import 'dart:async';
import 'dart:io';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
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

Future<String> listFiles(String path) async {
  final url = 'http://localhost:9178//list';
  
  try {
    final httpClient = HttpClient();
    final request = await httpClient.postUrl(Uri.parse(url));
    request.headers.set('Content-Type', 'application/json');
    
    final requestBody = json.encode({'path': path});
    request.write(requestBody);
    
    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();
    httpClient.close();
    
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
        home: const Pages(),
      ),
    );
  }
}

class Pages extends StatefulWidget {
  const Pages({super.key});

  @override
  State<Pages> createState() => _PagesState();
}

class _PagesState extends State<Pages> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Consumer<MyAppState>(
      builder: (context, appState, child) {
        // 根据当前索引更新appState
        if (_currentIndex != appState.currentIdx) {
          appState.setIdx(_currentIndex);
        }
        
        return SafeArea(
          child: NavigationView(
            pane: NavigationPane(
              displayMode: PaneDisplayMode.top,
              selected: _currentIndex,
              onChanged: (index) {
                setState(() {
                  _currentIndex = index;
                });
                if (index == 0) {
                  appState.setSyncMode(SyncMode.server);
                } else {
                  appState.setSyncMode(SyncMode.client);
                }
              },
              items: [
                PaneItem(
                  icon: Icon(FluentIcons.home),
                  title: Text('服务器模式'),
                  body: SyncPage(selectedTab: 0),
                ),
                PaneItem(
                  icon: Icon(FluentIcons.settings),
                  title: Text('客户端模式'),
                  body: SyncPage(selectedTab: 1),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class MyAppState extends ChangeNotifier {
  int _currentIdx = 0;
  String lastEvent = "No event yet";
  String watchPath = "";
  final List<String> eventHistory = [];

  SyncMode _syncMode = SyncMode.server;
  bool _isServerRunning = false;

  int get currentIdx => _currentIdx;
  SyncMode get syncMode => _syncMode;
  bool get isServerRunning => _isServerRunning;

  void setIdx(int idx) {
    _currentIdx = idx;

    _syncMode = idx == 0 ? SyncMode.server : SyncMode.client;
    notifyListeners();
  }

  void setSyncMode(SyncMode mode) {
    _syncMode = mode;
    _currentIdx = mode == SyncMode.server ? 0 : 1;
    notifyListeners();
  }


  void setServerRunning(bool running) {
    _isServerRunning = running;
    notifyListeners();
  }

  String httpHost = 'localhost';
  int httpPortC = 8080;

  String httpToken = '';

  MyAppState() {
    _currentIdx = _syncMode == SyncMode.server ? 0 : 1;
  }

  void setWatchPath(String path) {
    watchPath = path;
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
  final int selectedTab;

  const SyncPage({super.key, this.selectedTab = 0});

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
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
  Widget build(BuildContext context) {
    final appState = context.watch<MyAppState>();
    bool isServerMode = widget.selectedTab == 0;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('当前监控路径: ${appState.watchPath}'),

            const SizedBox(height: 16),

            if (isServerMode) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: double.infinity,
                        child: Button(
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

                      PasswordBox(
                        placeholder: '请输入访问令牌',
                        onChanged: (value) => appState.httpToken = value,
                      ),
                      const SizedBox(height: 16),

                      Consumer<MyAppState>(
                        builder: (context, appState, child) {
                          bool isServerRunning = appState.isServerRunning;
                          return SizedBox(
                            width: double.infinity,
                            child: Button(
                              onPressed: appState.watchPath.isEmpty
                                  ? null
                                  : () async {
                                      if (!isServerRunning) {

                                        try {
                                          synaesthesiaDart.uploadDir = appState.watchPath;
                                          synaesthesiaDart.apiToken = appState.httpToken;
                                          synaesthesiaDart.useToken = appState.httpToken.isNotEmpty;
                                          synaesthesiaDart.port = 9178;

                                          final initResult = await synaesthesiaDart.synaInit(appState.watchPath);

                                          if (initResult == 0) {
                                            final startResult = await synaesthesiaDart.synaStartHttpServer();
                                            if (startResult == 0) {
                                              _showMessage(context, '服务器启动成功');

                                              appState.setServerRunning(true);
                                            } else {
                                              _showMessage(context, '服务器启动失败');
                                            }
                                          } else {
                                            _showMessage(context, '服务器初始化失败: $initResult');
                                          }
                                        } catch (e) {
                                          _showMessage(context, '启动服务器时出错: $e');
                                        }
                                      } else {

                                        try {
                                          final stopResult = await synaesthesiaDart.synaStopHttpServer();
                                          if (stopResult == 0) {
                                            _showMessage(context, '服务器已停止');

                                            appState.setServerRunning(false);
                                          } else {
                                            _showMessage(context, '停止服务器失败');
                                          }
                                        } catch (e) {
                                          _showMessage(context, '停止服务器时出错: $e');
                                        }
                                      }
                                    },
                              child: Text(isServerRunning ? '停止服务器' : '启动服务器'),
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
                                color: appState.isServerRunning ? Colors.green : Colors.red,
                              ),
                            ),
                            const SizedBox(height: 8),
                            FutureBuilder<String>(
                              future: _getActualUploadDir(),
                              builder: (context, snapshot) {
                                String uploadDir = snapshot.data ?? appState.watchPath;
                                return Text('上传目录: $uploadDir');
                              },
                            ),
                            Text('端口: 9178'),
                            Text('Token认证: ${appState.httpToken.isNotEmpty ? "已启用" : "已禁用"}'),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ] else ...[

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
                            print('Selected Directory: $selectedDirectory');
                            if (selectedDirectory != null) {
                              appState.setWatchPath(selectedDirectory);
                            }
                          },
                          child: Text(
                            appState.watchPath.isEmpty ? '选择同步目录' : '更改同步目录',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),

                      SizedBox(
                        width: double.infinity,
                        child: Button(
                          onPressed: () async {
                            try {
                              final result = showDialog<bool>(
                                context: context,
                                builder: (BuildContext context) {
                                  return ContentDialog(
                                    title: const Text('同步进度'),
                                    content: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: const [
                                        ProgressRing(),
                                        SizedBox(height: 16),
                                        Text('正在同步文件...'),
                                      ],
                                    ),
                                  );
                                },
                              );

                              if (result == true) {
                                _showMessage(context, '同步完成');
                              } else {
                                _showMessage(context, '同步失败或取消');
                              }
                            } catch (e) {
                              _showMessage(context, '同步出错: $e');
                            }
                          },
                          child: const Text('开始同步到服务器'),
                        ),
                      ),
                      const SizedBox(height: 12),

                      PasswordBox(
                        placeholder: '请输入访问令牌',
                        onChanged: (value) => appState.httpToken = value,
                      ),
                      
                      const SizedBox(height: 16),

                      if (!isServerMode) ...[
                        SizedBox(
                          width: double.infinity,
                          child: Button(
                            onPressed: () async {
                              try {
                                _showMessage(context, '正在搜索局域网中的服务器...');
                                
                                final servers = await synaesthesiaDart.discoverServers();
                                
                                if (servers.isEmpty) {
                                  _showMessage(context, '未找到局域网中的服务器');
                                } else {
                                  _showServerDiscoveryDialog(context, servers);
                                }
                              } catch (e) {
                                _showMessage(context, '服务器发现失败: $e');
                              }
                            },
                            child: const Text('发现局域网服务器'),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                    ],
                  ),
                ),
              ),

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
                          onPressed: () async {
                            try {
                              final result = await synaesthesiaDart.synaCompareChanges(
                                'http://${appState.httpHost}:9178', 
                                appState.httpToken
                              );

                              if (result['status'] == 'success') {
                                _showComparisonResultDialog(context, result);
                              } else {
                                _showMessage(context, '比较失败: ${result['error']}');
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
                              InfoLabel(
                                label: '历史记录',
                                child: Text(event),
                              ),
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

void _showServerDiscoveryDialog(BuildContext context, List<Map<String, dynamic>> servers) {
  showDialog(
    context: context,
    builder: (context) {
      return ContentDialog(
        title: const Text('发现的服务器'),
        content: SizedBox(
          width: double.maxFinite,
          height: 300,
          child: ListView.builder(
            itemCount: servers.length,
            itemBuilder: (context, index) {
              final server = servers[index];
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Row(
                    children: [
                      Icon(FluentIcons.home),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${server['host']}:${server['port']}'),
                            Text('IP: ${server['address']}'),
                          ],
                        ),
                      ),
                      Button(
                        onPressed: () {
                          final appState = context.read<MyAppState>();
                          appState.httpHost = server['host'].toString();
                          Navigator.of(context).pop();
                          
                          // 使用ContentDialog显示消息
                          showDialog(
                            context: context,
                            builder: (context) {
                              Future.delayed(const Duration(seconds: 2), () {
                                Navigator.of(context).pop();
                              });
                              return ContentDialog(
                                title: const Text('提示'),
                                content: Text('已选择服务器: ${server['host']}:${server['port']}'),
                                actions: [
                                  Button(
                                    onPressed: () => Navigator.of(context).pop(),
                                    child: const Text('确定'),
                                  ),
                                ],
                              );
                            },
                          );
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

void _showComparisonResultDialog(
  BuildContext context,
  Map<String, dynamic> result,
) {
  showDialog(
    context: context,
    builder: (context) {
      return ContentDialog(
        title: const Text('文件比较结果'),
        content: SizedBox(
          width: double.maxFinite,
          height: 300,
          child: ListView.builder(
            itemCount: result['files'].length,
            itemBuilder: (context, index) {
              final file = result['files'][index];
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Row(
                    children: [
                      Icon(
                        file['status'] == 'added'
                            ? FluentIcons.add
                            : file['status'] == 'modified'
                                ? FluentIcons.edit
                                : FluentIcons.remove,
                        color: file['status'] == 'added'
                            ? Colors.green
                            : file['status'] == 'modified'
                                ? Colors.blue
                                : Colors.red,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(file['path']),
                            Text('状态: ${file['status']}'),
                          ],
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