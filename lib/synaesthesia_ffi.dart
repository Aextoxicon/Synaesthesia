import 'dart:ffi';
import 'dart:io' show Platform;
import 'package:ffi/ffi.dart';

typedef SynaInitC = Int32 Function(Pointer<Utf8> configPath);
typedef SynaInitDart = int Function(Pointer<Utf8> configPath);

typedef SynaScanC = Pointer<Utf8> Function();
typedef SynaScanDart = Pointer<Utf8> Function();

typedef SynaGetUploadDirC = Pointer<Utf8> Function();
typedef SynaGetUploadDirDart = Pointer<Utf8> Function();

class SynaesthesiaLibrary {
  late final DynamicLibrary _dylib;
  late final SynaInitDart synaInit;
  late final SynaScanDart synaScan;
  late final SynaGetUploadDirDart synaGetUploadDir;

  SynaesthesiaLibrary._() {
    String libraryPath;
    if (Platform.isWindows) {
      libraryPath = 'synaesthesia.dll';
    } else if (Platform.isAndroid) {
      libraryPath = 'libsynaesthesia.so';
    } else if (Platform.isMacOS) {
      libraryPath = 'libsynaesthesia.dylib';
    } else {
      throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
    }

    try {
      _dylib = DynamicLibrary.open(libraryPath);
    } catch (e) {
      String projectPath = '';
      if (Platform.isWindows) {
        projectPath = './lib/go-part/libsynaesthesia/synaesthesia.dll';
      } else {
        projectPath = './lib/go-part/libsynaesthesia/libsynaesthesia.so';
      }
      _dylib = DynamicLibrary.open(projectPath);
    }

    synaInit = _dylib.lookupFunction<SynaInitC, SynaInitDart>('synaInit');
    synaScan = _dylib.lookupFunction<SynaScanC, SynaScanDart>('synaScan');
    synaGetUploadDir = _dylib.lookupFunction<SynaGetUploadDirC, SynaGetUploadDirDart>('synaGetUploadDir');
  }

  static final SynaesthesiaLibrary _instance = SynaesthesiaLibrary._();
  static SynaesthesiaLibrary get instance => _instance;
}