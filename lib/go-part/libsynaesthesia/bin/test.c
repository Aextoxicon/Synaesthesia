#include <stdio.h>
#include <stdlib.h>
#include <windows.h>
#include <time.h>

// 定义所有导出函数的指针类型（Go CGO 使用 stdcall）
typedef int (__stdcall *synaInit_func)(const char*);
typedef const char* (__stdcall *synaGetUploadDir_func)();
typedef const char* (__stdcall *synaScan_func)();
typedef int (__stdcall *synaStartHttpServer_func)();
typedef int (__stdcall *synaStopHttpServer_func)();
typedef int (__stdcall *synaUpload_func)(const char*, const char*);

int main() {
    HMODULE dll = LoadLibrary("libsynaesthesia.dll");
    if (!dll) {
        printf("Failed to load libsynaesthesia.dll\n");
        return 1;
    }

    // 获取所有函数地址
    synaInit_func synaInit = (synaInit_func)GetProcAddress(dll, "synaInit");
    synaGetUploadDir_func synaGetUploadDir = (synaGetUploadDir_func)GetProcAddress(dll, "synaGetUploadDir");
    synaScan_func synaScan = (synaScan_func)GetProcAddress(dll, "synaScan");
    synaStartHttpServer_func synaStartHttpServer = (synaStartHttpServer_func)GetProcAddress(dll, "synaStartHttpServer");
    synaStopHttpServer_func synaStopHttpServer = (synaStopHttpServer_func)GetProcAddress(dll, "synaStopHttpServer");
    synaUpload_func synaUpload = (synaUpload_func)GetProcAddress(dll, "synaUpload");

    // 检查必需函数
    if (!synaInit || !synaGetUploadDir || !synaScan) {
        printf("Failed to get core function addresses\n");
        FreeLibrary(dll);
        return 1;
    }

    // === 测试 1: 初始化 ===
    printf("=== Testing synaInit ===\n");
    int result = synaInit("config.json");
    if (result != 0) {
        printf("synaInit failed with code: %d\n", result);
        FreeLibrary(dll);
        return 1;
    }
    printf("✓ synaInit succeeded!\n");

    // === 测试 2: 获取上传目录 ===
    printf("\n=== Testing synaGetUploadDir ===\n");
    const char* upload_dir = synaGetUploadDir();
    printf("Upload directory: %s\n", upload_dir);

    // === 测试 3: 扫描文件 ===
    printf("\n=== Testing synaScan ===\n");
    const char* scan_result = synaScan();
    printf("Scan result: %.*s\n", 200, scan_result); // 限制输出长度避免过长

    // === 测试 4: 启动 HTTP 服务器 ===
    if (synaStartHttpServer) {
        printf("\n=== Testing synaStartHttpServer ===\n");
        int start_result = synaStartHttpServer();
        if (start_result == 0) {
            printf("✓ HTTP server started successfully!\n");
            printf("Server running on port %d (check config.json)\n", 9178); // 默认端口
            
            // 等待几秒让服务器启动
            Sleep(2000);
            
            // === 测试 5: 停止 HTTP 服务器 ===
            if (synaStopHttpServer) {
                printf("\n=== Testing synaStopHttpServer ===\n");
                int stop_result = synaStopHttpServer();
                if (stop_result == 0) {
                    printf("HTTP server stopped successfully!\n");
                } else {
                    printf("synaStopHttpServer failed: %d\n", stop_result);
                }
            }
        } else {
            printf("synaStartHttpServer failed: %d\n", start_result);
        }
    }

    // === 测试 6: 文件上传（需要有效文件路径）===
    if (synaUpload) {
        printf("\n=== Testing synaUpload ===\n");
        // 创建一个测试文件
        FILE* test_file = fopen("test_upload.txt", "w");
        if (test_file) {
            fprintf(test_file, "Test file for upload");
            fclose(test_file);
            
            // 尝试上传到本地服务器（假设服务器正在运行）
            int upload_result = synaUpload("test_upload.txt", "http://localhost:9178");
            if (upload_result == 0) {
                printf("File upload succeeded!\n");
            } else {
                printf("synaUpload failed: %d (expected if server not running)\n", upload_result);
            }
            
            // 清理测试文件
            remove("test_upload.txt");
        } else {
            printf("Could not create test file for upload\n");
        }
    }

    FreeLibrary(dll);
    printf("\n=== All tests completed ===\n");
    return 0;
}