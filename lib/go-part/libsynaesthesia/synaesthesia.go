package main

/*
#include <stdlib.h>
*/
import "C"
import (
	"crypto/sha256"
	"encoding/gob"
	"encoding/hex"
	"encoding/json"
	"io"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
	"unsafe"
)

type Config struct {
	UploadDir  string `json:"uploadDir"`
	ApiToken   string `json:"apiToken"`
	Port       int    `json:"port"`
	UseCompare bool   `json:"useCompare"`
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

func synaInit(configPath *C.char) C.int {
	mu.Lock()
	defer mu.Unlock()

	path := C.GoString(configPath)
	data, err := os.ReadFile(path)
	if err != nil {
		log.Printf("load conf file failed: %v", err)
		config.Port = 9178
		config.UseCompare = false
	} else {
		if err := json.Unmarshal(data, &config); err != nil {
			log.Printf("conf format is not true: %v", err)
			return -1
		}

		if config.UseCompare == false {

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

func synaListFiles() *C.char {
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

func synaGetUploadDir() *C.char {
	mu.RLock()
	defer mu.RUnlock()
	return C.CString(config.UploadDir)
}

type TextDiffRecord struct {
	Timestamp   time.Time `json:"timestamp"`
	User        string    `json:"user"`
	LineNumber  int       `json:"lineNumber"`
	OldLine     string    `json:"oldLine"`
	NewLine     string    `json:"newLine"`
}


type FileState struct {
	Name      string    `json:"name"`
	Size      int64     `json:"size"`
	ModTime   time.Time `json:"modTime"`
	SHA256    string    `json:"sha256"`
	Content   string    `json:"content"`
	DiffLog   []TextDiffRecord `json:"diffLog,omitempty"`
}


func isTextFile(path string) bool {
	ext := strings.ToLower(filepath.Ext(path))
	textExts := []string{".txt", ".json", ".csv", ".xml", ".yaml", ".yml", ".toml", ".ini", ".cfg", ".log", ".md", ".html", ".htm", ".js", ".ts", ".go", ".dart", ".py", ".rb", ".java", ".cpp", ".c", ".h", ".cs"}

	for _, te := range textExts {
		if ext == te {
			return true
		}
	}


	data, err := os.ReadFile(path)
	if err != nil {
		return false
	}


	checkSize := 1024
	if len(data) < checkSize {
		checkSize = len(data)
	}

	for i := 0; i < checkSize; i++ {
		b := data[i]
		if b < 32 && b != '\t' && b != '\n' && b != '\r' {
			return false
		}
		if b == 0 {
			return false
		}
	}

	return true
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


		sha256Hash, err := calcSHA256(absPath)
		if err != nil {
			continue
		}

		result = append(result, FileState{
			Name:    file.Name,
			Size:    file.Size,
			ModTime: info.ModTime(),
			SHA256:  sha256Hash,
		})
	}

	return result, nil
}

// compareTextFileChanges 比较文本文件的变更
func compareTextFileChanges(currentFile FileState, prevStates map[string]FileState) []TextDiffRecord {
	// 如果之前没有该文件的状态，则没有变更记录
	prevFile, exists := prevStates[currentFile.Name]
	if !exists {
		return []TextDiffRecord{}
	}
	
	// 如果文件未更改，则没有变更记录
	if prevFile.Size == currentFile.Size && prevFile.ModTime.Equal(currentFile.ModTime) {
		return []TextDiffRecord{}
	}
	
	// 读取当前文件内容（用于差异比较）
	currentPath := filepath.Join(config.UploadDir, currentFile.Name)
	currentContent, err := os.ReadFile(currentPath)
	if err != nil {
		return []TextDiffRecord{}
	}
	
	// 从之前的状态中获取旧内容（如果有的话）
	// 注意：prevFile.Content 可能为空（如果上次扫描时 SaveFullTextSource=false）
	// 在这种情况下，我们需要从磁盘读取旧文件
	var prevContent []byte
	if prevFile.Content != "" {
		prevContent = []byte(prevFile.Content)
	} else {
		// 从磁盘读取旧文件内容
		prevPath := filepath.Join(config.UploadDir, prevFile.Name)
		prevContent, err = os.ReadFile(prevPath)
		if err != nil {
			return []TextDiffRecord{}
		}
	}
	
	// 将内容转换为行
	currentLines := strings.Split(string(currentContent), "\n")
	prevLines := strings.Split(string(prevContent), "\n")
	
	var diffRecords []TextDiffRecord
	maxLen := len(currentLines)
	if len(prevLines) > maxLen {
		maxLen = len(prevLines)
	}
	
	// 简单的逐行比较
	for i := 0; i < maxLen; i++ {
		var record TextDiffRecord
		record.Timestamp = time.Now()
		record.User = "unknown" // 在实际应用中，这里应该是真实的用户名
		
		var oldLine, newLine string
		if i < len(prevLines) {
			oldLine = prevLines[i]
		} else {
			oldLine = "" // 行被添加
		}
		
		if i < len(currentLines) {
			newLine = currentLines[i]
		} else {
			newLine = "" // 行被删除
		}
		
		// 如果行不同或者一边为空另一边不为空，则记录变更
		if oldLine != newLine {
			record.LineNumber = i + 1 // 行号从1开始
			record.OldLine = oldLine
			record.NewLine = newLine
			diffRecords = append(diffRecords, record)
		}
	}
	
	return diffRecords
}


func synaTextFiles(textFiles []FileState, prevStates map[string]FileState) ([]FileState, error) {
	var result []FileState

	for _, file := range textFiles {
		absPath := filepath.Join(config.UploadDir, file.Name)


		info, err := os.Stat(absPath)
		if err != nil {
			continue
		}


		sha256Hash, err := calcSHA256(absPath)
		if err != nil {
			continue
		}


		contentBytes, err := os.ReadFile(absPath)
		if err != nil {
			continue
		}
		content := string(contentBytes)

		var diffLog []TextDiffRecord


		if config.UseCompare {
			// 计算变更记录（这需要读取文件内容进行比较）
			diffLog = compareTextFileChanges(file, prevStates)
		} else {
			// 如果不启用比较，则返回空的diff日志
			diffLog = []TextDiffRecord{}
		}

		result = append(result, FileState{
			Name:      file.Name,
			Size:      file.Size,
			ModTime:   info.ModTime(),
			SHA256:    sha256Hash,
			Content:   content,
			DiffLog:   diffLog,
		})
	}

	return result, nil
}

var stateHistoryPath string

func SaveFileStatesToFile(states map[string]FileState, filePath string) error {
	file, err := os.Create(filePath)
	if err != nil {
		return err
	}
	defer file.Close()

	encoder := gob.NewEncoder(file)
	return encoder.Encode(states)
}

func LoadFileStatesFromFile(filePath string) (map[string]FileState, error) {
	states := make(map[string]FileState)

	if _, err := os.Stat(filePath); os.IsNotExist(err) {
		return states, nil
	}

	file, err := os.Open(filePath)
	if err != nil {
		return states, err
	}
	defer file.Close()

	decoder := gob.NewDecoder(file)
	err = decoder.Decode(&states)
	if err != nil {
		return states, err
	}

	return states, nil
}


func synaScan() *C.char {
	mu.RLock()
	defer mu.RUnlock()

	entries, err := os.ReadDir(config.UploadDir)
	if err != nil {
		log.Printf("scan dir failed: %v", err)
		errorResponse := `{"error": "扫描目录失败"}`
		return C.CString(errorResponse)
	}

	var allFiles []FileState
	var textFiles []FileState

	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}

		info, err := entry.Info()
		if err != nil {
			continue
		}

		absPath := filepath.Join(config.UploadDir, entry.Name())
		fileState := FileState{
			Name:    entry.Name(),
			Size:    info.Size(),
			ModTime: info.ModTime(),
		}

		allFiles = append(allFiles, fileState)

		if isTextFile(absPath) {

			if contentBytes, err := os.ReadFile(absPath); err == nil {
				fileState.Content = string(contentBytes)
			}
			textFiles = append(textFiles, fileState)
		}
	}


	stateHistoryPath = filepath.Join(config.UploadDir, ".file_states_history.gob")
	prevStates, err := LoadFileStatesFromFile(stateHistoryPath)
	if err != nil {
		log.Printf("load previous file states failed: %v", err)

		prevStates = make(map[string]FileState)
	}


	processedAllFiles, err := synaProcessFiles(allFiles)
	if err != nil {
		log.Printf("process all files failed: %v", err)
		errorResponse := `{"error": "处理文件失败"}`
		return C.CString(errorResponse)
	}


	processedTextFiles, err := synaTextFiles(textFiles, prevStates)
	if err != nil {
		log.Printf("process text files failed: %v", err)
		errorResponse := `{"error": "处理文本文件失败"}`
		return C.CString(errorResponse)
	}


	currentStates := make(map[string]FileState)
	for _, tf := range textFiles {
		currentStates[tf.Name] = tf
	}
	for _, bf := range allFiles {
		if _, exists := currentStates[bf.Name]; !exists {

			currentStates[bf.Name] = FileState{
				Name:    bf.Name,
				Size:    bf.Size,
				ModTime: bf.ModTime,
				Content: bf.Content,
			}
		}
	}

	if err := SaveFileStatesToFile(currentStates, stateHistoryPath); err != nil {
		log.Printf("save current file states failed: %v", err)
	}


	response := map[string]interface{}{
		"allFiles":    processedAllFiles,
		"textFiles":   processedTextFiles,
	}

	jsonResponse, err := json.Marshal(response)
	if err != nil {
		log.Printf("marshal response failed: %v", err)
		errorResponse := `{"error": "生成响应失败"}`
		return C.CString(errorResponse)
	}

	return C.CString(string(jsonResponse))
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


func main() {}