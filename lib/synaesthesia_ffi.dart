import 'dart:ffi';
import 'dart:io' show Platform;
import 'package:ffi/ffi.dart';

typedef SynaInitC = Int32 Function(Pointer<Utf8> configPath);
typedef SynaInitDart = int Function(Pointer<Utf8> configPath);

typedef SynaScanC = Pointer<Utf8> Function();
typedef SynaScanDart = Pointer<Utf8> Function();

typedef SynaGetUploadDirC = Pointer<Utf8> Function();
typedef SynaGetUploadDirDart = Pointer<Utf8> Function();

typedef SynaStartHttpServerC = Int32 Function();
typedef SynaStartHttpServerDart = int Function();

typedef SynaStopHttpServerC = Int32 Function();
typedef SynaStopHttpServerDart = int Function();

typedef SynaUploadC = Int32 Function(Pointer<Utf8> filePath, Pointer<Utf8> uploadHost);
typedef SynaUploadDart = int Function(Pointer<Utf8> filePath, Pointer<Utf8> uploadHost);

typedef SynaCompareChangesC = Pointer<Utf8> Function(Pointer<Utf8> remoteHost, Pointer<Utf8> token);
typedef SynaCompareChangesDart = Pointer<Utf8> Function(Pointer<Utf8> remoteHost, Pointer<Utf8> token);

class SynaesthesiaLibrary {
  late final DynamicLibrary _dylib;
  late final SynaInitDart synaInit;
  late final SynaScanDart synaScan;
  late final SynaGetUploadDirDart synaGetUploadDir;
  late final SynaStartHttpServerDart synaStartHttpServer;
  late final SynaStopHttpServerDart synaStopHttpServer;
  late final SynaUploadDart synaUpload;
  late final SynaCompareChangesDart synaCompareChanges;

  SynaesthesiaLibrary._() {
    String libraryPath;
    if (Platform.isWindows) {
      libraryPath = 'libsynaesthesia.dll';
    } else if (Platform.isAndroid) {
      libraryPath = 'libsynaesthesia.so';
    } else if (Platform.isMacOS) {
      libraryPath = 'libsynaesthesia.dylib';
    } else {
      throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
    }

    _dylib = DynamicLibrary.open(libraryPath);

    synaInit = _dylib.lookupFunction<SynaInitC, SynaInitDart>('synaInit');
    synaScan = _dylib.lookupFunction<SynaScanC, SynaScanDart>('synaScan');
    synaGetUploadDir = _dylib.lookupFunction<SynaGetUploadDirC, SynaGetUploadDirDart>('synaGetUploadDir');
    synaStartHttpServer = _dylib.lookupFunction<SynaStartHttpServerC, SynaStartHttpServerDart>('synaStartHttpServer');
    synaStopHttpServer = _dylib.lookupFunction<SynaStopHttpServerC, SynaStopHttpServerDart>('synaStopHttpServer');
    synaUpload = _dylib.lookupFunction<SynaUploadC, SynaUploadDart>('synaUpload');
    synaCompareChanges = _dylib.lookupFunction<SynaCompareChangesC, SynaCompareChangesDart>('synaCompareChanges');
  }

  static final SynaesthesiaLibrary _instance = SynaesthesiaLibrary._();
  static SynaesthesiaLibrary get instance => _instance;
}