flutter clean
flutter build windows
cd lib\libsynaesthesia
.\build-windows.ps1
.\build-android.ps1
cd ..\..
flutter build apk
adb install .\build\app\outputs\flutter-apk\app-release.apk
.\build\windows\x64\runner\Release\flutter_application.exe