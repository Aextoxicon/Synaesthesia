CGO_LDFLAGS='-install_name @rpath/libsynaesthesia.dylib -Wl,-headerpad_max_install_names' \
go build -buildmode=c-shared -o bin/libsynaesthesia.dylib .
cp bin/libsynaesthesia.dylib ../../../../build/macos/Build/Products/Release/synaesthesia.app/Contents/Frameworks/
echo "macOS Dylib built successfully!"