package main

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
	"time"
)

type Config struct {
	UploadDir   string   `json:"uploadDir"`
	ApiToken    string   `json:"apiToken"`
	//Port        int      `json:"port"`
}

var config Config

func loadConfig() {
    data, err := os.ReadFile("config.json")
    if err != nil {
        log.Printf("load conf file failed: %v", err)
        config.Port = 9178
    } else {
        if err := json.Unmarshal(data, &config); err != nil {
            log.Fatalf("conf format is not true: %v", err)
        }
    }

    if _, err := os.Stat(config.UploadDir); os.IsNotExist(err) {
        log.Fatalf("upload dir is unwritable: %s", config.UploadDir)
    }
    testFile := filepath.Join(config.UploadDir, ".write_test")
    if err := os.WriteFile(testFile, []byte{}, 0644); err != nil {
        log.Fatalf("upload dir is unwritable: %v", err)
    }
    os.Remove(testFile)
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

func sanitizeFilename(name string) string {
	// 移除或替换字符 name = regexp.MustCompile(`[<>:"/\\|?*\x00-\x1f]`).ReplaceAllString(name, "_")
	name = strings.TrimPrefix(name, "..")
	name = strings.TrimPrefix(name, "/")
	return name
}

func urlEncodeFileName(name string) string {
	return strings.ReplaceAll(url.QueryEscape(name), "+", "%20")
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

func main() {
	loadConfig()

	http.HandleFunc("/upload", tokenAuth(upload))
	http.HandleFunc("/list", list)

	addr := fmt.Sprintf(":%d", config.Port)
	log.Printf("the backend servise running on http://localhost%s", addr)
	log.Printf("work dir is: %s", config.UploadDir)
	log.Fatal(http.ListenAndServe(addr, nil))
}