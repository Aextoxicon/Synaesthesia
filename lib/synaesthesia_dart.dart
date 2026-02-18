import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

class FileState {
  final String name;
  final String relativePath;
  final int size;
  final DateTime modTime;

  FileState({
    required this.name,
    required this.relativePath,
    required this.size,
    required this.modTime,
  });

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'relativePath': relativePath,
      'size': size,
      'modTime': modTime.toIso8601String(),
    };
  }

  factory FileState.fromJson(Map<String, dynamic> json) {
    return FileState(
      name: json['name'],
      relativePath: json['relativePath'],
      size: json['size'],
      modTime: DateTime.parse(json['modTime']),
    );
  }
}

class SynaesthesiaDart {
  String? uploadDir;
  String? apiToken;
  int port = 9178;
  bool useToken = false;
  HttpServer? _httpServer;
  bool _isServerRunning = false;
  String? _localIp;

  bool get isServerRunning => _isServerRunning;

  Future<String> _getAppConfigDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final configDir = Directory(path.join(appDir.path, '.synaesthesia'));
    if (!await configDir.exists()) {
      await configDir.create(recursive: true);
    }
    return configDir.path;
  }

  Future<String> _getConfigFilePath() async {
    final configDir = await _getAppConfigDir();
    return path.join(configDir, 'server_config.json');
  }

  Future<String> _getLocalIp() async {
    if (_localIp != null) {
      return _localIp!;
    }

    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      
      final virtualInterfaceNames = [
        'Clash', 'Clash Core', 'clash',
        'WSL', 'wsl', 'vEthernet',
        'Hyper-V', 'HyperV',
        'VPN', 'vpn', 'Tun', 'tun',
        'Loopback', 'loopback',
        'Bluetooth', 'bluetooth',
        'rmnet', 'pdp', 'v4-rtnet',
      ];
      
      final virtualIpPrefixes = [
        '198.18.', '198.19.',
        '169.254.',
        '127.', '0.',
      ];
      
      bool isVirtualInterface(String name) {
        final lowerName = name.toLowerCase();
        return virtualInterfaceNames.any((v) => lowerName.contains(v.toLowerCase()));
      }
      
      bool isVirtualIp(String ip) {
        return virtualIpPrefixes.any((prefix) => ip.startsWith(prefix));
      }
      
      // 优先选择 WiFi 相关接口
      final wifiInterfaceNames = [
        'wlan', 'wifi', 'wlp', 'eth', 'en', 'wl',
      ];
      
      // 先尝试 WiFi 接口
      for (final interface in interfaces) {
        final lowerName = interface.name.toLowerCase();
        if (wifiInterfaceNames.any((wifiName) => lowerName.startsWith(wifiName)) &&
            !isVirtualInterface(interface.name)) {
          
          for (final addr in interface.addresses) {
            if (addr.type == InternetAddressType.IPv4) {
              final ip = addr.address;
              if (!isVirtualIp(ip)) {
                _localIp = ip;
                print('Selected WiFi interface: ${interface.name} ($ip)');
                return ip;
              }
            }
          }
        }
      }
      
      // 如果没有找到 WiFi 接口，则选择第一个非虚拟接口
      for (final interface in interfaces) {
        if (isVirtualInterface(interface.name)) {
          print('Skipping virtual interface: ${interface.name}');
          continue;
        }
        
        for (final addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4) {
            final ip = addr.address;
            if (isVirtualIp(ip)) {
              print('Skipping virtual IP: $ip on ${interface.name}');
              continue;
            }
            
            _localIp = ip;
            print('Selected network interface: ${interface.name} ($ip)');
            return ip;
          }
        }
      }
      
      print('No suitable network interface found, using localhost');
      _localIp = 'localhost';
      return 'localhost';
    } catch (e) {
      print('Failed to get local IP address: $e');
      _localIp = 'localhost';
      return 'localhost';
    }
  }

  Stream<Map<String, dynamic>> discoverServersStream({
    Duration timeout = const Duration(seconds: 5),
    void Function(int current, int total, String currentIp)? onProgress,
  }) async* {
    try {
      final localIp = await _getLocalIp();
      print('Starting subnet scan for Synaesthesia servers...');
      print('Local IP: $localIp');
      
      final parts = localIp.split('.');
      if (parts.length != 4) {
        print('Invalid local IP format');
        return;
      }
      
      final subnet = '${parts[0]}.${parts[1]}.${parts[2]}';
      final currentHost = int.parse(parts[3]);
      
      final dio = Dio();
      dio.options.connectTimeout = const Duration(milliseconds: 500);
      dio.options.receiveTimeout = const Duration(milliseconds: 500);
      
      final totalIps = 254;
      var checked = 0;
      
      final controller = StreamController<Map<String, dynamic>>();
      
      for (int i = 1; i < 255; i++) {
        if (i == currentHost) continue;
        
        final ip = '$subnet.$i';
        _checkServerAsync(dio, ip, port).then((result) {
          checked++;
          onProgress?.call(checked, totalIps, ip);
          
          if (result != null) {
            controller.add(result);
            print('Found server: ${result['name']} at ${result['host']}:${result['port']}');
          }
          
          if (checked >= totalIps - 1) {
            controller.close();
          }
        });
      }
      
      await for (final server in controller.stream) {
        yield server;
      }
      
      print('Subnet scan completed');
    } catch (e) {
      print('Subnet scan error: $e');
    }
  }

  Future<Map<String, dynamic>?> _checkServerAsync(Dio dio, String ip, int port) async {
    try {
      final response = await dio.get('http://$ip:$port/ping');
      if (response.statusCode == 200 && response.data['status'] == 'ok') {
        return {
          'host': ip,
          'port': port,
          'name': response.data['name'] ?? 'Synaesthesia-$ip',
          'ips': [ip],
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        };
      }
    } catch (e) {
      // Server not available, ignore
    }
    return null;
  }

  Future<List<Map<String, dynamic>>> discoverServers({Duration timeout = const Duration(seconds: 5)}) async {
    final servers = <Map<String, dynamic>>[];
    
    try {
      final localIp = await _getLocalIp();
      print('Starting subnet scan for Synaesthesia servers...');
      print('Local IP: $localIp');
      
      final parts = localIp.split('.');
      if (parts.length != 4) {
        print('Invalid local IP format');
        return servers;
      }
      
      final subnet = '${parts[0]}.${parts[1]}.${parts[2]}';
      final currentHost = int.parse(parts[3]);
      
      final dio = Dio();
      dio.options.connectTimeout = const Duration(milliseconds: 500);
      dio.options.receiveTimeout = const Duration(milliseconds: 500);
      
      final futures = <Future<Map<String, dynamic>?>>[];
      
      for (int i = 1; i < 255; i++) {
        if (i == currentHost) continue;
        
        final ip = '$subnet.$i';
        futures.add(_checkServer(dio, ip, port));
      }
      
      final results = await Future.wait(futures);
      
      for (final result in results) {
        if (result != null) {
          servers.add(result);
          print('Found server: ${result['name']} at ${result['host']}:${result['port']}');
        }
      }
      
      print('Subnet scan completed, found ${servers.length} servers');
    } catch (e) {
      print('Subnet scan error: $e');
    }
    
    return servers;
  }

  Future<Map<String, dynamic>?> _checkServer(Dio dio, String ip, int port) async {
    try {
      final response = await dio.get('http://$ip:$port/ping');
      if (response.statusCode == 200 && response.data['status'] == 'ok') {
        return {
          'host': ip,
          'port': port,
          'name': response.data['name'] ?? 'Synaesthesia-$ip',
          'ips': [ip],
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        };
      }
    } catch (e) {
      // Server not available, ignore
    }
    return null;
  }

  Future<int> synaInit(String? uploadDirOverride) async {
    try {
      if (uploadDirOverride != null && uploadDirOverride.isNotEmpty) {
        uploadDir = uploadDirOverride;
        
        final config = {
          'uploadDir': uploadDir!,
          'apiToken': apiToken ?? '',
          'port': port,
          'useToken': useToken,
          'autoStart': true,
        };
        
        final configFilePath = await _getConfigFilePath();
        final configFile = File(configFilePath);
        await configFile.writeAsString(json.encode(config));
        
        return 0;
      }

      final configFilePath = await _getConfigFilePath();
      final configFile = File(configFilePath);
      
      if (await configFile.exists()) {
        final configData = await configFile.readAsString();
        final configJson = json.decode(configData);
        
        uploadDir = configJson['uploadDir'] as String?;
        apiToken = configJson['apiToken'] as String?;
        port = configJson['port'] as int? ?? 9178;
        useToken = configJson['useToken'] as bool? ?? false;
      } else {
        uploadDir = '';
        port = 9178;
        useToken = false;
      }

      if (uploadDir == null || uploadDir!.isEmpty) {
        return -1;
      }

      final dir = Directory(uploadDir!);
      if (!await dir.exists()) {
        return -2;
      }

      final testFile = File(path.join(uploadDir!, '.write_test'));
      await testFile.writeAsString('');
      await testFile.delete();

      return 0;
    } catch (e) {
      print('synaInit error: $e');
      return -1;
    }
  }

  Future<String> synaGetUploadDir() async {
    return uploadDir ?? '';
  }

  Future<List<FileState>> synaScan() async {
    if (uploadDir == null || uploadDir!.isEmpty) {
      throw Exception('Upload directory not set');
    }

    final rootDir = Directory(uploadDir!);
    final fileStates = <FileState>[];
    
    await _scanDirectory(rootDir, rootDir, fileStates);
    
    return fileStates;
  }

  Future<void> _scanDirectory(
    Directory rootDir, 
    Directory currentDir, 
    List<FileState> fileStates
  ) async {
    final entities = await currentDir.list(recursive: false).toList();
    
    for (final entity in entities) {
      if (entity is File) {        
        final stat = await entity.stat();
        final relativePath = path.relative(entity.path, from: rootDir.path);
        
        fileStates.add(FileState(
          name: path.basename(entity.path),
          relativePath: relativePath,
          size: stat.size,
          modTime: stat.modified,
        ));
      } else if (entity is Directory) {
        await _scanDirectory(rootDir, entity, fileStates);
      }
    }
  }

  Future<int> synaStartHttpServer() async {
    if (_isServerRunning) {
      return 0;
    }

    if (uploadDir == null || uploadDir!.isEmpty) {
      return -1;
    }

    try {
      _httpServer = await HttpServer.bind(InternetAddress.anyIPv4, port);
      _isServerRunning = true;

      _httpServer!.listen((request) async {
        try {
          if (useToken && apiToken != null) {
            final authHeader = request.headers.value('authorization');
            if (authHeader == null || 
                !authHeader.startsWith('Bearer ') || 
                authHeader.substring(7) != apiToken) {
              request.response
                ..statusCode = 401
                ..headers.contentType = ContentType.json
                ..write(json.encode({'error': 'Invalid token'}));
              await request.response.close();
              return;
            }
          }

          if (request.method == 'POST' && request.uri.path == '/upload') {
            await _handleUpload(request);
          } else if (request.method == 'GET' && request.uri.path == '/list') {
            await _handleList(request);
          } else if (request.method == 'GET' && request.uri.path == '/ping') {
            await _handlePing(request);
          } else if (request.method == 'GET' && request.uri.path.startsWith('/download/')) {
            await _handleDownload(request);
          } else {
            request.response.statusCode = 404;
            await request.response.close();
          }
        } catch (e) {
          print('HTTP server error: $e');
          request.response.statusCode = 500;
          await request.response.close();
        }
      });

      final localIp = await _getLocalIp();
      print('HTTP server running on http://$localIp:$port');
      return 0;
    } catch (e) {
      print('Failed to start HTTP server: $e');
      return -1;
    }
  }

  Future<void> _handleUpload(HttpRequest request) async {
    try {
      final body = await utf8.decoder.bind(request).join();
      
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(json.encode({'message': '上传成功'}));
      await request.response.close();
    } catch (e) {
      request.response
        ..statusCode = 500
        ..headers.contentType = ContentType.json
        ..write(json.encode({'error': '保存文件失败'}));
      await request.response.close();
    }
  }

  String? _extractFilename(String contentDisposition) {
    const prefix = 'filename="';
    final filenameIndex = contentDisposition.indexOf(prefix);
    if (filenameIndex >= 0) {
      final startIndex = filenameIndex + prefix.length;
      final endIndex = contentDisposition.indexOf('"', startIndex);
      if (endIndex >= 0) {
        return contentDisposition.substring(startIndex, endIndex);
      }
    }
    return null;
  }

  Future<void> _handleList(HttpRequest request) async {
    try {
      final files = await synaScan();
      final response = {
        'allFiles': files.map((f) => f.toJson()).toList(),
        'status': 'success',
      };

      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(json.encode(response));
      await request.response.close();
    } catch (e) {
      request.response
        ..statusCode = 500
        ..headers.contentType = ContentType.json
        ..write(json.encode({'error': '扫描目录失败', 'status': 'error'}));
      await request.response.close();
    }
  }

  Future<void> _handlePing(HttpRequest request) async {
    try {
      final localIp = await _getLocalIp();
      final response = {
        'status': 'ok',
        'name': 'Synaesthesia-$localIp',
        'port': port,
        'host': localIp,
      };

      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(json.encode(response));
      await request.response.close();
    } catch (e) {
      request.response
        ..statusCode = 500
        ..headers.contentType = ContentType.json
        ..write(json.encode({'error': 'ping failed', 'status': 'error'}));
      await request.response.close();
    }
  }

  Future<void> _handleDownload(HttpRequest request) async {
    try {
      final requestPath = request.uri.path.substring('/download/'.length);
      final decodedPath = Uri.decodeComponent(requestPath);
      final safePath = _sanitizePath(decodedPath);
      final filePath = path.join(uploadDir!, safePath);
      final file = File(filePath);

      if (!await file.exists()) {
        request.response
          ..statusCode = 404
          ..headers.contentType = ContentType.json
          ..write(json.encode({'error': '文件不存在'}));
        await request.response.close();
        return;
      }

      final fileAbs = await file.absolute;
      final uploadAbs = await Directory(uploadDir!).absolute;
      if (!fileAbs.path.startsWith(uploadAbs.path)) {
        request.response
          ..statusCode = 403
          ..headers.contentType = ContentType.json
          ..write(json.encode({'error': '非法文件路径'}));
        await request.response.close();
        return;
      }

      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.binary
        ..headers.add('Content-Disposition', 'attachment; filename="${path.basename(filePath)}"');

      final fileStream = file.openRead();
      await request.response.addStream(fileStream);
      await request.response.close();
    } catch (e) {
      request.response
        ..statusCode = 500
        ..headers.contentType = ContentType.json
        ..write(json.encode({'error': '下载文件失败'}));
      await request.response.close();
    }
  }

  // Public method to sanitize path for testing
  String _sanitizePath(String pathStr) {
    var safePath = pathStr.replaceAll('../', '').replaceAll('..\\', '');
    if (safePath.startsWith('/')) {
      safePath = safePath.substring(1);
    }
    if (safePath.startsWith('\\')) {
      safePath = safePath.substring(1);
    }
    return safePath;
  }

  // Public wrapper for testing
  String sanitizePathForTesting(String pathStr) => _sanitizePath(pathStr);

  Future<int> synaStopHttpServer() async {
    if (_httpServer != null) {
      await _httpServer!.close();
      _httpServer = null;
      _isServerRunning = false;
    }
    return 0;
  }

  Future<Map<String, dynamic>?> loadConfig() async {
    try {
      final configFilePath = await _getConfigFilePath();
      final configFile = File(configFilePath);
      
      if (!await configFile.exists()) {
        return null;
      }
      
      final configData = await configFile.readAsString();
      return json.decode(configData) as Map<String, dynamic>;
    } catch (e) {
      print('loadConfig error: $e');
      return null;
    }
  }

  Future<int> synaUpload(String filePath, String uploadHost) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        return -1;
      }

      final dio = Dio();
      final formData = FormData.fromMap({
        'file': await MultipartFile.fromFile(filePath, filename: path.basename(filePath)),
      });

      final options = Options(
        method: 'POST',
        headers: useToken && apiToken != null ? {'Authorization': 'Bearer $apiToken'} : {},
      );

      final response = await dio.request('$uploadHost/upload', data: formData, options: options);
      
      if (response.statusCode != 200) {
        print('Upload failed: ${response.data}');
        return -7;
      }

      return 0;
    } catch (e) {
      print('Upload error: $e');
      return -7;
    }
  }

  Future<Map<String, dynamic>> synaCompareChanges(String remoteHost, String token) async {
    try {
      final dio = Dio();
      final remoteUrl = '$remoteHost/list';
      final remoteHeaders = <String, String>{};
      
      if (useToken) {
        final authToken = token.isNotEmpty ? token : apiToken;
        if (authToken != null) {
          remoteHeaders['Authorization'] = 'Bearer $authToken';
        }
      }

      final response = await dio.get(remoteUrl, options: Options(headers: remoteHeaders));
      if (response.statusCode != 200) {
        throw Exception('Remote list request failed with status: ${response.statusCode}');
      }

      final remoteData = response.data;
      if (remoteData['status'] != 'success') {
        throw Exception('Remote response status is not success');
      }

      final remoteFiles = (remoteData['allFiles'] as List)
          .map((f) => FileState.fromJson(f))
          .toList();

      final localFiles = await synaScan();

      final remotePathMap = {
        for (var file in remoteFiles) file.relativePath: file
      };

      final missingOnRemote = <FileState>[];
      for (final localFile in localFiles) {
        if (!remotePathMap.containsKey(localFile.relativePath)) {
          missingOnRemote.add(localFile);
        }
      }

      return {
        'missingOnRemote': missingOnRemote.map((f) => f.toJson()).toList(),
        'localCount': localFiles.length,
        'remoteCount': remoteFiles.length,
        'missingCount': missingOnRemote.length,
        'status': 'success',
      };
    } catch (e) {
      return {
        'error': '比较失败: $e',
        'status': 'error',
      };
    }
  }
}