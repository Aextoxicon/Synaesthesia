import 'package:flutter_test/flutter_test.dart';
import '../../lib/main.dart'; // 导入您的主文件

void main() {
  group('LogManager Tests', () {
    late LogManager logManager;

    setUp(() {
      logManager = LogManager();
    });

    tearDown(() {
      logManager.clearLogs();
    });

    test('should add log message with timestamp', () {
      logManager.log('Test message');
      final logs = logManager.getLogs();
      
      expect(logs.length, 1);
      expect(logs.first, contains('['));
      expect(logs.first, contains('] Test message'));
    });

    test('should maintain maximum log count', () {
      // 添加超过最大限制的日志
      for (int i = 0; i < LogManager.maxLogLines + 10; i++) {
        logManager.log('Log message $i');
      }
      
      final logs = logManager.getLogs();
      expect(logs.length, LogManager.maxLogLines);
    });

    test('should clear all logs', () {
      logManager.log('Test message 1');
      logManager.log('Test message 2');
      logManager.clearLogs();
      
      expect(logManager.getLogs().length, 0);
    });

    test('should notify listeners when logging', () {
      var notificationCount = 0;
      final listener = () => notificationCount++;
      
      logManager.addListener(listener);
      logManager.log('Test message');
      
      expect(notificationCount, 1);
      
      logManager.removeListener(listener);
      logManager.log('Another message');
      
      expect(notificationCount, 1); // 不应该再增加
    });
  });
}