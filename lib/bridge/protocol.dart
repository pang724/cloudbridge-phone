/// 协议常量与纯函数（与 P2 server.js 严格对齐）。
library;

/// 传输分块大小 256KB（二进制帧上限）。
const int kChunkSize = 256 * 1024;

/// 默认服务端口。
const int kDefaultPort = 18888;

/// 应用名 / 版本号（hello 帧）。
const String kAppName = '云桥备份';
const String kAppVersion = '1.0.0';

/// 清理文件名非法字符（同 server.js safeName）。
String safeName(String name) => name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

/// 同名不覆盖：name → name (1).ext / name (2).ext …（同 server.js uniquePath 命名规则）。
String uniqueName(String name, Set<String> existing) {
  final n = safeName(name);
  if (!existing.contains(n)) return n;
  final dot = n.lastIndexOf('.');
  final base = dot > 0 ? n.substring(0, dot) : n;
  final ext = dot > 0 ? n.substring(dot) : '';
  for (var i = 1; i < 10000; i++) {
    final p = '$base ($i)$ext';
    if (!existing.contains(p)) return p;
  }
  return '$base (10000)$ext';
}

/// 字节数格式化（同 server.js fmtBytes）。
String fmtBytes(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
  if (n < 1024 * 1024 * 1024) return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
  return '${(n / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}
