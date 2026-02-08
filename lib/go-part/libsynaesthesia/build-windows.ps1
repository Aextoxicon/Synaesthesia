$env:CC="C:\tools\mingw64\bin\gcc.exe"; $env:CGO_ENABLED=1; $env:GOOS="windows"; $env:GOARCH="amd64"; go build -buildmode=c-shared -o .\bin\synaesthesia.dll .
cp bin/libsynaesthesia.dll ..\..\..\windows\
echo "Windows DLL built successfully!"
