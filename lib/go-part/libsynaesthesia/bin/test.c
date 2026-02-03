#include <stdio.h>
#include <stdlib.h>
#include "libsynaesthesia.h"

int main() {
    char* config_path = "config.json";
    int result = synaInit(config_path);
    
    if (result != 0) {
        printf("synaInit failed with code: %d\n", result);
        return 1;
    }
    
    printf("synaInit succeeded!\n");

    const char* upload_dir = synaGetUploadDir();
    printf("Upload directory: %s\n", upload_dir);

    const char* scan_result = synaScan();
    printf("Scan result: %s\n", scan_result);
    
    return 0;
}