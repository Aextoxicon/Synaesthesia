import 'dart:async';
import 'dart:io';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'package:path/path.dart' as path;
import 'package:fluent_ui/fluent_ui.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'synaesthesia_dart.dart';

final synaesthesiaDart = SynaesthesiaDart();

enum SyncMode { server, client }

void main() {
  runApp(const MyApp());
}

class LogManager {
  static final LogManager _instance = LogManager._internal();
  factory LogManager() => _instance;
  LogManager._internal();

  final ListQueue<String> _logs = ListQueue<String>();
  final Set<VoidCallback> _listeners = <VoidCallback>{};

  static const int maxLogLines = 100;

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

void _log(String message) {
  LogManager().log(message);
  print(message);
}

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

/// 将HttpClient作为参数传入，以便进行测试
Future<String> listFiles(String path, {HttpClient? httpClient}) async {
  final url = 'http://localhost:9178/list';
  final client = httpClient ?? HttpClient();

  try {
    final request = await client.postUrl(Uri.parse(url));
    request.headers.set('Content-Type', 'application/json');

    final requestBody = json.encode({'path': path});
    request.write(requestBody);

    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();
    if (httpClient == null) {
      // 只有在我们创建了HttpClient时才关闭它
      client.close();
    }

    return responseBody;
  } catch (e) {
    _log("listFiles 请求失败: $e");
    return '[]';
  }
}

Future<String> _getActualUploadDir() async {
  try {
    final resultStr = await synaesthesiaDart.synaGetUploadDir();
    return resultStr;
  } catch (e) {
    _log("获取上传目录失败: $e");
    return "未知目录";
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (context) => MyAppState(),
      child: FluentApp(
        title: 'Synaesthesia',
        theme: FluentThemeData(
          brightness: Brightness.light,
          accentColor: Colors.blue,
        ),
        darkTheme: FluentThemeData(
          brightness: Brightness.dark,
          accentColor: Colors.blue,
        ),
        home: const SyncPage(),
      ),
    );
  }
}


class MyAppState extends ChangeNotifier {
  String lastEvent = "No event yet";
  String watchPath = "";
  final List<String> eventHistory = [];

  bool _isServerRunning = false;

  bool get isServerRunning => _isServerRunning;

  void setServerRunning(bool running) {
    _isServerRunning = running;
    notifyListeners();
  }

  String httpHost = 'localhost';
  int httpPortC = 8080;
  String httpToken = '';

  MyAppState() {
    _loadSavedConfig();
  }

  Future<void> _loadSavedConfig() async {
    final config = await synaesthesiaDart.loadConfig();
    if (config != null) {
      watchPath = config['uploadDir'] as String? ?? '';
      httpToken = config['apiToken'] as String? ?? '';
      notifyListeners();
    }
  }

  Future<void> setWatchPath(String path) async {
    watchPath = path;
    synaesthesiaDart.uploadDir = path;
    await synaesthesiaDart.synaInit(path);
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
}

class SyncPage extends StatefulWidget {
  const SyncPage({super.key});

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  void _showMessage(BuildContext context, String message) {
    showDialog(
      context: context,
      builder: (context) {
        Future.delayed(const Duration(seconds: 2), () {
          if (context.mounted) {
            Navigator.of(context).pop();
          }
        });
        return ContentDialog(
          title: const Text('提示'),
          content: Text(message),
          actions: [
            Button(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }

  Future<String> _getLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );

      String? preferredIp;
      List<String> allValidIps = [];

      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4) {
            final ip = addr.address;
            // 过滤掉无效的IP地址
            if (ip.startsWith('127.') ||
                ip.startsWith('0.') ||
                ip.startsWith('169.254.') ||
                ip.startsWith('198.18.') || // Hyper-V virtual network
                ip.startsWith('198.19.')) {
              // Hyper-V virtual network
              continue;
            }

            allValidIps.add(ip);

            // 优先选择192.168.x.x网段
            if (ip.startsWith('192.168.')) {
              return ip;
            }
            // 其次选择10.x.x.x网段
            else if (ip.startsWith('10.')) {
              preferredIp ??= ip;
            }
            // 再次选择172.16-31.x.x网段
            else if (ip.startsWith('172.')) {
              final parts = ip.split('.');
              if (parts.length == 4) {
                final secondOctet = int.tryParse(parts[1]);
                if (secondOctet != null &&
                    secondOctet >= 16 &&
                    secondOctet <= 31) {
                  preferredIp ??= ip;
                }
              }
            }
          }
        }
      }

      // 如果找到了优选的IP，返回它
      if (preferredIp != null) {
        return preferredIp;
      }

      // 如果没有优选IP，返回第一个有效的IP
      if (allValidIps.isNotEmpty) {
        return allValidIps.first;
      }
    } catch (e) {
      print('Failed to get local IP address: $e');
    }
    return 'localhost';
  }

  Future<void> _autoStartServerIfNeeded(
    BuildContext context,
    MyAppState appState,
  ) async {
    if (appState.isServerRunning) {
      return;
    }

    if (appState.watchPath.isEmpty) {
      return;
    }

    try {
      synaesthesiaDart.uploadDir = appState.watchPath;
      synaesthesiaDart.apiToken = '';
      synaesthesiaDart.useToken = false;
      synaesthesiaDart.port = 9178;

      final initResult = await synaesthesiaDart.synaInit(appState.watchPath);

      if (initResult == 0) {
        final startResult = await synaesthesiaDart.synaStartHttpServer();
        if (startResult == 0) {
          appState.setServerRunning(true);
        }
      }
    } catch (e) {
      print('自动启动服务器失败: $e');
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 延迟执行自动启动，确保上下文可用
    final appState = context.read<MyAppState>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _autoStartServerIfNeeded(context, appState);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<MyAppState>();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('当前监控路径: ${appState.watchPath}'),

            const SizedBox(height: 16),

            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 服务器模式控件
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Text(
                              '服务器模式',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 16),

                            SizedBox(
                              width: double.infinity,
                              child: Button(
                                onPressed: () async {
                                  String? selectedDirectory = await FilePicker
                                      .platform
                                      .getDirectoryPath();
                                  print(
                                    'Selected Directory: $selectedDirectory',
                                  );
                                  if (selectedDirectory != null) {
                                    appState.setWatchPath(selectedDirectory);
                                    // 选择目录后立即尝试启动服务器
                                    _autoStartServerIfNeeded(context, appState);
                                  }
                                },
                                child: Text(
                                  appState.watchPath.isEmpty
                                      ? '选择要同步的目录'
                                      : '选择另一个目录',
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),

                            Consumer<MyAppState>(
                              builder: (context, appState, child) {
                                bool isServerRunning = appState.isServerRunning;
                                if (isServerRunning) {
                                  return const SizedBox.shrink();
                                }
                                return SizedBox(
                                  width: double.infinity,
                                  child: Button(
                                    onPressed: appState.watchPath.isEmpty
                                        ? null
                                        : () async {
                                            try {
                                              synaesthesiaDart.uploadDir =
                                                  appState.watchPath;
                                              synaesthesiaDart.apiToken = '';
                                              synaesthesiaDart.useToken = false;
                                              synaesthesiaDart.port = 9178;

                                              final initResult =
                                                  await synaesthesiaDart
                                                      .synaInit(
                                                        appState.watchPath,
                                                      );

                                              if (initResult == 0) {
                                                final startResult =
                                                    await synaesthesiaDart
                                                        .synaStartHttpServer();
                                                if (startResult == 0) {
                                                  _showMessage(
                                                    context,
                                                    '服务器启动成功',
                                                  );
                                                  appState.setServerRunning(
                                                    true,
                                                  );
                                                } else {
                                                  _showMessage(
                                                    context,
                                                    '服务器启动失败',
                                                  );
                                                }
                                              } else {
                                                _showMessage(
                                                  context,
                                                  '服务器初始化失败: $initResult',
                                                );
                                              }
                                            } catch (e) {
                                              _showMessage(
                                                context,
                                                '启动服务器时出错: $e',
                                              );
                                            }
                                          },
                                    child: const Text('启动服务器'),
                                  ),
                                );
                              },
                            ),
                            const SizedBox(height: 12),

                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.grey),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '服务器状态: ${appState.isServerRunning ? "运行中" : "已停止"}',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: appState.isServerRunning
                                          ? Colors.green
                                          : Colors.red,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  FutureBuilder<String>(
                                    future: _getLocalIp(),
                                    builder: (context, snapshot) {
                                      if (snapshot.hasData) {
                                        return Text('本机IP: ${snapshot.data}');
                                      } else if (snapshot.hasError) {
                                        return Text('本机IP: 获取失败');
                                      } else {
                                        return Text('本机IP: 加载中...');
                                      }
                                    },
                                  ),
                                  const SizedBox(height: 8),
                                  FutureBuilder<String>(
                                    future: _getActualUploadDir(),
                                    builder: (context, snapshot) {
                                      String uploadDir =
                                          snapshot.data ?? appState.watchPath;
                                      return Text('上传目录: $uploadDir');
                                    },
                                  ),
                                  Text('端口: 9178'),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 16),

                    // 客户端模式控件
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Text(
                              '客户端模式',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 16),

                            TextBox(
                              placeholder: '输入服务器IP地址',
                              keyboardType: TextInputType.url,
                              controller: TextEditingController(
                                text: appState.httpHost,
                              ),
                              onChanged: (value) => appState.httpHost = value,
                            ),
                            const SizedBox(height: 12),

                            SizedBox(
                              width: double.infinity,
                              child: Button(
                                onPressed: () async {
                                  String? selectedDirectory = await FilePicker
                                      .platform
                                      .getDirectoryPath();
                                  print(
                                    'Selected Directory: $selectedDirectory',
                                  );
                                  if (selectedDirectory != null) {
                                    appState.setWatchPath(selectedDirectory);
                                  }
                                },
                                child: Text(
                                  appState.watchPath.isEmpty
                                      ? '选择同步目录'
                                      : '更改同步目录',
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),

                            SizedBox(
                              width: double.infinity,
                              child: Button(
                                onPressed:
                                    (appState.watchPath.isEmpty ||
                                        appState.httpHost.isEmpty ||
                                        appState.httpHost == 'localhost')
                                    ? null
                                    : () async {
                                        try {
                                          synaesthesiaDart.uploadDir =
                                              appState.watchPath;
                                          synaesthesiaDart.apiToken = '';
                                          synaesthesiaDart.useToken = false;
                                          synaesthesiaDart.port = 9178;

                                          final comparisonResult =
                                              await synaesthesiaDart
                                                  .synaCompareChanges(
                                                    'http://${appState.httpHost}:9178',
                                                    '',
                                                  );

                                          if (comparisonResult['status'] !=
                                              'success') {
                                            _showMessage(
                                              context,
                                              '文件比较失败: ${comparisonResult['error']}',
                                            );
                                            return;
                                          }

                                          final missingFiles =
                                              comparisonResult['missingOnRemote']
                                                  as List;

                                          if (missingFiles.isEmpty) {
                                            _showMessage(
                                              context,
                                              '所有文件已在服务器上，无需同步',
                                            );
                                            return;
                                          }

                                          bool syncSuccess = true;
                                          int uploadedCount = 0;

                                          for (var fileJson in missingFiles) {
                                            final relativePath =
                                                fileJson['relativePath']
                                                    as String;
                                            final localFilePath = path.join(
                                              appState.watchPath,
                                              relativePath,
                                            );

                                            final uploadResult =
                                                await synaesthesiaDart.synaUpload(
                                                  localFilePath,
                                                  'http://${appState.httpHost}:9178',
                                                  subPath: path.dirname(relativePath),
                                                );

                                            if (uploadResult == 0) {
                                              uploadedCount++;
                                            } else {
                                              syncSuccess = false;
                                              break;
                                            }
                                          }

                                          if (syncSuccess) {
                                            _showMessage(
                                              context,
                                              '同步完成！已上传 $uploadedCount 个文件',
                                            );
                                          } else {
                                            _showMessage(context, '同步过程中出现错误');
                                          }
                                        } catch (e) {
                                          _showMessage(context, '同步出错: $e');
                                        }
                                      },
                                child: const Text('开始同步到服务器'),
                              ),
                            ),
                            const SizedBox(height: 12),

                            SizedBox(
                              width: double.infinity,
                              child: Button(
                                onPressed: () async {
                                  _showServerDiscoveryDialog(context);
                                },
                                child: const Text('发现局域网服务器'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 16),

                    // 文件比较功能
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Text(
                              '文件比较',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 16),

                            SizedBox(
                              width: double.infinity,
                              child: Button(
                                onPressed:
                                    (appState.watchPath.isEmpty ||
                                        appState.httpHost.isEmpty ||
                                        appState.httpHost == 'localhost')
                                    ? null
                                    : () async {
                                        try {
                                          final result = await synaesthesiaDart
                                              .synaCompareChanges(
                                                'http://${appState.httpHost}:9178',
                                                '',
                                              );

                                          if (result['status'] == 'success') {
                                            _showComparisonResultDialog(
                                              context,
                                              result,
                                            );
                                          } else {
                                            _showMessage(
                                              context,
                                              '比较失败: ${result['error']}',
                                            );
                                          }
                                        } catch (e) {
                                          _showMessage(context, '比较出错: $e');
                                        }
                                      },
                                child: const Text('比较本地与远程文件'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
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

class WatcherPage extends StatefulWidget {
  const WatcherPage({super.key});

  @override
  State<WatcherPage> createState() => _WatcherPageState();
}

class _WatcherPageState extends State<WatcherPage> {
  void _showMessage(BuildContext context, String message) {
    showDialog(
      context: context,
      builder: (context) {
        Future.delayed(const Duration(seconds: 2), () {
          Navigator.of(context).pop();
        });
        return ContentDialog(
          title: const Text('提示'),
          content: Text(message),
          actions: [
            Button(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<MyAppState>();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('监控路径: ${appState.watchPath}'),
            const SizedBox(height: 16),
            Button(
              onPressed: () async {
                if (appState.watchPath.isEmpty) {
                  _showMessage(context, '请先选择一个监控路径');
                  return;
                }

                try {
                  final pathStr = appState.watchPath;

                  final files = await synaesthesiaDart.synaScan();

                  _showMessage(context, 'Dart扫描完成，找到${files.length}个文件');

                  appState.updateLastEvent(
                    '扫描目录: ${appState.watchPath} (${files.length}个文件)',
                  );
                } catch (e) {
                  _showMessage(context, 'CGO扫描失败: $e');
                }
              },
              child: const Text('使用CGO扫描目录'),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '文件变更历史:',
                      style: FluentTheme.of(context).typography.bodyLarge,
                    ),
                    const SizedBox(height: 8),
                    ...appState.eventHistory
                        .map(
                          (event) => Column(
                            children: [
                              InfoLabel(label: '历史记录', child: Text(event)),
                              if (event != appState.eventHistory.last)
                                Divider(),
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

    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() {
          _isCompleted = true;
          _isSuccess = true;
        });
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
    return ContentDialog(
      title: Row(
        children: [
          const Text('文件上传进度'),
          const SizedBox(width: 10),
          if (!_isCompleted)
            const ProgressRing()
          else
            Icon(
              _isSuccess ? FluentIcons.check_mark : FluentIcons.error,
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
          Button(
            onPressed: () {
              Navigator.of(context).pop(_isSuccess);
            },
            child: const Text('关闭'),
          ),
      ],
    );
  }
}

void _showServerDiscoveryDialog(BuildContext context) {
  final servers = <Map<String, dynamic>>[];
  var progress = 0.0;
  var currentIp = '';
  var isScanning = true;
  StreamSubscription? subscription;

  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setState) {
          // 只在初始时启动扫描
          if (isScanning && servers.isEmpty && subscription == null) {
            subscription = synaesthesiaDart
                .discoverServersStream(
                  onProgress: (current, total, ip) {
                    if (Navigator.of(dialogContext).canPop()) {
                      setState(() {
                        progress = current / total;
                        currentIp = ip;
                      });
                    }
                  },
                )
                .listen(
                  (server) {
                    if (Navigator.of(dialogContext).canPop()) {
                      setState(() {
                        servers.add(server);
                      });
                    }
                  },
                  onDone: () {
                    if (Navigator.of(dialogContext).canPop()) {
                      setState(() {
                        isScanning = false;
                      });
                    }
                  },
                  onError: (e) {
                    if (Navigator.of(dialogContext).canPop()) {
                      setState(() {
                        isScanning = false;
                      });
                    }
                  },
                );
          }

          return ContentDialog(
            title: Row(
              children: [
                const Text('发现服务器'),
                const Spacer(),
                if (isScanning)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: ProgressRing(strokeWidth: 2),
                  ),
              ],
            ),
            content: SizedBox(
              width: double.maxFinite,
              height: 350,
              child: Column(
                children: [
                  if (isScanning) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8.0),
                      child: Column(
                        children: [
                          ProgressBar(value: progress * 100),
                          const SizedBox(height: 8),
                          Text(
                            '正在扫描: $currentIp',
                            style: TextStyle(
                              color: Colors.grey[100],
                              fontSize: 12,
                            ),
                          ),
                          Text(
                            '已发现 ${servers.length} 个服务器',
                            style: TextStyle(
                              color: Colors.grey[100],
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Divider(),
                  ],
                  Expanded(
                    child: servers.isEmpty
                        ? Center(
                            child: isScanning
                                ? const Text('正在扫描局域网...')
                                : const Text('未发现服务器'),
                          )
                        : ListView.builder(
                            itemCount: servers.length,
                            itemBuilder: (context, index) {
                              final server = servers[index];
                              final host = server['host'] as String? ?? '';
                              final port = server['port'] as int? ?? 9178;
                              final name =
                                  server['name'] as String? ?? 'Unknown';
                              final ips = server['ips'] as List? ?? [];
                              final displayIp = ips.isNotEmpty
                                  ? ips.first
                                  : host;

                              return Card(
                                child: Padding(
                                  padding: const EdgeInsets.all(8.0),
                                  child: Row(
                                    children: [
                                      const Icon(FluentIcons.server),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              name,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            Text('地址: $displayIp:$port'),
                                          ],
                                        ),
                                      ),
                                      Button(
                                        onPressed: () {
                                          // 关闭订阅
                                          subscription?.cancel();

                                          final appState = context
                                              .read<MyAppState>();
                                          appState.httpHost = displayIp;
                                          Navigator.of(dialogContext).pop();
                                        },
                                        child: const Text('选择'),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              Button(
                onPressed: () {
                  // 取消订阅
                  subscription?.cancel();
                  Navigator.of(dialogContext).pop();
                },
                child: Text(isScanning ? '停止扫描' : '关闭'),
              ),
            ],
          );
        },
      );
    },
  );
}

void _showComparisonResultDialog(
  BuildContext context,
  Map<String, dynamic> result,
) {
  // 安全地获取 files 列表
  final files = result['files'] is List ? result['files'] : [];

  showDialog(
    context: context,
    builder: (context) {
      return ContentDialog(
        title: const Text('文件比较结果'),
        content: SizedBox(
          width: double.maxFinite,
          height: 300,
          child: ListView.builder(
            itemCount: files.length,
            itemBuilder: (context, index) {
              final file = files[index];
              final path = file is Map
                  ? file['path']?.toString() ?? '未知路径'
                  : '未知路径';
              final status = file is Map
                  ? file['status']?.toString() ?? 'unknown'
                  : 'unknown';

              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Row(
                    children: [
                      Icon(
                        status == 'added'
                            ? FluentIcons.add
                            : status == 'modified'
                            ? FluentIcons.edit
                            : FluentIcons.remove,
                        color: status == 'added'
                            ? Colors.green
                            : status == 'modified'
                            ? Colors.blue
                            : Colors.red,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [Text(path), Text('状态: $status')],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        actions: [
          Button(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      );
    },
  );
}
