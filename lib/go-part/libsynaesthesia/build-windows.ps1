$env:CC="C:\tools\mingw64\bin\gcc.exe"
go build -buildmode=c-shared -o bin/libsynaesthesia.dll .
cp bin/libsynaesthesia.dll ..\..\..\windows\
echo "Windows DLL built successfully!"
