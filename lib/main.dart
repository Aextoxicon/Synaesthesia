import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:ffi';
import 'package:ffi/ffi.dart' as ffi;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'synaesthesia_ffi.dart';
import 'package:ffi/ffi.dart';

final synaesthesia = SynaesthesiaLibrary.instance;

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
  final url = 'http://localhost:9178/list-files';
  
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
    final resultPtr = synaesthesia.synaGetUploadDir();
    final resultStr = resultPtr.toDartString();
    malloc.free(resultPtr);
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

class Pages extends StatelessWidget {
  const Pages({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<MyAppState>(
      builder: (context, appState, child) {
        return Scaffold(
          body: SyncPage(selectedTab: appState.currentIdx),
          bottomNavigationBar: BottomNavigationBar(
            currentIndex: appState.currentIdx,
            onTap: (index) {
              appState.setIdx(index);
              if (index == 0) {
                appState.setSyncMode(SyncMode.server);
              } else {
                appState.setSyncMode(SyncMode.client);
              }
            },
            items: const [
              BottomNavigationBarItem(
                icon: Icon(Icons.computer),
                label: '服务器模式',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.laptop_mac),
                label: '客户端模式',
              ),
            ],
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
  @override
  Widget build(BuildContext context) {
    final appState = context.watch<MyAppState>();
    bool isServerMode = widget.selectedTab == 0;

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('当前监控路径: ${appState.watchPath}'),

            const SizedBox(height: 16),

            if (isServerMode) ...[
              Card(
                elevation: 2,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: double.infinity,
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
                          labelText: '访问令牌',
                          hintText: '请输入访问令牌',
                          border: OutlineInputBorder(),
                        ),
                        obscureText: true,
                        onChanged: (value) => appState.httpToken = value,
                      ),
                      const SizedBox(height: 16),


                      Consumer<MyAppState>(
                        builder: (context, appState, child) {
                          bool isServerRunning = appState.isServerRunning;
                          return SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed: appState.watchPath.isEmpty
                                  ? null
                                  : () async {
                                      if (!isServerRunning) {

                                        try {

                                          final config = {
                                            'uploadDir': appState.watchPath,
                                            'useCompare': false,
                                            'apiToken': appState.httpToken,
                                            'port': 9178,
                                            'useToken': appState.httpToken.isNotEmpty,
                                          };

                                          final configFile = File('${appState.watchPath}/.syna/.server_config.json');
                                          if (configFile.existsSync()) {
                                            configFile.deleteSync();
                                          } else {
                                            Directory(appState.watchPath + '/.syna').createSync(recursive: true);
                                          }
                                          await configFile.writeAsString(json.encode(config));

                                          final configPathPtr = configFile.path.toNativeUtf8().cast<ffi.Utf8>();
                                          final initResult = synaesthesia.synaInit(configPathPtr);
                                          malloc.free(configPathPtr);

                                          if (initResult == 0) {
                                            final startResult = synaesthesia.synaStartHttpServer();
                                            if (startResult == 0) {
                                              ScaffoldMessenger.of(context).showSnackBar(
                                                const SnackBar(
                                                  content: Text('服务器启动成功'),
                                                ),
                                              );


                                              appState.setServerRunning(true);
                                            } else {
                                              ScaffoldMessenger.of(context).showSnackBar(
                                                const SnackBar(
                                                  content: Text('服务器启动失败'),
                                                ),
                                              );
                                            }
                                          } else {
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              SnackBar(
                                                content: Text('服务器初始化失败: $initResult'),
                                              ),
                                            );
                                          }
                                        } catch (e) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(
                                              content: Text('启动服务器时出错: $e'),
                                            ),
                                          );
                                        }
                                      } else {

                                        try {
                                          final stopResult = synaesthesia.synaStopHttpServer();
                                          if (stopResult == 0) {
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              const SnackBar(
                                                content: Text('服务器已停止'),
                                              ),
                                            );


                                            appState.setServerRunning(false);
                                          } else {
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              const SnackBar(
                                                content: Text('停止服务器失败'),
                                              ),
                                            );
                                          }
                                        } catch (e) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(
                                              content: Text('停止服务器时出错: $e'),
                                            ),
                                          );
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
                elevation: 2,
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

                      TextField(
                        decoration: const InputDecoration(
                          labelText: '服务器地址',
                          hintText: '输入服务器IP地址',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.url,
                        onChanged: (value) => appState.httpHost = value,
                      ),
                      const SizedBox(height: 12),

                      SizedBox(
                        width: double.infinity,
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
                            appState.watchPath.isEmpty ? '选择同步目录' : '更改同步目录',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),

                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: () async {
                            try {

                              final result = await showDialog<bool>(
                                context: context,
                                builder: (BuildContext context) {
                                  return const AlertDialog(
                                    title: Text('同步进度'),
                                    content: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        CircularProgressIndicator(),
                                        SizedBox(height: 16),
                                        Text('正在同步文件...'),
                                      ],
                                    ),
                                  );
                                },
                              );

                              if (result == true) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('同步完成'),
                                  ),
                                );
                              } else {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('同步失败或取消'),
                                  ),
                                );
                              }
                            } catch (e) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('同步出错: $e'),
                                ),
                              );
                            }
                          },
                          child: const Text('开始同步到服务器'),
                        ),
                      ),
                      const SizedBox(height: 12),

                      TextField(
                        decoration: const InputDecoration(
                          labelText: '访问令牌',
                          hintText: '请输入访问令牌',
                          border: OutlineInputBorder(),
                        ),
                        obscureText: true,
                        onChanged: (value) => appState.httpToken = value,
                      ),
                    ],
                  ),
                ),
              ),

              Card(
                elevation: 2,
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
                        child: ElevatedButton(
                          onPressed: () async {
                            try {
                              final host = 'http://${appState.httpHost}:9178';
                              final hostPtr = host.toNativeUtf8().cast<ffi.Utf8>();
                              final tokenPtr = appState.httpToken.toNativeUtf8().cast<ffi.Utf8>();

                              final resultPtr = synaesthesia.synaCompareChanges(hostPtr, tokenPtr);
                              final resultStr = resultPtr.toDartString();

                              malloc.free(hostPtr);
                              malloc.free(tokenPtr);
                              malloc.free(resultPtr);

                              final result = json.decode(resultStr);

                              if (result['status'] == 'success') {
                                // 显示比较结果
                                showDialog(
                                  context: context,
                                  builder: (BuildContext context) {
                                    return _buildComparisonResultDialog(context, result);
                                  },
                                );
                              } else {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('比较失败: ${result['error']}'),
                                  ),
                                );
                              }
                            } catch (e) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('比较出错: $e'),
                                ),
                              );
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
  @override
  void dispose() {
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
            ElevatedButton(
              onPressed: () async {
                if (appState.watchPath.isEmpty) {
                  final snackBar = SnackBar(
                    content: Text('请先选择一个监控路径'),
                  );
                  ScaffoldMessenger.of(context).showSnackBar(snackBar);
                  return;
                }

                try {
                  final pathStr = appState.watchPath;
                  
                  final resultStr = await listFiles(pathStr);

                  List<dynamic> files = json.decode(resultStr);

                  final snackBar = SnackBar(
                    content: Text('CGO扫描完成，找到${files.length}个文件'),
                  );
                  ScaffoldMessenger.of(context).showSnackBar(snackBar);

                  appState.updateLastEvent(
                    '扫描目录: ${appState.watchPath} (${files.length}个文件)',
                  );
                } catch (e) {
                  final snackBar = SnackBar(
                    content: Text('CGO扫描失败: $e'),
                  );
                  ScaffoldMessenger.of(context).showSnackBar(snackBar);
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

    Future.delayed(Duration(seconds: 2), () {
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

Widget _buildComparisonResultDialog(
  BuildContext context,
  Map<String, dynamic> result,
) {
  List<dynamic> missingOnRemote = result['missingOnRemote'] ?? [];
  int localCount = result['localCount'] ?? 0;
  int remoteCount = result['remoteCount'] ?? 0;
  int missingCount = result['missingCount'] ?? 0;

  return AlertDialog(
    title: const Text('文件比较结果'),
    content: SizedBox(
      width: double.maxFinite,
      child: ListView(
        shrinkWrap: true,
        children: [
          ListTile(
            title: Text('本地文件数: $localCount'),
          ),
          ListTile(
            title: Text('远程文件数: $remoteCount'),
          ),
          ListTile(
            title: Text('远程缺失文件数: $missingCount'),
          ),
          const Divider(),
          
          if (missingOnRemote.isNotEmpty) ...[
            const Text(
              '以下文件仅存在于本地（远程缺失）:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            ...missingOnRemote.map(
              (file) => Card(
                margin: const EdgeInsets.only(top: 8),
                child: ListTile(
                  leading: const Icon(Icons.file_copy, color: Colors.orange),
                  title: Text(file['name'] ?? 'Unknown'),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('大小: ${formatBytes(file['size'] ?? 0)}'),
                      Text('修改时间: ${DateTime.parse(file['modTime'].toString()).toString()}'),
                      if (file['sha256'] != null) Text('SHA256: ${file['sha256']}'),
                    ],
                  ),
                ),
              ),
            ).toList(),
          ] else ...[
            const ListTile(
              leading: Icon(Icons.check, color: Colors.green),
              title: Text('远程服务器文件完整，无缺失文件'),
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
}

Future<bool> _performUpload(String token, String localPath) async {
  ffi.Pointer<Utf8>? tokenPtr;
  ffi.Pointer<Utf8>? hostPtr;

  try {
    _log("开始上传文件，使用Token进行认证");

    final tokenStr = token;
    final hostStr = 'http://${MyAppState().httpHost}:9178';
    tokenPtr = tokenStr.toNativeUtf8().cast<ffi.Utf8>();
    hostPtr = hostStr.toNativeUtf8().cast<ffi.Utf8>();
    final resultPtr = synaesthesia.synaCompareChanges(hostPtr, tokenPtr);
    
    if (resultPtr == nullptr) {
      _log("服务器比较返回空指针");
      return false;
    }
    
    final resultStr = resultPtr.toDartString();

    _log("服务器比较结果: $resultStr");

    malloc.free(resultPtr);
    malloc.free(hostPtr);
    malloc.free(tokenPtr);
    hostPtr = null;
    tokenPtr = null;

    await Future.delayed(const Duration(seconds: 2));

    _log("上传完成");
    return true;
  } catch (e) {
    _log("上传失败: $e");
    return false;
  } finally {
    try {
      if (tokenPtr != null) {
        malloc.free(tokenPtr);
      }
      if (hostPtr != null) {
        malloc.free(hostPtr);
      }
    } catch (e) {
      _log("释放内存时出现警告: $e");
    }
  }
}
