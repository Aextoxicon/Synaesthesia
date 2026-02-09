#!/bin/bash
CGO_LDFLAGS='-install_name @rpath/libsynaesthesia.dylib -Wl,-headerpad_max_install_names' \
go build -buildmode=c-shared -o bin/libsynaesthesia.dylib .
cp bin/libsynaesthesia.dylib ../../macos
echo "macOS Dylib built successfully!"