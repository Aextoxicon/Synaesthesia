import 'package:flutter_test/flutter_test.dart';
import '../../lib/main.dart'; // 导入您的主文件

void main() {
  group('MyAppState Tests', () {
    late MyAppState appState;

    setUp(() {
      appState = MyAppState();
    });

    test('should initialize with correct default values', () {
      expect(appState.currentIdx, 0);
      expect(appState.syncMode, SyncMode.server);
      expect(appState.isServerRunning, false);
      expect(appState.watchPath, '');
      expect(appState.eventHistory, isEmpty);
      expect(appState.httpHost, 'localhost');
      expect(appState.httpPortC, 8080);
      expect(appState.httpToken, '');
    });

    test('should update index and sync mode correctly', () {
      appState.setIdx(1);
      
      expect(appState.currentIdx, 1);
      expect(appState.syncMode, SyncMode.client);
    });

    test('should set sync mode correctly', () {
      appState.setSyncMode(SyncMode.client);
      
      expect(appState.syncMode, SyncMode.client);
      expect(appState.currentIdx, 1);
    });

    test('should update server running state', () {
      appState.setServerRunning(true);
      
      expect(appState.isServerRunning, true);
    });

    test('should update watch path', () {
      const testPath = '/test/path';
      appState.setWatchPath(testPath);
      
      expect(appState.watchPath, testPath);
    });

    test('should update last event and history', () {
      const testEvent = 'Test event';
      appState.updateLastEvent(testEvent);
      
      expect(appState.lastEvent, testEvent);
      expect(appState.eventHistory, contains(testEvent));
      expect(appState.eventHistory.length, 1);
    });

    test('should maintain event history limit', () {
      // 添加超过100个事件
      for (int i = 0; i < 105; i++) {
        appState.updateLastEvent('Event $i');
      }
      
      expect(appState.eventHistory.length, 100);
      expect(appState.eventHistory.first, 'Event 104'); // 最新事件在前面
    });
  });
}