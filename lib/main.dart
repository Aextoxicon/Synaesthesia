import 'dart:async';
import 'dart:io';
import 'dart:collection';
import 'dart:math';
import 'dart:ffi';
import 'dart:ffi' as ffi;
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;

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
          body: const SyncPage(),
          bottomNavigationBar: BottomNavigationBar(
            currentIndex: 0,
            onTap: null,
            items: const [
              BottomNavigationBarItem(icon: Icon(Icons.devices), label: '设备发现'),
            ],
          ),
        );
      },
    );
  }
}


class MyAppState extends ChangeNotifier {
  var currentIdx = 0;
  String lastEvent = "No event yet";
  String watchPath = "";
  final List<String> eventHistory = [];

  SyncMode syncMode = SyncMode.server;

  void setSyncMode(SyncMode mode) {
    syncMode = mode;
    notifyListeners();
  }


  String httpHost = 'localhost';
  int httpPortC = 8080;

  String httpUser = 'user';
  String httpPwd = 'pwd123';

  MyAppState();

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

  void setIdx(int idx) {
    currentIdx = idx;
    notifyListeners();
  }

  // 移除所有后端功能函数，只保留UI状态管理
}


class SyncPage extends StatefulWidget {
  const SyncPage({super.key});

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
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


                      if (false) ...[
                        const SizedBox(height: 16),
                        const Divider(),
                        const Text(
                          'HTTP服务器状态: 已移除',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.orange,
                          ),
                        ),
                        const Text('HTTP服务器功能已暂时移除'),
                      ],
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
                                  // 模拟上传过程，现在只显示一个提示
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('模拟上传完成'),
                                      backgroundColor: Color.fromARGB(
                                        255,
                                        0,
                                        0,
                                        0,
                                      ),
                                    ),
                                  );
                                },
                          child: const Text('上传服务器缺失的文件'),
                        ),
                      ),
                      const SizedBox(height: 12),


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
                            : () {
                                // 模拟比较结果，现在只显示一个模拟对话框
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
                                            const Text(
                                              '仅在本地存在:',
                                              style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            const ListTile(
                                              leading: Icon(
                                                Icons.upload_file,
                                                color: Colors.blue,
                                              ),
                                              title: Text('/example/file.txt'),
                                            ),
                                            const Divider(),
                                            
                                            const Text(
                                              '修改时间不同:',
                                              style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            const ListTile(
                                              leading: Icon(
                                                Icons.update,
                                                color: Colors.orange,
                                              ),
                                              title: Text('/another/file.txt'),
                                              subtitle: Text(
                                                '本地: 2023-01-01 远程: 2023-01-02',
                                              ),
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
              onPressed: () {
                // 显示模拟扫描结果
                final snackBar = SnackBar(
                  content: Text('模拟CGO扫描完成，找到若干文件'),
                  backgroundColor: Colors.green,
                );
                ScaffoldMessenger.of(context).showSnackBar(snackBar);
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