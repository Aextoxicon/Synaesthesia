rm bin\*
$env:CC="C:\tools\mingw64\bin\gcc.exe"; $env:CGO_ENABLED=1; $env:GOOS="windows"; $env:GOARCH="amd64"; go build -buildmode=c-shared -o .\bin\libsynaesthesia.dll .
cp bin\libsynaesthesia.dll ..\..\build\windows\x64\runner\Release
cp bin\libsynaesthesia.dll ..\..\build\windows\x64\runner\Debug
echo "Windows DLL built successfully!"
