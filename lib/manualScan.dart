import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'watcher.dart';

// 为Android准备的，因为Android对于watcher兼容性很差
class manual implements watcherd {
  final StreamController<Map<String, String>> _controller =
      StreamController.broadcast();
  Timer? _timer;
  String? _currentPath;
  Map<String, FileSystemEntity> _preFileStates = {};

  @override
  Stream<Map<String, String>> get onEvent => _controller.stream;

  @override
  void startWatch(String path) {
    _currentPath = path;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 5), (timer) {
      _scanDirectory(Directory(path));
    });
    _scanDirectory(Directory(path));
  }

  @override
  void stopWatch() {
    _timer?.cancel();
    _currentPath = null;
  }

  Future<void> _scanDirectory(Directory directory) async {
    final Map<String, FileSystemEntity> newFileStates = {};

    try {
      if (!directory.existsSync()) {
        final scanError = {
          'type': 'error',
          'message': 'Directory "${directory.path}" does not exist.',
          'timestamp': DateTime.now().toIso8601String(),
        };
        _controller.add({'event': jsonEncode(scanError)});
        return;
      }

      await for (final entity in directory.list(recursive: true)) {
        // 忽略 .scan_result.json 文件（虽然已经移除了，但保留以防万一）
        if (entity.path.contains('.scan_result.json')) {
          continue;
        }

        newFileStates[entity.path] = entity;
      }

      _compareAndSendEvents(newFileStates);
    } catch (e) {
      final scanError = {
        'type': 'error',
        'message': '扫描目录出错: $e',
        'timestamp': DateTime.now().toIso8601String(),
      };
      _controller.add({'event': jsonEncode(scanError)});
    }
  }

  void _compareAndSendEvents(Map<String, FileSystemEntity> newFileStates) {
    newFileStates.forEach((path, newEntity) {
      final eventData = {
        'type': '',
        'path': path,
        'timestamp': DateTime.now().toIso8601String(),
      };

      if (!_preFileStates.containsKey(path)) {
        eventData['type'] = '新增';
        _controller.add({'event': jsonEncode(eventData)});
      } else if (_preFileStates[path]!.statSync().modified.isBefore(
        newEntity.statSync().modified,
      )) {
        eventData['type'] = '修改';
        _controller.add({'event': jsonEncode(eventData)});
      }
    });

    _preFileStates.forEach((path, oldEntity) {
      if (!newFileStates.containsKey(path)) {
        final eventData = {
          'type': '移除',
          'path': path,
          'timestamp': DateTime.now().toIso8601String(),
        };
        _controller.add({'event': jsonEncode(eventData)});
      }
    });

    _preFileStates = newFileStates;
    _controller.add({"扫描完成": '扫描完成。发现 ${newFileStates.length} 个文件/目录。'});
  }

  void dispose() {
    stopWatch();
    _preFileStates.clear();
    _controller.close();
  }
}
