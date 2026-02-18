import 'package:flutter_test/flutter_test.dart';
import '../../lib/main.dart'; // 导入您的主文件

void main() {
  group('Format Functions Tests', () {
    test('formatBytes should convert bytes to human readable format', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(1024), '1.00 KB');
      expect(formatBytes(1024 * 1024), '1.00 MB');
      expect(formatBytes(1024 * 1024 * 1024), '1.00 GB');
      expect(formatBytes(1024 * 1024 * 1024 * 1024), '1.00 TB');
    });

    test('formatBytes should handle custom decimal places', () {
      expect(formatBytes(1500, decimalPlaces: 1), '1.5 KB');
      // 修复：1500字节四舍五入到0个小数位应该是1KB，而不是2KB
      expect(formatBytes(1500, decimalPlaces: 0), '1 KB');
      expect(formatBytes(1024 * 1024 * 1024, decimalPlaces: 3), '1.000 GB');
    });

    test('formatBytes should handle edge cases', () {
      expect(formatBytes(1), '1.00 B');
      expect(formatBytes(1023), '1023.00 B');
      expect(formatBytes(1024), '1.00 KB');
    });
  });
}