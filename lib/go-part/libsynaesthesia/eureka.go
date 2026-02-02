package main

/*
#include <stdlib.h>
*/
import "C"
import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
	"unsafe"
)

type Config struct {
	UploadDir   string   `json:"uploadDir"`
	ApiToken    string   `json:"apiToken"`
	Port        int      `json:"port"`
}

var config Config

var mimeTypes = map[string]string{
	".css":  "text/css",
	".gif":  "image/gif",
	".htm":  "text/html",
	".html": "text/html",
	".jpeg": "image/jpeg",
	".jpg":  "image/jpeg",
	".js":   "application/javascript",
	".mjs":  "application/javascript",
	".pdf":  "application/pdf",
	".png":  "image/png",
	".svg":  "image/svg+xml",
	".wasm": "application/wasm",
	".webp": "image/webp",
	".xml":  "text/xml",
}

var mu sync.RWMutex

func eurekaInit(configPath *C.char) C.int {
	mu.Lock()
	defer mu.Unlock()

	path := C.GoString(configPath)
	data, err := os.ReadFile(path)
	if err != nil {
		log.Printf("load conf file failed: %v", err)
		config.Port = 9178
	} else {
		if err := json.Unmarshal(data, &config); err != nil {
			log.Printf("conf format is not true: %v", err)
			return -1
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

	return 0
}

func eurekaSaveFileFromMemory(filename *C.char, data unsafe.Pointer, length C.int, token *C.char) C.int {
	mu.RLock()
	defer mu.RUnlock()

	fn := C.GoString(filename)
	apiToken := C.GoString(token)

	if apiToken != config.ApiToken {
		return -3 // Invalid token
	}

	if !regexp.MustCompile(`^[a-zA-Z0-9._@\-]+$`).MatchString(fn) {
		return -4 // Invalid filename
	}

	sanitizedFn := sanitizeFilename(fn)
	filePath := filepath.Join(config.UploadDir, sanitizedFn)

	realPath, err := filepath.Abs(filePath)
	if err != nil {
		return -5 // Path resolution failed
	}
	uploadAbs, _ := filepath.Abs(config.UploadDir)
	if !strings.HasPrefix(realPath, uploadAbs) {
		return -6 // Illegal file path
	}

	fileData := C.GoBytes(data, length)
	err = os.WriteFile(filePath, fileData, 0644)
	if err != nil {
		return -7 // Failed to save file
	}

	return 0 // Success
}

func eurekaListFiles() *C.char {
	mu.RLock()
	defer mu.RUnlock()

	entries, err := os.ReadDir(config.UploadDir)
	if err != nil {
		log.Printf("read dir failed: %v", err)
		errorResponse := `{"error": "获取文件列表失败"}`
		return C.CString(errorResponse)
	}

	var files []map[string]interface{}
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			continue
		}
		files = append(files, map[string]interface{}{
			"filename": entry.Name(),
			"size":     info.Size(),
		})
	}

	response, _ := json.Marshal(map[string]interface{}{"files": files})
	return C.CString(string(response))
}

func eurekaGetUploadDir() *C.char {
	mu.RLock()
	defer mu.RUnlock()
	return C.CString(config.UploadDir)
}

//export eurekaGetApiToken
func eurekaGetApiToken() *C.char {
	mu.RLock()
	defer mu.RUnlock()
	return C.CString(config.ApiToken)
}

func eurekaValidateToken(token *C.char) C.int {
	mu.RLock()
	defer mu.RUnlock()
	
	inputToken := C.GoString(token)
	if inputToken == config.ApiToken {
		return 0 // Valid
	}
	return -1 // Invalid
}

func eurekaGetPort() C.int {
	mu.RLock()
	defer mu.RUnlock()
	return C.int(config.Port)
}

func sanitizeFilename(name string) string {
	name = regexp.MustCompile(`[<>:"/\\|?*\x00-\x1f]`).ReplaceAllString(name, "_")
	name = strings.TrimPrefix(name, "..")
	name = strings.TrimPrefix(name, "/")
	return name
}

func urlEncodeFileName(name string) string {
	return strings.ReplaceAll(url.QueryEscape(name), "+", "%20")
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

func upload(w http.ResponseWriter, r *http.Request) {
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

func download(w http.ResponseWriter, r *http.Request) {
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

	ext := strings.ToLower(filepath.Ext(filename))
	contentType := mimeTypes[ext]
	if contentType == "" {
		contentType = mime.TypeByExtension(ext)
		if contentType == "" {
			contentType = "application/octet-stream"
		}
	}
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s"`, urlEncodeFileName(filename)))

	http.ServeFile(w, r, filePath)
}

func list(w http.ResponseWriter, r *http.Request) {
	entries, err := os.ReadDir(config.UploadDir)
	if err != nil {
		log.Printf("read dir failed: %v", err)
		http.Error(w, `{"error": "获取文件列表失败"}`, http.StatusInternalServerError)
		return
	}

	var files []map[string]interface{}
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			continue
		}
		files = append(files, map[string]interface{}{
			"filename": entry.Name(),
			"size":     info.Size(),
		})
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{"files": files})
}

func main() {}