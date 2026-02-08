package main

/*
#include <stdlib.h>
*/
import "C"
import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"mime/multipart"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

type Config struct {
	UploadDir  string `json:"uploadDir"`
	UseCompare bool   `json:"useCompare"`
	ApiToken   string `json:"apiToken"`
	Port       int    `json:"port"`
	UseToken   bool   `json:"useToken"`
}

var config Config
var httpServer *http.Server
var customMux *http.ServeMux // 使用自定义ServeMux
var mu sync.RWMutex

//export synaInit
func synaInit(configPath *C.char) C.int {
	mu.Lock()
	defer mu.Unlock()

	path := C.GoString(configPath)
	data, err := os.ReadFile(path)
	if err != nil {
		log.Printf("load conf file failed: %v", err)
		config.UploadDir = ""
		config.UseCompare = false
		config.Port = 9178
		config.UseToken = false
	} else {
		if err := json.Unmarshal(data, &config); err != nil {
			log.Printf("conf format is not true: %v", err)
			return -1
		}
		if config.Port == 0 {
			config.Port = 9178
		}

	}

	if _, err := os.Stat(config.UploadDir); os.IsNotExist(err) {
		log.Printf("upload dir is unwritable: %s", config.UploadDir)
		return -2
	}
	testFile := filepath.Join(config.UploadDir, ".write_test")
	if err := os.WriteFile(testFile, []byte{}, 0644); err != nil {
		log.Printf("upload dir is unwritable: %v", err)
		return -2
	}
	os.Remove(testFile)

	if config.UseCompare {
		synaDir := filepath.Join(config.UploadDir, ".syna")
		if err := os.MkdirAll(synaDir, 0755); err != nil {
			log.Printf("failed to create .syna directory: %v", err)
			return -2
		}

		originDir := filepath.Join(synaDir, "origin")
		if err := os.MkdirAll(originDir, 0755); err != nil {
			log.Printf("failed to create .syna/origin directory: %v", err)
			return -2
		}
	}

	return 0
}
func tokenAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		authHeader := r.Header.Get("Authorization")
		if authHeader == "" {
			http.Error(w, `{"error": "Missing Authorization header"}`, http.StatusUnauthorized)
			return
		}

		parts := strings.Split(authHeader, " ")
		if len(parts) != 2 || parts[0] != "Bearer" {
			http.Error(w, `{"error": "Authorization format must be 'Bearer <token>'"}`, http.StatusUnauthorized)
			return
		}

		if parts[1] != config.ApiToken {
			http.Error(w, `{"error": "Invalid token"}`, http.StatusUnauthorized)
			return
		}

		next(w, r)
	}
}

func uploadHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	file, header, err := r.FormFile("file")
	if err != nil {
		http.Error(w, `{"error": "未选择文件"}`, http.StatusBadRequest)
		return
	}
	defer file.Close()

	filename := sanitizeFilename(header.Filename)
	filePath := filepath.Join(config.UploadDir, filename)

	out, err := os.Create(filePath)
	if err != nil {
		http.Error(w, `{"error": "保存文件失败"}`, http.StatusInternalServerError)
		return
	}
	defer out.Close()

	_, err = io.Copy(out, file)
	if err != nil {
		http.Error(w, `{"error": "写入文件失败"}`, http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	fmt.Fprintf(w, `{"message": "上传成功"}`)
	log.Printf("file upload succeed: %s", filename)
}

func downloadHandler(w http.ResponseWriter, r *http.Request) {
	filename := filepath.Base(r.URL.Path)

	validName := regexp.MustCompile(`^[a-zA-Z0-9._@\-]+$`).MatchString(filename)
	if !validName {
		http.Error(w, `{"error": "非法文件名"}`, http.StatusBadRequest)
		return
	}

	filePath := filepath.Join(config.UploadDir, filename)
	realPath, err := filepath.Abs(filePath)
	if err != nil {
		http.Error(w, `{"error": "路径解析失败"}`, http.StatusInternalServerError)
		return
	}

	uploadAbs, _ := filepath.Abs(config.UploadDir)
	if !strings.HasPrefix(realPath, uploadAbs) {
		http.Error(w, `{"error": "非法文件路径"}`, http.StatusBadRequest)
		return
	}

	if _, err := os.Stat(filePath); os.IsNotExist(err) {
		http.Error(w, `{"error": "文件不存在"}`, http.StatusNotFound)
		return
	}

	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s"`, urlEncodeFileName(filename)))
	http.ServeFile(w, r, filePath)
}

func listHandler(w http.ResponseWriter, r *http.Request) {
	scanResult := synaScan()

	scanResultStr := C.GoString(scanResult)

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	fmt.Fprint(w, scanResultStr)
}

func sanitizeFilename(name string) string {
	name = strings.TrimPrefix(name, "..")
	name = strings.TrimPrefix(name, "/")
	return name
}

func urlEncodeFileName(name string) string {
	return strings.ReplaceAll(url.QueryEscape(name), "+", "%20")
}

//export synaGetUploadDir
func synaGetUploadDir() *C.char {
	mu.RLock()
	defer mu.RUnlock()
	return C.CString(config.UploadDir)
}

type FileState struct {
	Name    string    `json:"name"`
	Size    int64     `json:"size"`
	ModTime time.Time `json:"modTime"`
	SHA256  string    `json:"sha256,omitempty"`
}

func calcSHA256(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()

	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return "", err
	}

	return hex.EncodeToString(hash.Sum(nil)), nil
}

func synaProcessFiles(files []FileState) ([]FileState, error) {
	var result []FileState

	for _, file := range files {
		absPath := filepath.Join(config.UploadDir, file.Name)

		info, err := os.Stat(absPath)
		if err != nil {
			continue
		}

		newFileState := FileState{
			Name:    file.Name,
			Size:    file.Size,
			ModTime: info.ModTime(),
		}

		if config.UseCompare {
			sha256Hash, err := calcSHA256(absPath)
			if err != nil {
				continue
			}
			newFileState.SHA256 = sha256Hash
		}

		result = append(result, newFileState)
	}

	return result, nil
}

//export synaScan
func synaScan() *C.char {
	mu.RLock()
	defer mu.RUnlock()

	entries, err := os.ReadDir(config.UploadDir)
	if err != nil {
		log.Printf("scan dir failed: %v", err)
		errorResponse := `{"error": "扫描目录失败", "status": "error"}`
		return C.CString(errorResponse)
	}

	var allFiles []FileState

	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}

		info, err := entry.Info()
		if err != nil {
			continue
		}

		fileState := FileState{
			Name:    entry.Name(),
			Size:    info.Size(),
			ModTime: info.ModTime(),
		}

		if config.UseCompare {
			absPath := filepath.Join(config.UploadDir, fileState.Name)
			sha256Hash, err := calcSHA256(absPath)
			if err == nil {
				fileState.SHA256 = sha256Hash
			}
		}

		allFiles = append(allFiles, fileState)
	}

	processedAllFiles, err := synaProcessFiles(allFiles)
	if err != nil {
		log.Printf("process all files failed: %v", err)
		errorResponse := `{"error": "处理文件失败", "status": "error"}`
		return C.CString(errorResponse)
	}

	response := map[string]interface{}{
		"allFiles": processedAllFiles,
		"status":   "success",
	}

	jsonResponse, err := json.Marshal(response)
	if err != nil {
		log.Printf("marshal response failed: %v", err)
		errorResponse := `{"error": "生成响应失败", "status": "error"}`
		return C.CString(errorResponse)
	}

	return C.CString(string(jsonResponse))
}

//export synaStartHttpServer
func synaStartHttpServer() C.int {
	mu.Lock() // 使用写锁确保线程安全
	defer mu.Unlock()

	if config.UploadDir == "" {
		return -1
	}

	// 创建新的 ServeMux 实例
	customMux = http.NewServeMux()

	addr := fmt.Sprintf(":%d", config.Port)
	
	// 注册路由到自定义的 ServeMux
	if config.UseToken {
		customMux.HandleFunc("/upload", tokenAuth(uploadHandler))
	} else {
		customMux.HandleFunc("/upload", uploadHandler)
	}

	customMux.HandleFunc("/list", listHandler)
	customMux.HandleFunc("/download/", downloadHandler)

	// 创建服务器实例并使用自定义 ServeMux
	httpServer = &http.Server{
		Addr:    addr,
		Handler: customMux, // 使用自定义的 mux
	}

	go func() {
		log.Printf("HTTP server running on http://localhost:%s", addr)
		log.Printf("Work dir is: %s", config.UploadDir)
		if config.UseToken {
			log.Printf("Token authentication is enabled")
		} else {
			log.Printf("Token authentication is disabled")
		}
		if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Printf("HTTP server error: %v", err)
		}
	}()

	return 0
}

//export synaStopHttpServer
func synaStopHttpServer() C.int {
	mu.Lock()
	defer mu.Unlock()

	if httpServer != nil {
		err := httpServer.Close()
		if err != nil {
			log.Printf("Error closing server: %v", err)
			return -1
		}
		httpServer = nil
		customMux = nil // 清除 ServeMux 引用
	}
	return 0
}

//export synaUpload
func synaUpload(filePath *C.char, uploadHost *C.char) C.int {
	mu.RLock()
	defer mu.RUnlock()

	filePathStr := C.GoString(filePath)
	uploadHostStr := C.GoString(uploadHost)

	// 验证文件是否存在
	if _, err := os.Stat(filePathStr); os.IsNotExist(err) {
		log.Printf("File does not exist: %s", filePathStr)
		return -1
	}

	// 打开文件
	file, err := os.Open(filePathStr)
	if err != nil {
		log.Printf("Failed to open file: %v", err)
		return -2
	}
	defer file.Close()

	// 获取文件名
	filename := filepath.Base(filePathStr)
	
	// 创建 multipart writer
	body := &bytes.Buffer{}
	writer := multipart.NewWriter(body)
	
	part, err := writer.CreateFormFile("file", filename)
	if err != nil {
		log.Printf("Failed to create form file: %v", err)
		return -3
	}
	
	// 复制文件内容到 multipart
	_, err = io.Copy(part, file)
	if err != nil {
		log.Printf("Failed to copy file content: %v", err)
		return -4
	}
	
	err = writer.Close()
	if err != nil {
		log.Printf("Failed to close multipart writer: %v", err)
		return -5
	}

	// 构建请求 URL
	uploadURL := uploadHostStr
	if !strings.HasSuffix(uploadHostStr, "/") {
		uploadURL += "/"
	}
	uploadURL += "upload"

	// 创建 HTTP 请求
	req, err := http.NewRequest("POST", uploadURL, body)
	if err != nil {
		log.Printf("Failed to create HTTP request: %v", err)
		return -6
	}

	// 设置请求头
	req.Header.Set("Content-Type", writer.FormDataContentType())
	
	// 如果启用了 Token 认证，添加 Authorization 头
	if config.UseToken {
		req.Header.Set("Authorization", "Bearer "+config.ApiToken)
	}

	// 发送请求
	client := &http.Client{
		Timeout: 30 * time.Second,
	}
	resp, err := client.Do(req)
	if err != nil {
		log.Printf("Failed to send HTTP request: %v", err)
		return -7
	}
	defer resp.Body.Close()

	// 检查响应状态
	if resp.StatusCode != http.StatusOK {
		log.Printf("Upload failed with status code: %d", resp.StatusCode)
		return -8
	}

	log.Printf("File uploaded successfully to: %s", uploadURL)
	return 0
}

func main() {}