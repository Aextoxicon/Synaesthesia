# 单元测试说明文档

本文档介绍了如何为Synaesthesia Flutter应用编写和运行单元测试。

## 测试结构

单元测试文件存放在 `test/unit/` 目录下，按照功能模块组织：

- `log_manager_test.dart` - 测试日志管理功能
- `format_functions_test.dart` - 测试格式化函数
- `my_app_state_test.dart` - 测试应用状态管理
- `network_functions_test.dart` - 测试网络相关功能

## 如何运行测试

### 运行所有单元测试
```bash
flutter test test/unit/
```

### 运行单个测试文件
```bash
flutter test test/unit/log_manager_test.dart
```

### 查看测试覆盖率
```bash
flutter test --coverage
genhtml coverage/lcov.info -o coverage/html
open coverage/html/index.html
```

## 测试策略

### 1. 纯函数测试
对于像 `formatBytes` 这样的纯函数，测试各种输入和输出：

```dart
test('formatBytes should convert bytes to human readable format', () {
  expect(formatBytes(0), '0 B');
  expect(formatBytes(1024), '1.00 KB');
  expect(formatBytes(1024 * 1024), '1.00 MB');
});
```

### 2. 类方法测试
对类的方法进行测试，验证状态变化和行为：

```dart
test('should update server running state', () {
  appState.setServerRunning(true);
  expect(appState.isServerRunning, true);
});
```

### 3. 边界条件测试
测试边界条件和异常情况：

```dart
test('should maintain maximum log count', () {
  for (int i = 0; i < LogManager.maxLogLines + 10; i++) {
    logManager.log('Log message $i');
  }
  final logs = logManager.getLogs();
  expect(logs.length, LogManager.maxLogLines);
});
```

## 重构以提高可测试性

为了让代码更易于测试，我们进行了以下重构：

1. 修改 `listFiles` 函数，使其接受可选的 `HttpClient` 参数
2. 为私有方法添加公共包装器以进行测试
3. 使用依赖注入模式

## 测试最佳实践

1. **测试命名**：使用描述性的测试名称
2. **单一职责**：每个测试只验证一个行为
3. **独立性**：测试之间不应相互依赖
4. **可重复性**：测试结果应是一致的
5. **快速执行**：单元测试应快速运行
6. **全面覆盖**：覆盖各种场景，包括边界条件

## Mocking 和 Stubbing

对于外部依赖（如网络请求），使用Mockito库进行模拟：

```dart
// 示例（已在network_functions_test.dart中定义）
when(mockHttpClient.postUrl(any)).thenAnswer((_) async => mockRequest);
```

## 维护测试

当添加新功能或修改现有功能时，请确保：
1. 编写相应的单元测试
2. 运行所有测试以确保没有破坏现有功能
3. 保持高测试覆盖率