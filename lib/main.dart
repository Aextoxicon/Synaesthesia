import 'dart:async';
import 'dart:io';
import 'dart:collection';
import 'dart:math';
import 'watcher.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;

enum SyncMode { server, client }

void main() {
  runApp(const MyApp());
}

//日志管理
class LogManager {
  static final LogManager _instance = LogManager._internal();
  factory LogManager() => _instance;
  LogManager._internal();

  final ListQueue<String> _logs = ListQueue<String>();
  final Set<VoidCallback> _listeners = <VoidCallback>{};

  static const int maxLogLines = 100; // 最大日志行数

  void log(String message) {
    final timestamp = DateTime.now().toString().split('.').first;
    final logMessage = '[$timestamp] $message';

    _logs.addLast(logMessage);

    if (_logs.length > maxLogLines) {
      _logs.removeFirst();
    }
    for (final listener in _listeners.toList()) {
      listener();
    }
  }

  List<String> getLogs() => _logs.toList();

  void clearLogs() {
    _logs.clear();
    for (final listener in _listeners.toList()) {
      listener();
    }
  }

  void addListener(VoidCallback listener) {
    _listeners.add(listener);
  }

  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
  }
}

// 用于输出到UI
void _log(String message) {
  LogManager().log(message);
  print(message);
}

// 格式化字节数
String formatBytes(int bytes, {int decimalPlaces = 2}) {
  if (bytes == 0) return '0 B';

  const List<String> units = [
    'B',
    'KB',
    'MB',
    'GB',
    'TB',
    'PB',
    'EB',
    'ZB',
    'YB',
  ];
  const double base = 1024;

  int exponent = (log(bytes) / log(base)).floor();
  exponent = exponent.clamp(0, units.length - 1);

  double value = bytes / pow(base, exponent);
  return '${value.toStringAsFixed(decimalPlaces)} ${units[exponent]}';
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (context) => MyAppState(),
      child: MaterialApp(
        title: 'flutter-demo',
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        ),
        home: const Pages(),
      ),
    );
  }
}

//页面定义
class Pages extends StatelessWidget {
  const Pages({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<MyAppState>(
      builder: (context, appState, child) {
        return Scaffold(
          body: IndexedStack(
            index: appState.currentIdx,
            children: const [SyncPage(), WatcherPage()],
          ),
          bottomNavigationBar: BottomNavigationBar(
            currentIndex: appState.currentIdx,
            onTap: (index) => appState.setIdx(index),
            items: const [
              BottomNavigationBarItem(icon: Icon(Icons.devices), label: '设备发现'),
              BottomNavigationBarItem(icon: Icon(Icons.folder), label: '文件监控'),
            ],
          ),
        );
      },
    );
  }
}

//APP本体的功能以及服务调用
class MyAppState extends ChangeNotifier {
  var currentIdx = 0;
  String lastEvent = "No event yet";
  String watchPath = "";
  final watcherd _watcher = watcherd();
  final List<String> eventHistory = [];

  SyncMode syncMode = SyncMode.server;

  Map<String, dynamic>? _cachedLocalFiles;
  Map<String, dynamic>? _cachedRemoteFiles;
  DateTime? _localCacheTime;
  DateTime? _remoteCacheTime;
  static const Duration cacheDuration = Duration(seconds: 30); // 30秒缓存时间

  void setSyncMode(SyncMode mode) {
    syncMode = mode;
    notifyListeners();
  }

  // HTTP服务器
  bool isHTTPRunning = false;
  int httpPort = 8080;
  HttpServer? httpServer;

  // HTTP客户端
  String httpHost = 'localhost';
  int httpPortC = 8080;

  String httpUser = 'user';
  String httpPwd = 'pwd123';

  String localIPAddress = 'localhost';

  MyAppState() {
    _watcher.onEvent.listen((event) {
      if (event.containsKey('event')) {
        final jsonEvent = jsonDecode(event['event']!);
        String formattedEvent = '';

        if (jsonEvent['type'] == 'error') {
          formattedEvent =
              '错误: ${jsonEvent['message']} (${jsonEvent['timestamp']})';
        } else {
          formattedEvent =
              '${jsonEvent['type']}: ${jsonEvent['path']} (${jsonEvent['timestamp']})';
        }

        updateLastEvent(formattedEvent);
        clearFileCache();
      }
    });
    getLocalIPAddress();
  }

  void setWatchPath(String path) {
    watchPath = path;
    _watcher.startWatch(path);
    notifyListeners();
  }

  void updateLastEvent(String event) {
    eventHistory.insert(0, event);
    if (eventHistory.length > 100) {
      eventHistory.removeLast();
    }
    lastEvent = event;
    notifyListeners();
  }

  void setIdx(int idx) {
    currentIdx = idx;
    notifyListeners();
  }

  Future<void> getLocalIPAddress() async {
    try {
      final List<NetworkInterface> interfaces = await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
      );

      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          // 选择一个非回环的IPv4地址
          if (address.type == InternetAddressType.IPv4 &&
              !address.isLoopback &&
              !address.isLinkLocal) {
            localIPAddress = address.address;
            notifyListeners();
            return;
          }
        }
      }
    } catch (e) {
      print('获取本机IP地址失败: $e');
    }
  }

  // 启动HTTP服务器
  void startHTTP() async {
    if (watchPath.isEmpty) {
      print('请先选择要同步的目录');
      return;
    }

    bool _checkAuth(HttpRequest request) {
      final authHeader = request.headers.value('authorization');
      if (authHeader == null || !authHeader.startsWith('Basic ')) {
        return false;
      }

      final encodedAuth = authHeader.substring(6);
      try {
        final decodedAuth = utf8.decode(base64Decode(encodedAuth));
        final parts = decodedAuth.split(':');
        if (parts.length != 2) {
          return false;
        }

        final user = parts[0];
        final pwd = parts[1];

        return user == httpUser && pwd == httpPwd;
      } catch (e) {
        print('认证解析失败: $e');
        return false;
      }
    }

    Future<void> _fileUpload(HttpRequest request, String path) async {
      IOSink? sink;
      try {
        print('开始处理文件上传请求，路径: $path');

        // 确保路径正确连接，处理路径分隔符问题
        final normalizedPath = path.startsWith('/') ? path.substring(1) : path;
        print('标准化路径: $normalizedPath');

        // 构造完整文件路径
        final filePath = '$watchPath${Platform.pathSeparator}$normalizedPath'
            .replaceAll('/', Platform.pathSeparator)
            .replaceAll('\\', Platform.pathSeparator)
            .replaceAll(
              '${Platform.pathSeparator}${Platform.pathSeparator}',
              Platform.pathSeparator,
            );

        final file = File(filePath);
        print('准备接收上传文件: $filePath');
        print('监控路径: $watchPath');

        // 检查父目录是否存在，如果不存在则创建
        final parentDir = file.parent;
        print('父目录路径: ${parentDir.path}');

        try {
          if (!await parentDir.exists()) {
            print('父目录不存在，正在创建...');
            await parentDir.create(recursive: true);
            print('创建目录成功: ${parentDir.path}');
          } else {
            print('父目录已存在: ${parentDir.path}');
          }
        } catch (dirError) {
          print('创建目录失败: $dirError');
          request.response
            ..statusCode = HttpStatus.internalServerError
            ..write('Failed to create directory: $dirError')
            ..close();
          return;
        }

        // 流式写入文件
        try {
          print('开始流式写入文件...');
          sink = file.openWrite();
          int totalBytes = 0;
          await for (var data in request) {
            sink.add(data);
            totalBytes += data.length;
          }
          await sink.close();
          print('文件写入成功: $filePath, 总大小: $totalBytes 字节');
        } catch (writeError) {
          await sink?.close();
          if (await file.exists()) {
            await file.delete();
          }
          rethrow;
        }

        // 返回成功响应
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.set('Content-Type', 'text/plain; charset=utf-8')
          ..write('File uploaded successfully')
          ..close();

        print('文件上传完成: $filePath');
      } catch (e, stackTrace) {
        // 关闭
        await sink?.close();
        print('文件上传过程中发生未处理的异常: $e');
        print('详细堆栈信息: $stackTrace');
        try {
          request.response
            ..statusCode = HttpStatus.internalServerError
            ..headers.set('Content-Type', 'text/plain; charset=utf-8')
            ..write('File upload failed: $e')
            ..close();
        } catch (responseError) {
          print('发送错误响应失败: $responseError');
        }
      }
    }

    try {
      // 绑定所有接口
      httpServer = await HttpServer.bind(InternetAddress.anyIPv4, httpPort);

      httpServer!.listen((HttpRequest request) async {
        bool isAuthenticated = true;
        if (httpUser.isNotEmpty && httpPwd.isNotEmpty) {
          isAuthenticated = _checkAuth(request);
        }

        if (!isAuthenticated) {
          request.response
            ..statusCode = HttpStatus.unauthorized
            ..headers.set('WWW-Authenticate', 'Basic realm="flutter-demo"')
            ..write('Unauthorized')
            ..close();
          return;
        }

        final path = request.uri.path;

        // API
        if (path.startsWith('/api/')) {
          await _apiRequest(request, path);
          return;
        }

        // 文件列表
        if (path == '/.scan_result.json') {
          await _jsonRequest(request);
          return;
        }

        // PUT
        if (request.method == 'PUT') {
          await _fileUpload(request, path);
          return;
        }

        // 根路径
        if (path == '/' || path.isEmpty) {
          final dir = Directory(watchPath);
          final entities = await dir.list().toList();

          final StringBuffer buffer = StringBuffer();
          buffer.write('<html><head><title>文件列表</title></head><body>');
          buffer.write('<h1>目录内容</h1><ul>');

          for (final entity in entities) {
            final name = entity.uri.pathSegments.last;
            final isDir = entity is Directory ? '📁' : '📄';
            buffer.write('<li>$isDir <a href="$name">$name</a></li>');
          }

          buffer.write('</ul></body></html>');

          request.response
            ..headers.contentType = ContentType.html
            ..write(buffer.toString())
            ..close();
        } else {
          String normalizedPath = path;
          if (normalizedPath.startsWith('/')) {
            normalizedPath = normalizedPath.substring(1);
          }

          // 构造文件路径
          final filePath = '$watchPath${Platform.pathSeparator}$normalizedPath'
              .replaceAll('/', Platform.pathSeparator)
              .replaceAll('\\', Platform.pathSeparator)
              .replaceAll(
                '${Platform.pathSeparator}${Platform.pathSeparator}',
                Platform.pathSeparator,
              );

          final file = File(filePath);

          print('尝试提供文件: $filePath (原始请求路径: $path, 监控路径: $watchPath)');

          if (await file.exists()) {
            print('文件存在，开始传输: $filePath');
            // 响应头
            request.response.headers.contentType = _getContentType(filePath);

            // Content-Length头
            final length = await file.length();
            request.response.headers.set('Content-Length', length.toString());

            // 发送
            await request.response.addStream(file.openRead());
            await request.response.close();
            print('文件传输完成: $filePath');
          } else {
            print('文件不存在: $filePath');
            print('监控路径: $watchPath');
            print('请求路径: $path');
            print('标准化路径: $normalizedPath');
            request.response
              ..statusCode = HttpStatus.notFound
              ..headers.contentType = ContentType.html
              ..write(
                '<html><body><h1>404 - 文件未找到</h1><p>请求的文件 $path 不存在</p><p>完整路径: $filePath</p></body></html>',
              )
              ..close();
          }
        }
      });

      isHTTPRunning = true;
      notifyListeners();
      print('HTTP服务器已启动，端口: $httpPort');
      // 更新本机IP
      getLocalIPAddress();
    } catch (e) {
      print('启动HTTP服务器失败: $e');
    }
  }

  // 根据后缀确定内容类型
  ContentType _getContentType(String filePath) {
    final lowerPath = filePath.toLowerCase();
    if (lowerPath.endsWith('.json')) {
      return ContentType('application', 'json');
    } else if (lowerPath.endsWith('.html') || lowerPath.endsWith('.htm')) {
      return ContentType('text', 'html');
    } else if (lowerPath.endsWith('.css')) {
      return ContentType('text', 'css');
    } else if (lowerPath.endsWith('.js')) {
      return ContentType('application', 'javascript');
    } else if (lowerPath.endsWith('.png')) {
      return ContentType('image', 'png');
    } else if (lowerPath.endsWith('.jpg') || lowerPath.endsWith('.jpeg')) {
      return ContentType('image', 'jpeg');
    } else if (lowerPath.endsWith('.gif')) {
      return ContentType('image', 'gif');
    } else {
      return ContentType('application', 'octet-stream');
    }
  }

  // 处理API
  Future<void> _apiRequest(HttpRequest request, String path) async {
    if (path == '/api/file-list') {
      await _fileListRequest(request);
    } else {
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('API未找到')
        ..close();
    }
  }

  // 处理文件列表
  Future<void> _jsonRequest(HttpRequest request) async {
    try {
      final fileMap = await _scanDir(watchPath);
      final jsonResponse = jsonEncode(fileMap);

      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonResponse)
        ..close();
    } catch (e) {
      print('生成文件列表失败: $e');
      request.response
        ..statusCode = HttpStatus.internalServerError
        ..write('{"error": "Internal server error"}')
        ..close();
    }
  }

  // 处理文件列表API
  Future<void> _fileListRequest(HttpRequest request) async {
    try {
      final fileMap = await _scanDir(watchPath);
      final jsonResponse = jsonEncode(fileMap);

      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonResponse)
        ..close();
    } catch (e) {
      print('生成文件列表失败: $e');
      request.response
        ..statusCode = HttpStatus.internalServerError
        ..write('{"error": "Internal server error"}')
        ..close();
    }
  }

  // 扫描目录结构
  Future<Map<String, dynamic>> _scanDir(String rootPath) async {
    final fileMap = <String, dynamic>{};
    final dir = Directory(rootPath);

    if (!await dir.exists()) {
      return fileMap;
    }

    await _scanDirForApi(dir, rootPath, fileMap);
    return fileMap;
  }

  // 生成API响应
  Future<void> _scanDirForApi(
    Directory dir,
    String rootPath,
    Map<String, dynamic> fileMap,
  ) async {
    try {
      await for (final FileSystemEntity entity in dir.list()) {
        // 相对路径
        final relativePath = entity.path
            .replaceFirst(rootPath, '')
            .replaceAll('\\', '/');
        if (relativePath.isEmpty) continue;

        final normalizedPath = relativePath.startsWith('/')
            ? relativePath
            : '/$relativePath';

        print(
          '扫描到文件/目录: 路径=$normalizedPath, 完整路径=${entity.path}, 类型=${entity.runtimeType}',
        );

        if (entity is Directory) {
          final dirInfo = {
            'type': 'directory',
            'path': normalizedPath,
            'children': <dynamic>[],
          };

          await _scanDirForApi(
            entity,
            rootPath,
            dirInfo as Map<String, dynamic>,
          );

          fileMap[normalizedPath] = dirInfo;
        } else if (entity is File) {
          final stat = await entity.stat();
          fileMap[normalizedPath] = {
            'type': 'file',
            'path': normalizedPath,
            'size': stat.size,
            'modified': stat.modified.toIso8601String(),
          };
        }
      }
    } catch (e) {
      print('扫描目录时出错: $e');
    }
  }

  // 停止HTTP服务器
  void stopHTTP() {
    httpServer?.close();
    isHTTPRunning = false;
    httpServer = null;
    notifyListeners();
    print('HTTP服务器已停止');
  }

  // 使用HTTP同步
  Future<bool> httpUpload() async {
    LogManager().clearLogs();
    _log('开始上传文件到服务器');

    if (watchPath.isEmpty) {
      _log('请先选择本地目录');
      return false;
    }

    try {
      _log('正在获取文件差异结果...');
      final diffResult = await diffScanResults();

      if (diffResult.containsKey('error')) {
        _log('获取差异结果失败: ${diffResult['error']}');
        return false;
      }

      // 获取服务器上缺失的文件列表（仅在本地存在的文件）
      final onlyLocal = List<String>.from(diffResult['onlyLocal'] as List);
      final different = List<Map<String, dynamic>>.from(
        diffResult['different'] as List,
      );

      // 合并仅本地存在的文件和修改时间不同的文件
      final fileUpload = <String>[];
      fileUpload.addAll(onlyLocal);
      fileUpload.addAll(different.map((item) => item['path'] as String));

      if (fileUpload.isEmpty) {
        _log('没有需要上传的文件');
        eventHistory.insert(
          0,
          '没有需要上传的文件 (${DateTime.now().toIso8601String()})',
        );
        if (eventHistory.length > 100) {
          eventHistory.removeLast();
        }
        notifyListeners();
        return true;
      }

      _log('准备流式上传 ${fileUpload.length} 个文件到服务器');

      bool success = true;
      int upCount = 0;

      // 上传缺失文件
      for (final filePath in fileUpload) {
        try {
          final normalizedRelativePath = filePath.startsWith('/')
              ? filePath.substring(1)
              : filePath;
          final fullPath = '$watchPath/$normalizedRelativePath'
              .replaceAll('//', '/')
              .replaceAll('\\', '/');
          final file = File(fullPath);

          _log('检查文件是否存在: $fullPath');
          if (!await file.exists()) {
            _log('文件不存在: $fullPath');
            eventHistory.insert(
              0,
              '文件不存在: $fullPath (${DateTime.now().toIso8601String()})',
            );
            if (eventHistory.length > 100) {
              eventHistory.removeLast();
            }
            success = false;
            continue;
          }

          // 构造URL
          final urlPath = filePath.startsWith('/') ? filePath : '/$filePath';
          final url = Uri.http('$httpHost:$httpPortC', urlPath);

          // 进度显示
          final fileName = file.uri.pathSegments.last;
          _log('开始流式上传文件: $fileName 到 $url');

          // 请求头
          final Map<String, String> headers = {};
          if (httpUser.isNotEmpty && httpPwd.isNotEmpty) {
            final auth = base64Encode(utf8.encode('$httpUser:$httpPwd'));
            headers['authorization'] = 'Basic $auth';
          }

          // 流式上传
          final client = HttpClient();
          final request = await client.openUrl('PUT', url);

          // 设置头
          headers.forEach((key, value) {
            request.headers.set(key, value);
          });

          // 设置长度
          final length = await file.length();
          request.headers.set('Content-Length', length.toString());

          // 流式发送内容
          final stream = file.openRead();
          int bytesSent = 0;

          // 创建带进度监控的流
          final progressStream = stream.transform(
            StreamTransformer<List<int>, List<int>>.fromHandlers(
              handleData: (data, sink) {
                bytesSent += data.length;
                if (bytesSent % (1024 * 1024) == 0) {
                  // 每MB显示一次进度
                  final progress = length > 0 ? (bytesSent / length) * 100 : 0;
                  _log(
                    '上传进度 [$fileName]: ${progress.toStringAsFixed(1)}% ($bytesSent/$length 字节)',
                  );
                }
                sink.add(data);
              },
            ),
          );

          await progressStream.pipe(request);

          final response = await request.close();

          _log('收到服务器响应，状态码: ${response.statusCode}');

          if (response.statusCode == 200 || response.statusCode == 201) {
            upCount++;
            _log('文件流式上传成功: $fileName');
            eventHistory.insert(
              0,
              '文件上传成功: $fileName (${DateTime.now().toIso8601String()})',
            );
          } else if (response.statusCode == HttpStatus.unauthorized) {
            _log('文件上传失败: 认证失败 ($fileName)');
            eventHistory.insert(
              0,
              '文件上传失败: 认证失败 ($fileName) (${DateTime.now().toIso8601String()})',
            );
            success = false;
          } else {
            _log('文件上传失败，状态码: ${response.statusCode} ($fileName)');
            final errorBody = await response.transform(utf8.decoder).join();
            _log('错误响应内容: $errorBody');
            eventHistory.insert(
              0,
              '文件上传失败: 状态码 ${response.statusCode} ($fileName) (${DateTime.now().toIso8601String()})',
            );
            success = false;
          }
        } catch (e) {
          _log('处理文件时发生错误: $e');
          eventHistory.insert(
            0,
            '处理文件时发生错误: $e ($filePath) (${DateTime.now().toIso8601String()})',
          );
          success = false;
        }

        if (eventHistory.length > 100) {
          eventHistory.removeLast();
        }
      }

      notifyListeners();

      _log('上传完成，成功上传 $upCount/${fileUpload.length} 个文件');
      eventHistory.insert(
        0,
        '上传完成，成功上传 $upCount/${fileUpload.length} 个文件 (${DateTime.now().toIso8601String()})',
      );
      if (eventHistory.length > 100) {
        eventHistory.removeLast();
      }
      notifyListeners();

      return success;
    } catch (e, stackTrace) {
      _log('HTTP流式上传失败: $e');
      _log('详细错误信息: $stackTrace');
      eventHistory.insert(
        0,
        'HTTP上传失败: $e (${DateTime.now().toIso8601String()})',
      );
      if (eventHistory.length > 100) {
        eventHistory.removeLast();
      }
      notifyListeners();
      return false;
    }
  }

  // 下载远程缺失的文件（流式传输版本，带文件名的进度显示，但是出现了点问题暂时搁置，目前没有实际作用）
  Future<bool> httpDownload() async {
    if (watchPath.isEmpty) {
      print('请先选择本地目录');
      return false;
    }

    try {
      final diffResult = await diffScanResults();

      if (diffResult.containsKey('error')) {
        print('获取差异结果失败: ${diffResult['error']}');
        return false;
      }

      final remoteFiles = await _scanRemoteFiles();

      if (remoteFiles.containsKey('error')) {
        print('获取远程文件列表失败: ${remoteFiles['error']}');
        return false;
      }

      final onlyRemote = List<String>.from(diffResult['onlyRemote'] as List);
      final different = List<Map<String, dynamic>>.from(
        diffResult['different'] as List,
      );

      final fileDownload = <String>[];

      for (final path in onlyRemote) {
        final remoteFile = remoteFiles[path];
        if (remoteFile != null && remoteFile['type'] == 'file') {
          fileDownload.add(path);
        }
      }

      for (final item in different) {
        final path = item['path'] as String;
        final remoteFile = remoteFiles[path];
        if (remoteFile != null && remoteFile['type'] == 'file') {
          fileDownload.add(path);
        }
      }

      if (fileDownload.isEmpty) {
        print('没有需要下载的文件');
        eventHistory.insert(
          0,
          '没有需要下载的文件 (${DateTime.now().toIso8601String()})',
        );
        if (eventHistory.length > 100) {
          eventHistory.removeLast();
        }
        notifyListeners();
        return true;
      }

      print('准备从服务器流式下载 ${fileDownload.length} 个文件');

      bool success = true;
      int downCount = 0;

      for (final filePath in fileDownload) {
        try {
          final urlPath = filePath.startsWith('/') ? filePath : '/$filePath';
          final url = Uri.http('$httpHost:$httpPortC', urlPath);

          final fileName = filePath.split('/').last;
          print('开始从 $url 流式下载文件: $fileName');

          final Map<String, String> headers = {};
          if (httpUser.isNotEmpty && httpPwd.isNotEmpty) {
            final auth = base64Encode(utf8.encode('$httpUser:$httpPwd'));
            headers['authorization'] = 'Basic $auth';
          }

          final client = HttpClient();
          final request = await client.getUrl(url);

          headers.forEach((key, value) {
            request.headers.set(key, value);
          });

          final response = await request.close();

          print('收到服务器响应，状态码: ${response.statusCode}');

          if (response.statusCode == 200) {
            final normalizedRelativePath = filePath.startsWith('/')
                ? filePath.substring(1)
                : filePath;
            final localFilePath =
                '$watchPath${Platform.pathSeparator}$normalizedRelativePath'
                    .replaceAll('/', Platform.pathSeparator)
                    .replaceAll('\\', Platform.pathSeparator)
                    .replaceAll(
                      '${Platform.pathSeparator}${Platform.pathSeparator}',
                      Platform.pathSeparator,
                    );
            final localFile = File(localFilePath);

            final parentDir = localFile.parent;
            try {
              if (!await parentDir.exists()) {
                print('父目录不存在，正在创建...');
                await parentDir.create(recursive: true);
                print('创建目录成功: ${parentDir.path}');
              } else {
                print('父目录已存在: ${parentDir.path}');
              }
            } catch (dirError) {
              print('创建目录失败: $dirError');
              eventHistory.insert(
                0,
                '创建目录失败: $dirError ($fileName) (${DateTime.now().toIso8601String()})',
              );
              success = false;
              continue;
            }

            // 写入文件
            final totalBytes = response.contentLength ?? 0;
            print('文件大小: $totalBytes 字节');

            final fileSink = localFile.openWrite();
            int bytesReceived = 0;

            // 创建带进度监控的流
            final progressStream = response.transform(
              StreamTransformer<List<int>, List<int>>.fromHandlers(
                handleData: (data, sink) {
                  bytesReceived += data.length;
                  if (totalBytes > 0 && bytesReceived % (1024 * 1024) == 0) {
                    // 每MB显示一次进度
                    final progress = (bytesReceived / totalBytes) * 100;
                    print(
                      '下载进度 [$fileName]: ${progress.toStringAsFixed(1)}% ($bytesReceived/$totalBytes 字节)',
                    );
                  }
                  sink.add(data);
                },
              ),
            );

            await progressStream.pipe(fileSink);

            print('文件流式下载成功: $fileName');
            downCount++;
            eventHistory.insert(
              0,
              '文件下载成功: $fileName (${DateTime.now().toIso8601String()})',
            );
          } else if (response.statusCode == HttpStatus.unauthorized) {
            print('文件下载失败: 认证失败 ($fileName)');
            eventHistory.insert(
              0,
              '文件下载失败: 认证失败 ($fileName) (${DateTime.now().toIso8601String()})',
            );
            success = false;
          } else if (response.statusCode == HttpStatus.notFound) {
            print('文件下载失败: 远程文件不存在 $fileName');
            print('请求URL: $url');
            eventHistory.insert(
              0,
              '文件下载失败: 远程文件不存在 ($fileName) (${DateTime.now().toIso8601String()})',
            );
            success = false;
          } else {
            print('文件下载失败，状态码: ${response.statusCode} ($fileName)');
            // 读取错误响应体
            final errorBody = await response.transform(utf8.decoder).join();
            print('错误响应内容: $errorBody');
            eventHistory.insert(
              0,
              '文件下载失败: 状态码 ${response.statusCode} ($fileName) (${DateTime.now().toIso8601String()})',
            );
            success = false;
          }
        } catch (e) {
          print('处理文件时发生错误: $e');
          eventHistory.insert(
            0,
            '处理文件时发生错误: $e ($filePath) (${DateTime.now().toIso8601String()})',
          );
          success = false;
        }

        if (eventHistory.length > 100) {
          eventHistory.removeLast();
        }
      }

      notifyListeners();

      print('下载完成，成功下载 $downCount/${fileDownload.length} 个文件');
      eventHistory.insert(
        0,
        '下载完成，成功下载 $downCount/${fileDownload.length} 个文件 (${DateTime.now().toIso8601String()})',
      );
      if (eventHistory.length > 100) {
        eventHistory.removeLast();
      }
      notifyListeners();

      return success;
    } catch (e, stackTrace) {
      print('HTTP流式下载失败: $e');
      print('详细错误信息: $stackTrace');
      eventHistory.insert(
        0,
        'HTTP下载失败: $e (${DateTime.now().toIso8601String()})',
      );
      if (eventHistory.length > 100) {
        eventHistory.removeLast();
      }
      notifyListeners();
      return false;
    }
  }

  Timer? _diffTimer;

  // 定时比较

  Future<Map<String, dynamic>> diffScanResults() async {
    if (watchPath.isEmpty) {
      print('请先选择本地目录');
      return {'error': '请先选择本地目录'};
    }

    try {
      final localFiles = await _scanLocalFiles();

      final remoteFiles = await _scanRemoteFiles();

      if (remoteFiles.containsKey('error')) {
        return remoteFiles;
      }

      print('本地文件数量: ${localFiles.length}');
      print('远程文件数量: ${remoteFiles.length}');
      if (localFiles.isNotEmpty) {
        print('前几个本地文件路径: ${localFiles.keys.take(5).toList()}');
      }
      if (remoteFiles.isNotEmpty) {
        print('前几个远程文件路径: ${remoteFiles.keys.take(5).toList()}');
      }

      final onlyLocal = localFiles.keys
          .where((path) => !remoteFiles.containsKey(path))
          .toList();

      final onlyRemote = remoteFiles.keys
          .where((path) => !localFiles.containsKey(path))
          .toList();

      final commonPaths = localFiles.keys
          .where((path) => remoteFiles.containsKey(path))
          .toList();
      final different = <Map<String, dynamic>>[];

      for (final path in commonPaths) {
        final localFile = localFiles[path]!;
        final remoteFile = remoteFiles[path]!;
        //跳过目录
        if (remoteFile['type'] == 'file' && localFile is File) {
          try {
            final localModified = localFile.statSync().modified;
            final remoteModified = DateTime.parse(remoteFile['modified']);

            // 如果修改时间差异超过1秒，认为是不同的
            if (localModified.difference(remoteModified).inSeconds.abs() > 1) {
              different.add({
                'path': path,
                'localModified': localModified.toIso8601String(),
                'remoteModified': remoteModified.toIso8601String(),
              });
            }
          } catch (e) {
            print('比较文件修改时间失败 $path: $e');
          }
        }
      }

      print('仅在本地存在的文件数量: ${onlyLocal.length}');
      if (onlyLocal.isNotEmpty) {
        print('前几个仅在本地存在的文件: ${onlyLocal.take(5).toList()}');
      }

      print('仅在远程存在的文件数量: ${onlyRemote.length}');
      if (onlyRemote.isNotEmpty) {
        print('前几个仅在远程存在的文件: ${onlyRemote.take(5).toList()}');
      }

      print('修改时间不同的文件数量: ${different.length}');
      if (different.isNotEmpty) {
        print(
          '前几个修改时间不同的文件: ${different.take(5).map((d) => d['path']).toList()}',
        );
      }

      return {
        'onlyLocal': onlyLocal,
        'onlyRemote': onlyRemote,
        'different': different,
      };
    } catch (e, stackTrace) {
      print('比较文件失败: $e');
      print('详细错误信息: $stackTrace');
      return {'error': '比较文件失败: $e'};
    }
  }

  Future<Map<String, File>> _scanLocalFiles() async {
    if (_cachedLocalFiles != null &&
        _localCacheTime != null &&
        DateTime.now().difference(_localCacheTime!) < cacheDuration) {
      print('使用本地文件缓存，缓存时间: $_localCacheTime');
      // 将缓存的 Map<String, dynamic> 转换回 Map<String, File>
      final Map<String, File> fileMap = {};
      _cachedLocalFiles!.forEach((path, info) {
        if (info is File) {
          fileMap[path] = info;
        }
      });
      return fileMap;
    }

    print('重新扫描本地文件（跳过缓存）');
    final files = <String, File>{};
    final dir = Directory(watchPath);

    if (!await dir.exists()) {
      // 更新缓存
      _cachedLocalFiles = {};
      _localCacheTime = DateTime.now();
      return files;
    }

    try {
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File) {
          final relativePath = entity.path
              .replaceFirst(watchPath, '')
              .replaceAll('\\', '/')
              .replaceAll('//', '/');
          final normalizedPath = relativePath.startsWith('/')
              ? relativePath
              : '/$relativePath';
          files[normalizedPath] = entity;
        }
      }
    } catch (e) {
      print('扫描本地文件失败: $e');
    }

    // 更新缓存
    _cachedLocalFiles = Map<String, dynamic>.from(files);
    _localCacheTime = DateTime.now();
    print('更新本地文件缓存，文件数量: ${files.length}');

    return files;
  }

  void clearFileCache() {
    _cachedLocalFiles = null;
    _cachedRemoteFiles = null;
    _localCacheTime = null;
    _remoteCacheTime = null;
    print('文件缓存已清除');
  }

  // 手动刷新缓存
  Future<void> refreshFileCache() async {
    print('手动刷新文件缓存');
    clearFileCache();
    await _scanLocalFiles();
    await _scanRemoteFiles();
  }

  Future<Map<String, dynamic>> _scanRemoteFiles() async {
    if (_cachedRemoteFiles != null &&
        _remoteCacheTime != null &&
        DateTime.now().difference(_remoteCacheTime!) < cacheDuration) {
      print('使用远程文件缓存，缓存时间: $_remoteCacheTime');
      return _cachedRemoteFiles!;
    }

    print('重新获取远程文件列表（跳过缓存）');
    try {
      final url = Uri.http('$httpHost:$httpPortC', '/api/file-list');
      print('开始从 $url 获取远程文件列表');

      final Map<String, String> headers = {};
      if (httpUser.isNotEmpty && httpPwd.isNotEmpty) {
        final auth = base64Encode(utf8.encode('$httpUser:$httpPwd'));
        headers['authorization'] = 'Basic $auth';
      }

      http.Response? response;
      int retryCount = 0;
      const maxRetry = 3;

      while (retryCount <= maxRetry) {
        try {
          response = await http
              .get(url, headers: headers)
              .timeout(Duration(seconds: 15));
          break;
        } catch (e) {
          retryCount++;
          if (retryCount > maxRetry) {
            rethrow;
          }
          print('请求失败，正在重试 ($retryCount/$maxRetry): $e');
          await Future.delayed(Duration(seconds: 2 * retryCount));
        }
      }

      if (response == null) {
        print('HTTP请求失败: 无响应');
        return {'error': 'HTTP请求失败: 无响应'};
      }

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is Map<String, dynamic>) {
          print('接收到远程文件列表，文件数量: ${data.length}');
          if (data.isNotEmpty) {
            print('前几个远程文件: ${data.keys.take(5).toList()}');
            final firstKey = data.keys.first;
            print('第一个文件信息: key=$firstKey, value=${data[firstKey]}');
          }

          // 更新缓存
          _cachedRemoteFiles = data;
          _remoteCacheTime = DateTime.now();
          print('更新远程文件缓存，文件数量: ${data.length}');

          // 确保路径格式一致，都以 '/' 开头
          final normalizedData = <String, dynamic>{};
          data.forEach((path, info) {
            final normalizedPath = path.startsWith('/') ? path : '/$path';
            normalizedData[normalizedPath] = info;
          });

          return normalizedData;
        } else {
          print('远程响应数据格式不正确: $data');
          return {};
        }
      } else if (response.statusCode == HttpStatus.unauthorized) {
        print('获取远程数据失败: 认证失败');
        return {'error': '认证失败'};
      } else {
        print('获取远程数据失败，状态码: ${response.statusCode}');
        print('响应内容: ${response.body}');
        return {'error': '获取远程数据失败，状态码: ${response.statusCode}'};
      }
    } catch (e, stackTrace) {
      print('获取远程文件列表失败: $e');
      print('详细错误信息: $stackTrace');
      return {'error': '获取远程文件列表失败: $e'};
    }
  }

  // 从远程文件列表中提取文件（排除目录）
  Map<String, dynamic> _extractRemoteFilesOnly(
    Map<String, dynamic> remoteFiles,
  ) {
    final fileMap = <String, dynamic>{};

    remoteFiles.forEach((path, info) {
      if (info is Map<String, dynamic> && info['type'] == 'file') {
        fileMap[path] = info;
      }
    });

    return fileMap;
  }

  // 从目录树中提取所有文件路径
  List<String> _extPath(Map<String, dynamic> tree) {
    final paths = <String>[];

    void traverse(dynamic node) {
      if (node is! Map<String, dynamic>) return;

      if (node['type'] == 'file' && node.containsKey('path')) {
        paths.add(node['path']);
      } else if (node['type'] == 'directory' && node.containsKey('children')) {
        final children = node['children'] as List?;
        if (children != null) {
          for (final child in children) {
            traverse(child);
          }
        }
      }
    }

    traverse(tree);
    return paths;
  }

  // 比较共同文件的修改时间
  Future<List<Map<String, dynamic>>> _compare(
    Map<String, dynamic> localData,
    Map<String, dynamic> remoteData,
    List<String> commonPaths,
  ) async {
    final different = <Map<String, dynamic>>[];

    // 路径到节点的映射
    final localPathMap = _createMap(localData['directoryTree'] ?? {});
    final remotePathMap = _createMap(remoteData['directoryTree'] ?? {});

    for (final path in commonPaths) {
      final localNode = localPathMap[path];
      final remoteNode = remotePathMap[path];

      if (localNode != null && remoteNode != null) {
        try {
          final localModified = DateTime.parse(localNode['modified']);
          final remoteModified = DateTime.parse(remoteNode['modified']);

          if (localModified.difference(remoteModified).inSeconds.abs() > 1) {
            different.add({
              'path': path,
              'localModified': localModified.toIso8601String(),
              'remoteModified': remoteModified.toIso8601String(),
            });
          }
        } catch (e) {
          print('比较文件修改时间失败 $path: $e');
        }
      }
    }

    return different;
  }

  // 创建路径到节点的映射
  Map<String, Map<String, dynamic>> _createMap(Map<String, dynamic> tree) {
    final pathMap = <String, Map<String, dynamic>>{};

    void traverse(dynamic node) {
      if (node is! Map<String, dynamic>) return;

      if (node.containsKey('path')) {
        pathMap[node['path']] = node;
      }

      if (node['type'] == 'directory' && node.containsKey('children')) {
        final children = node['children'] as List?;
        if (children != null) {
          for (final child in children) {
            traverse(child);
          }
        }
      }
    }

    traverse(tree);
    return pathMap;
  }

  // 测试HTTP连接
  Future<bool> testHttp(String host, int port) async {
    try {
      final url = Uri.http('$host:$port', '/');
      print('测试HTTP连接到: $url');

      final Map<String, String> headers = {};
      if (httpUser.isNotEmpty && httpPwd.isNotEmpty) {
        final auth = base64Encode(utf8.encode('$httpUser:$httpPwd'));
        headers['authorization'] = 'Basic $auth';
      }

      http.Response? response;
      int retryCount = 0;
      const maxRetry = 3;
      const timeoutSeconds = 5;

      while (retryCount <= maxRetry) {
        try {
          response = await http
              .get(url, headers: headers)
              .timeout(
                Duration(seconds: timeoutSeconds),
                onTimeout: () {
                  print('HTTP连接测试超时 (URL: $url)');
                  throw TimeoutException(
                    'HTTP连接测试超时: $url',
                    Duration(seconds: timeoutSeconds),
                  );
                },
              );
          break;
        } catch (e) {
          retryCount++;
          if (retryCount > maxRetry) {
            print('HTTP连接测试失败，已达到最大重试次数 ($maxRetry): $e');
            eventHistory.insert(
              0,
              'HTTP连接测试失败: $e (${DateTime.now().toIso8601String()})',
            );
            if (eventHistory.length > 100) {
              eventHistory.removeLast();
            }
            notifyListeners();
            rethrow;
          }
          print('连接测试失败，正在重试 ($retryCount/$maxRetry): $e');
          await Future.delayed(Duration(seconds: 2 * retryCount));
        }
      }

      if (response == null) {
        print('HTTP连接测试失败: 无响应');
        return false;
      }

      print('HTTP连接测试成功，状态码: ${response.statusCode}');

      if (response.statusCode == HttpStatus.unauthorized) {
        print('HTTP连接测试失败: 认证失败');
        return false;
      }

      return response.statusCode == 200;
    } catch (e, stackTrace) {
      print('HTTP连接测试失败: $e');
      print('详细错误信息: $stackTrace');
      eventHistory.insert(
        0,
        'HTTP连接测试失败: $e (${DateTime.now().toIso8601String()})',
      );
      if (eventHistory.length > 100) {
        eventHistory.removeLast();
      }
      notifyListeners();
      return false;
    }
  }
}

// 同步页面
class SyncPage extends StatefulWidget {
  const SyncPage({super.key});

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  bool autoRefreshDiff = false;
  Timer? autoRefreshTimer;

  void toggleAutoRefresh() {
    autoRefreshDiff = !autoRefreshDiff;
    if (autoRefreshDiff) {
      autoRefreshTimer = Timer.periodic(Duration(seconds: 30), (_) {});
    } else {
      autoRefreshTimer?.cancel();
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<MyAppState>();
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('当前监控路径: ${appState.watchPath}'),

            // 模式选择
            const Text('选择模式:', style: TextStyle(fontWeight: FontWeight.bold)),
            Row(
              children: [
                Expanded(
                  child: ListTile(
                    title: const Text('服务器模式'),
                    leading: Radio<SyncMode>(
                      value: SyncMode.server,
                      groupValue: appState.syncMode,
                      onChanged: (SyncMode? value) {
                        if (value != null) {
                          appState.setSyncMode(value);
                        }
                      },
                    ),
                  ),
                ),
                Expanded(
                  child: ListTile(
                    title: const Text('客户端模式'),
                    leading: Radio<SyncMode>(
                      value: SyncMode.client,
                      groupValue: appState.syncMode,
                      onChanged: (SyncMode? value) {
                        if (value != null) {
                          appState.setSyncMode(value);
                        }
                      },
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),

            if (appState.syncMode == SyncMode.server) ...[
              Card(
                elevation: 2,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: double.infinity,  // 修改为 double.infinity 避免计算宽度问题
                        child: ElevatedButton(
                          onPressed: () async {
                            String? selectedDirectory = await FilePicker
                                .platform
                                .getDirectoryPath();
                            print('Selected Directory: $selectedDirectory');
                            if (selectedDirectory != null) {
                              appState.setWatchPath(selectedDirectory);
                            }
                          },
                          child: Text(
                            appState.watchPath.isEmpty ? '选择要同步的目录' : '选择另一个目录',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),

                      TextField(
                        decoration: const InputDecoration(
                          labelText: 'HTTP端口',
                          hintText: '请输入HTTP端口 (默认: 8080)',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.number,
                        onChanged: (value) {
                          final port = int.tryParse(value);
                          if (port != null) {
                            appState.httpPort = port;
                          }
                        },
                      ),

                      const SizedBox(height: 16),

                      const Text(
                        'HTTP基本认证 (可选):',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),

                      TextField(
                        decoration: const InputDecoration(
                          labelText: '用户名',
                          hintText: '请输入用户名（默认user）',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (value) => appState.httpUser = value,
                      ),

                      const SizedBox(height: 8),

                      TextField(
                        decoration: const InputDecoration(
                          labelText: '密码',
                          hintText: '请输入密码（默认pwd123）',
                          border: OutlineInputBorder(),
                        ),
                        obscureText: true,
                        onChanged: (value) => appState.httpPwd = value,
                      ),

                      // 显示服务器状态信息
                      if (appState.isHTTPRunning) ...[
                        const SizedBox(height: 16),
                        const Divider(),
                        const Text(
                          'HTTP服务器状态: 运行中',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.green,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text('HTTP服务器端口: ${appState.httpPort}'),
                        Text('用户名: ${appState.httpUser}'),
                        Text('密码: ${appState.httpPwd}'),
                        Text(
                          '访问地址: http://${appState.localIPAddress}:${appState.httpPort}',
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ] else ...[
              // 客户端模式控件
              Card(
                elevation: 2,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: double.infinity,  // 修改为 double.infinity 避免计算宽度问题
                        child: ElevatedButton(
                          onPressed: () async {
                            String? selectedDirectory = await FilePicker
                                .platform
                                .getDirectoryPath();
                            print('Selected Directory: $selectedDirectory');
                            if (selectedDirectory != null) {
                              appState.setWatchPath(selectedDirectory);
                            }
                          },
                          child: Text(
                            appState.watchPath.isEmpty ? '选择要同步的目录' : '选择另一个目录',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,  // 修改为 double.infinity 避免计算宽度问题
                        child: ElevatedButton(
                          onPressed: appState.watchPath.isEmpty
                              ? null
                              : () async {
                                  final result = await showDialog<bool>(
                                    context: context,
                                    barrierDismissible: false,
                                    builder: (BuildContext context) {
                                      return UploadProgressDialog(
                                        uploadFuture: appState.httpUpload(),
                                      );
                                    },
                                  );

                                  if (context.mounted) {
                                    if (result == true) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text('文件上传成功'),
                                          backgroundColor: Color.fromARGB(
                                            255,
                                            0,
                                            0,
                                            0,
                                          ),
                                        ),
                                      );
                                    } else if (result == false) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text('文件上传失败，请查看日志'),
                                          backgroundColor: Color.fromARGB(
                                            255,
                                            0,
                                            0,
                                            0,
                                          ),
                                        ),
                                      );
                                    }
                                  }
                                },
                          child: const Text('上传服务器缺失的文件'),
                        ),
                      ),
                      const SizedBox(height: 12),

                      //先让他暂时歇在这里
                      /*ElevatedButton(
                onPressed: appState.watchPath.isEmpty
                  ? null
                  : () => appState.httpDownload(),
                style: ElevatedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: const Text('下载本地缺失的文件'),
              ),*/
                      ElevatedButton(
                        onPressed: appState.httpHost.isEmpty
                            ? null
                            : () async {
                                final isConnected = await appState.testHttp(
                                  appState.httpHost,
                                  appState.httpPortC,
                                );

                                if (isConnected) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('HTTP连接成功'),
                                      backgroundColor: Color.fromARGB(
                                        255,
                                        0,
                                        0,
                                        0,
                                      ),
                                    ),
                                  );
                                } else {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('HTTP连接失败，请检查服务器设置和网络连接'),
                                      backgroundColor: Color.fromARGB(
                                        255,
                                        0,
                                        0,
                                        0,
                                      ),
                                    ),
                                  );
                                }
                              },
                        child: const Text('测试HTTP连接'),
                      ),

                      const SizedBox(height: 12),

                      // 检查差异按钮
                      ElevatedButton(
                        onPressed:
                            appState.watchPath.isEmpty ||
                                appState.httpHost.isEmpty
                            ? null
                            : () async {
                                final diffResult = await appState
                                    .diffScanResults();

                                if (diffResult.containsKey('error')) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        '比较失败: ${diffResult['error']}',
                                      ),
                                      backgroundColor: const Color.fromARGB(
                                        255,
                                        0,
                                        0,
                                        0,
                                      ),
                                    ),
                                  );
                                  return;
                                }

                                // 显示差异结果
                                showDialog(
                                  context: context,
                                  builder: (BuildContext context) {
                                    return AlertDialog(
                                      title: const Text('文件差异比较结果'),
                                      content: SizedBox(
                                        width: double.maxFinite,
                                        child: ListView(
                                          shrinkWrap: true,
                                          children: [
                                            if ((diffResult['onlyLocal']
                                                    as List)
                                                .isNotEmpty) ...[
                                              const Text(
                                                '仅在本地存在:',
                                                style: TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                              ...((diffResult['onlyLocal']
                                                          as List)
                                                      .map(
                                                        (file) => ListTile(
                                                          leading: const Icon(
                                                            Icons.upload_file,
                                                            color: Colors.blue,
                                                          ),
                                                          title: Text(file),
                                                        ),
                                                      ))
                                                  .toList(),
                                              const Divider(),
                                            ],

                                            if ((diffResult['onlyRemote']
                                                    as List)
                                                .isNotEmpty) ...[
                                              const Text(
                                                '仅在远程存在:',
                                                style: TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                              ...((diffResult['onlyRemote']
                                                          as List)
                                                      .map(
                                                        (file) => ListTile(
                                                          leading: const Icon(
                                                            Icons.download,
                                                            color: Colors.green,
                                                          ),
                                                          title: Text(file),
                                                        ),
                                                      ))
                                                  .toList(),
                                              const Divider(),
                                            ],

                                            if ((diffResult['different']
                                                    as List)
                                                .isNotEmpty) ...[
                                              const Text(
                                                '修改时间不同:',
                                                style: TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                              ...((diffResult['different'] as List).map(
                                                (item) => ListTile(
                                                  leading: const Icon(
                                                    Icons.update,
                                                    color: Colors.orange,
                                                  ),
                                                  title: Text(
                                                    (item as Map)['path'],
                                                  ),
                                                  subtitle: Text(
                                                    '本地: ${(item['localModified'] as String).split('T').first} '
                                                    '远程: ${(item['remoteModified'] as String).split('T').first}',
                                                  ),
                                                ),
                                              )).toList(),
                                            ],

                                            if ((diffResult['onlyLocal']
                                                        as List)
                                                    .isEmpty &&
                                                (diffResult['onlyRemote']
                                                        as List)
                                                    .isEmpty &&
                                                (diffResult['different']
                                                        as List)
                                                    .isEmpty) ...[
                                              const Text(
                                                '没有发现差异',
                                                style: TextStyle(
                                                  fontStyle: FontStyle.italic,
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () {
                                            Navigator.of(context).pop();
                                          },
                                          child: const Text('关闭'),
                                        ),
                                      ],
                                    );
                                  },
                                );
                              },
                        child: const Text('比较本地与远程文件差异'),
                      ),

                      const SizedBox(height: 16),

                      const Text(
                        'HTTP基本认证 (可选):',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),

                      const SizedBox(height: 8),

                      TextField(
                        decoration: const InputDecoration(
                          labelText: '用户名',
                          hintText: '请输入用户名',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (value) => appState.httpUser = value,
                      ),

                      const SizedBox(height: 8),

                      TextField(
                        decoration: const InputDecoration(
                          labelText: '密码',
                          hintText: '请输入密码',
                          border: OutlineInputBorder(),
                        ),
                        obscureText: true,
                        onChanged: (value) => appState.httpPwd = value,
                      ),

                      const SizedBox(height: 16),

                      TextField(
                        decoration: const InputDecoration(
                          labelText: 'HTTP服务器地址',
                          hintText: '请输入HTTP服务器地址',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (value) => appState.httpHost = value,
                      ),

                      const SizedBox(height: 8),

                      TextField(
                        decoration: InputDecoration(
                          labelText: 'HTTP端口',
                          hintText: '请输入HTTP端口 (默认: 8080)',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.number,
                        onChanged: (value) {
                          final port = int.tryParse(value);
                          if (port != null) {
                            appState.httpPortC = port;
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

//文件监视页面
class WatcherPage extends StatefulWidget {
  const WatcherPage({super.key});

  @override
  State<WatcherPage> createState() => _WatcherPageState();
}

class _WatcherPageState extends State<WatcherPage> {
  @override
  void dispose() {
    context.read<MyAppState>()._watcher.stopWatch();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<MyAppState>();
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('监控路径: ${appState.watchPath}'),
            const SizedBox(height: 16),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '文件变更历史:',
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 8),
                    ...appState.eventHistory
                        .map(
                          (event) => Column(
                            children: [
                              ListTile(
                                leading: const Icon(Icons.history),
                                title: Text(
                                  event,
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ),
                              if (event != appState.eventHistory.last)
                                Divider(
                                  height: 1,
                                  thickness: 1,
                                  color: Colors.grey[300],
                                  indent: 72,
                                ),
                            ],
                          ),
                        )
                        .toList(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

//上传进度对话框
class UploadProgressDialog extends StatefulWidget {
  final Future<bool> uploadFuture;

  const UploadProgressDialog({Key? key, required this.uploadFuture})
    : super(key: key);

  @override
  _UploadProgressDialogState createState() => _UploadProgressDialogState();
}

class _UploadProgressDialogState extends State<UploadProgressDialog> {
  final LogManager _logManager = LogManager();
  late final VoidCallback _logListener;
  List<String> _logs = [];
  bool _isCompleted = false;
  bool _isSuccess = false;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();

    _logs = _logManager.getLogs();

    _logListener = () {
      if (mounted) {
        setState(() {
          _logs = _logManager.getLogs();
        });

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              _scrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 100),
              curve: Curves.easeOut,
            );
          }
        });
      }
    };

    _logManager.addListener(_logListener);

    widget.uploadFuture
        .then((success) {
          if (mounted) {
            setState(() {
              _isCompleted = true;
              _isSuccess = success;
            });

            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (_scrollController.hasClients) {
                _scrollController.animateTo(
                  _scrollController.position.maxScrollExtent,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOut,
                );
              }
            });
          }
        })
        .catchError((error) {
          if (mounted) {
            setState(() {
              _isCompleted = true;
              _isSuccess = false;
            });
            _log('上传过程中发生未捕获的错误: $error');
          }
        });
  }

  @override
  void dispose() {
    _logManager.removeListener(_logListener);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Text('文件上传进度'),
          const SizedBox(width: 10),
          if (!_isCompleted)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(
              _isSuccess ? Icons.check_circle : Icons.error,
              color: _isSuccess ? Colors.green : Colors.red,
            ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: 400,
        child: Column(
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Scrollbar(
                  controller: _scrollController,
                  child: ListView.builder(
                    controller: _scrollController,
                    itemCount: _logs.length,
                    itemBuilder: (context, index) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8.0,
                          vertical: 2.0,
                        ),
                        child: Text(
                          _logs[index],
                          style: const TextStyle(
                            fontSize: 12,
                            fontFamily: 'monospace',
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              _isCompleted ? (_isSuccess ? '上传完成!' : '上传失败!') : '正在上传文件...',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: _isCompleted
                    ? (_isSuccess ? Colors.green : Colors.red)
                    : const Color.fromARGB(255, 0, 0, 0),
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (_isCompleted)
          TextButton(
            onPressed: () {
              Navigator.of(context).pop(_isSuccess);
            },
            child: const Text('关闭'),
          ),
      ],
    );
  }
}
