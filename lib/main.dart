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

// FFI相关声明

// 声明外部CGO库接口
typedef synaInit_func = ffi.Int32 Function(ffi.Pointer<Utf8> configPath);
typedef SynaInit = int Function(ffi.Pointer<Utf8> configPath);

typedef synaScan_func = ffi.Pointer<Utf8> Function();
typedef SynaScan = ffi.Pointer<Utf8> Function();

typedef synaListFiles_func = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8> dir);
typedef SynaListFiles = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8> dir);

typedef synaGetUploadDir_func = ffi.Pointer<Utf8> Function();
typedef SynaGetUploadDir = ffi.Pointer<Utf8> Function();

typedef synaCompareWithServer_func = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8> token);
typedef SynaCompareWithServer = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8> token);

// CGO库实例
final DynamicLibrary _synaLib = Platform.isWindows 
    ? DynamicLibrary.open('syna.dll')
    : DynamicLibrary.open('libsyna.so');

// CGO函数绑定
final int Function(Pointer<Utf8> configPath) synaInit = _synaLib
    .lookup<NativeFunction<synaInit_func>>('synaInit')
    .asFunction<SynaInit>();

final Pointer<Utf8> Function() synaScan = _synaLib
    .lookup<NativeFunction<synaScan_func>>('synaScan')
    .asFunction<SynaScan>();

final Pointer<Utf8> Function(Pointer<Utf8> dir) synaListFiles = _synaLib
    .lookup<NativeFunction<synaListFiles_func>>('synaListFiles')
    .asFunction<SynaListFiles>();

final Pointer<Utf8> Function() synaGetUploadDir = _synaLib
    .lookup<NativeFunction<synaGetUploadDir_func>>('synaGetUploadDir')
    .asFunction<SynaGetUploadDir>();

final Pointer<Utf8> Function(Pointer<Utf8> token) synaCompareWithServer = _synaLib
    .lookup<NativeFunction<synaCompareWithServer_func>>('synaCompareWithServer')
    .asFunction<SynaCompareWithServer>();

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
          body: SyncPage(selectedTab: appState.currentIdx), // 传递当前选中的标签页
          bottomNavigationBar: BottomNavigationBar(
            currentIndex: appState.currentIdx,
            onTap: (index) {
              // 切换标签页时更新模式
              appState.setIdx(index);
              if (index == 0) {
                appState.setSyncMode(SyncMode.server);
              } else {
                appState.setSyncMode(SyncMode.client);
              }
            },
            items: const [
              BottomNavigationBarItem(icon: Icon(Icons.computer), label: '服务器模式'),
              BottomNavigationBarItem(icon: Icon(Icons.laptop_mac), label: '客户端模式'),
            ],
          ),
        );
      },
    );
  }
}


class MyAppState extends ChangeNotifier {
  int _currentIdx = 0; // 使用私有变量
  String lastEvent = "No event yet";
  String watchPath = "";
  final List<String> eventHistory = [];

  SyncMode _syncMode = SyncMode.server; // 使用私有变量

  // getter方法
  int get currentIdx => _currentIdx;
  SyncMode get syncMode => _syncMode;

  // 设置当前索引并同步更新模式
  void setIdx(int idx) {
    _currentIdx = idx;
    // 更新模式：索引0对应服务器模式，索引1对应客户端模式
    _syncMode = idx == 0 ? SyncMode.server : SyncMode.client;
    notifyListeners();
  }

  // 设置同步模式并同步更新索引
  void setSyncMode(SyncMode mode) {
    _syncMode = mode;
    _currentIdx = mode == SyncMode.server ? 0 : 1;
    notifyListeners();
  }

  String httpHost = 'localhost';
  int httpPortC = 8080;

  String httpToken = '';

  MyAppState() {
    // 初始化时，如果_syncMode是server，则_currentIdx为0，否则为1
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

  // 移除所有后端功能函数，只保留UI状态管理
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
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: appState.watchPath.isEmpty
                              ? null
                              : () async {
                                  try {
                                    // 显示上传进度对话框
                                    final result = await showDialog<bool>(
                                      context: context,
                                      builder: (BuildContext context) {
                                        return UploadProgressDialog(
                                          uploadFuture: _performUpload(appState.httpToken, appState.watchPath),
                                        );
                                      },
                                    );

                                    if (result == true) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                          content: Text('文件上传完成'),
                                          backgroundColor: Colors.green,
                                        ),
                                      );
                                    } else {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                          content: Text('文件上传失败'),
                                          backgroundColor: Colors.red,
                                        ),
                                      );
                                    }
                                  } catch (e) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text('上传出错: $e'),
                                        backgroundColor: Colors.red,
                                      ),
                                    );
                                  }
                                },
                          child: const Text('上传服务器缺失的文件'),
                        ),
                      ),
                      const SizedBox(height: 12),

                      ElevatedButton(
                        onPressed: appState.httpHost.isEmpty
                            ? null
                            : () async {
                                // 模拟连接测试，现在只显示一个提示
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('模拟连接测试成功'),
                                    backgroundColor: Color.fromARGB(
                                      255,
                                      0,
                                      0,
                                      0,
                                    ),
                                  ),
                                );
                              },
                        child: const Text('测试HTTP连接'),
                      ),

                      const SizedBox(height: 12),


                      ElevatedButton(
                        onPressed:
                            appState.watchPath.isEmpty ||
                                appState.httpHost.isEmpty
                            ? null
                            : () async {
                                try {
                                  // 调用后端CGO库进行文件差异比较
                                  final tokenStr = appState.httpToken;
                                  if (tokenStr.isEmpty) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('请先输入访问令牌'),
                                        backgroundColor: Colors.orange,
                                      ),
                                    );
                                    return;
                                  }
                                  
                                  final tokenPtr = tokenStr.toNativeUtf8().cast<ffi.Utf8>();
                                  try {
                                    final resultPtr = synaCompareWithServer(tokenPtr);
                                    if (resultPtr.address == 0) {
                                      throw Exception('返回空结果指针');
                                    }
                                    
                                    final comparisonResult = resultPtr.toDartString();
                                    malloc.free(resultPtr);
                                    
                                    // 解析CGO库返回的JSON格式比较结果
                                    Map<String, dynamic> result = json.decode(comparisonResult);
                                    
                                    // 显示比较结果对话框
                                    showDialog(
                                      context: context,
                                      builder: (BuildContext context) {
                                        return _buildComparisonDialog(context, result);
                                      },
                                    );
                                  } finally {
                                    malloc.free(tokenPtr);
                                  }
                                } catch (e) {
                                  // 如果CGO调用失败，显示错误信息
                                  showDialog(
                                    context: context,
                                    builder: (BuildContext context) {
                                      return AlertDialog(
                                        title: const Text('比较出错'),
                                        content: Text('无法连接服务器或获取比较结果: $e'),
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
                                }
                              },
                        child: const Text('比较本地与远程文件差异'),
                      ),

                      const SizedBox(height: 16),

                      const Text(
                        '认证方式 (Authentication):',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),

                      const SizedBox(height: 8),

                      TextField(
                        decoration: const InputDecoration(
                          labelText: '访问令牌 (Access Token)',
                          hintText: '请输入访问令牌',
                          border: OutlineInputBorder(),
                        ),
                        obscureText: true,
                        onChanged: (value) => appState.httpToken = value,
                      )
                    ]
                  )
                )
              )
            ]
          ]
        )
      )
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
    // 不再调用_stopWatch，因为后端逻辑已移除
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
                    backgroundColor: Colors.orange,
                  );
                  ScaffoldMessenger.of(context).showSnackBar(snackBar);
                  return;
                }
                
                try {
                  // 使用CGO库扫描目录
                  final pathStr = appState.watchPath;
                  final pathPtr = pathStr.toNativeUtf8().cast<ffi.Utf8>();
                  final resultPtr = synaListFiles(pathPtr.cast());
                  final resultStr = resultPtr.toDartString();
                  
                  // 释放内存
                  malloc.free(pathPtr);
                  malloc.free(resultPtr);
                  
                  // 解析CGO库返回的JSON格式结果
                  List<dynamic> files = json.decode(resultStr);
                  
                  final snackBar = SnackBar(
                    content: Text('CGO扫描完成，找到${files.length}个文件'),
                    backgroundColor: Colors.green,
                  );
                  ScaffoldMessenger.of(context).showSnackBar(snackBar);
                  
                  // 将扫描结果添加到事件历史
                  appState.updateLastEvent('扫描目录: ${appState.watchPath} (${files.length}个文件)');
                } catch (e) {
                  final snackBar = SnackBar(
                    content: Text('CGO扫描失败: $e'),
                    backgroundColor: Colors.red,
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

    // 模拟上传完成
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

// 构建比较结果对话框
Widget _buildComparisonDialog(BuildContext context, Map<String, dynamic> result) {
  // 假设返回的数据结构包含 onlyLocal, onlyRemote, modified 等字段
  List<dynamic> onlyLocal = result['onlyLocal'] ?? [];
  List<dynamic> onlyRemote = result['onlyRemote'] ?? [];
  List<dynamic> modified = result['modified'] ?? [];

  return AlertDialog(
    title: const Text('文件差异比较结果'),
    content: SizedBox(
      width: double.maxFinite,
      child: ListView(
        shrinkWrap: true,
        children: [
          if (onlyLocal.isNotEmpty) ...[
            const Text(
              '仅在本地存在:',
              style: TextStyle(
                fontWeight: FontWeight.bold,
              ),
            ),
            ...onlyLocal.map((file) => ListTile(
              leading: const Icon(
                Icons.upload_file,
                color: Colors.blue,
              ),
              title: Text(file['path'] ?? file.toString()),
              subtitle: Text('大小: ${formatBytes(file['size'] ?? 0)}'),
            )),
            const Divider(),
          ],
          
          if (onlyRemote.isNotEmpty) ...[
            const Text(
              '仅在远程存在:',
              style: TextStyle(
                fontWeight: FontWeight.bold,
              ),
            ),
            ...onlyRemote.map((file) => ListTile(
              leading: const Icon(
                Icons.download,
                color: Colors.green,
              ),
              title: Text(file['path'] ?? file.toString()),
              subtitle: Text('大小: ${formatBytes(file['size'] ?? 0)}'),
            )),
            const Divider(),
          ],
          
          if (modified.isNotEmpty) ...[
            const Text(
              '修改时间不同:',
              style: TextStyle(
                fontWeight: FontWeight.bold,
              ),
            ),
            ...modified.map((file) => ListTile(
              leading: const Icon(
                Icons.update,
                color: Colors.orange,
              ),
              title: Text(file['path'] ?? file.toString()),
              subtitle: Text(
                '本地: ${file['localModTime'] ?? 'N/A'} 远程: ${file['remoteModTime'] ?? 'N/A'}',
              ),
            )),
          ],
          
          if (onlyLocal.isEmpty && onlyRemote.isEmpty && modified.isEmpty)
            const ListTile(
              leading: Icon(Icons.check, color: Colors.green),
              title: Text('本地与远程文件完全一致'),
            ),
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

// 上传功能实现
Future<bool> _performUpload(String token, String localPath) async {
  ffi.Pointer<Utf8>? tokenPtr; // 定义在函数作用域内，以便finally可以访问
  
  try {
    _log("开始上传文件，使用Token进行认证");
    
    // 将token转换为指针并调用CGO函数
    final tokenStr = token;
    tokenPtr = tokenStr.toNativeUtf8().cast<ffi.Utf8>();
    final resultPtr = synaCompareWithServer(tokenPtr);
    final resultStr = resultPtr.toDartString();
    
    // 释放内存
    malloc.free(resultPtr);
    
    _log("服务器比较结果: $resultStr");
    
    // 这里可以根据CGO库返回的结果决定如何处理上传
    // 模拟上传过程，实际上应该是通过CGO库完成上传
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
    } catch (e) {
      _log("释放内存时出现警告: $e");
    }
  }
}
