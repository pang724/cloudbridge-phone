import 'dart:async';

import 'package:flutter/services.dart';

import '../bridge/backend.dart';
import '../bridge/protocol.dart';

/// Android 原生层实现：MediaStore 相册 + SAF 目录（MethodChannel "cloudbridge/native"）。
class AndroidBackend implements PhoneBackend {
  AndroidBackend() {
    _events
        .receiveBroadcastStream()
        .listen(_onEvent, onError: (Object _) {});
  }

  static const MethodChannel _channel = MethodChannel('cloudbridge/native');
  static const EventChannel _events = EventChannel('cloudbridge/native/events');

  @override
  final List<void Function(String uri)> onDeepLink = [];

  // ---------- 会话状态 ----------
  bool albumsGranted = false;
  final List<Map<String, String>> _trees = []; // {uri, name}

  /// SAF 文件 id 注册表：'sf1' → {treeUri, relPath}（列表时登记，file-req 时查找）。
  int _fileSeq = 0;
  final Map<String, Map<String, String>> _files = {};

  // ---------- 基础 ----------

  Future<T?> _invoke<T>(String method, [Map<String, dynamic>? args]) =>
      _channel.invokeMethod<T>(method, args);

  @override
  Future<String> deviceName() async {
    final r = await _invoke('deviceInfo') as Map?;
    return (r?['name'] as String?) ?? '未知设备';
  }

  @override
  Future<String?> initialDeepLink() async {
    final uri = await _invoke<String>('launchUri');
    if (uri != null && uri.isNotEmpty) {
      _onEvent({'type': 'deeplink', 'uri': uri});
    }
    return uri;
  }

  void _onEvent(dynamic e) {
    if (e is Map && e['type'] == 'deeplink' && e['uri'] is String) {
      for (final f in List.of(onDeepLink)) {
        f(e['uri'] as String);
      }
    }
  }

  @override
  Future<bool> requestMediaPermission() async {
    final r = await _invoke<bool>('requestMediaPermission');
    return r == true;
  }

  @override
  Future<Map<String, dynamic>> pickSafDir() async {
    final uri = await _invoke<String>('safPick');
    if (uri == null || uri.isEmpty) return {'ok': false};
    final r = await _invoke('safTreeName', {'uri': uri}) as Map?;
    return {'ok': true, 'uri': uri, 'name': (r?['name'] as String?) ?? '目录'};
  }

  @override
  Future<void> applyGrant({
    required bool albums,
    required List<Map<String, String>> trees,
  }) async {
    albumsGranted = albums;
    _trees
      ..clear()
      ..addAll(trees.map((t) => Map<String, String>.from(t)));
    _files.clear();
    _fileSeq = 0;
  }

  // ---------- 列表 ----------

  @override
  Future<List<Map<String, dynamic>>> listAlbums() async {
    if (!albumsGranted) return const [];
    final r = await _invoke('listAlbums') as Map?;
    final list = (r?['albums'] as List?) ?? const [];
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  static const List<List<String>> _grads = [
    ['#2563EB', '#60A5FA'],
    ['#12B76A', '#6EE7B7'],
    ['#F79009', '#FDB022'],
    ['#F04438', '#F97066'],
    ['#7A5AF8', '#B4A0F8'],
    ['#06AED4', '#8AE6FC'],
  ];

  static List<String> _gradFor(String id) {
    var h = 0;
    for (final c in id.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return _grads[h % _grads.length];
  }

  @override
  Future<List<Map<String, dynamic>>> listPhotos() async {
    if (!albumsGranted) return const [];
    final r = await _invoke('listPhotos') as Map?;
    final list = (r?['photos'] as List?) ?? const [];
    return list.map((raw) {
      final p = Map<String, dynamic>.from(raw as Map);
      p['icon'] = p['type']; // PC 页面缩略图图标：image / video
      p['grad'] = _gradFor('${p['id']}'); // PC 页面占位渐变
      return p;
    }).toList();
  }

  Future<List<int>> _stats(String uri, String path) async {
    final r = await _invoke('safStats', {'uri': uri, 'path': path}) as Map?;
    return [(r?['count'] as int?) ?? 0, (r?['bytes'] as int?) ?? 0];
  }

  /// 毫秒时间戳 → 'yyyy-MM-dd HH:mm'（PC 文件列表 time 字段）。
  static String fmtTimeMs(int ms) {
    if (ms <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
  }

  Map<String, String>? _findTree(String rootName) {
    for (final t in _trees) {
      if (t['name'] == rootName) return t;
    }
    return null;
  }

  @override
  Future<List<Map<String, dynamic>>> listRoot() async {
    final out = <Map<String, dynamic>>[];
    for (final t in _trees) {
      final st = await _stats(t['uri']!, '');
      out.add({
        'id': t['name'],
        'name': t['name'],
        'files': st[0],
        'size': fmtBytes(st[1]),
      });
    }
    return out;
  }

  @override
  Future<Map<String, dynamic>> listDir(String dirId) async {
    final slash = dirId.indexOf('/');
    final rootName = slash < 0 ? dirId : dirId.substring(0, slash);
    final rel = slash < 0 ? '' : dirId.substring(slash + 1);
    final t = _findTree(rootName);
    if (t == null) throw StateError('目录未授权或已失效，请在手机端重新授权');
    final r = await _invoke('listSafDir', {'uri': t['uri'], 'path': rel}) as Map?;
    final dirs = (r?['dirs'] as List?) ?? const [];
    final files = (r?['files'] as List?) ?? const [];
    final subs = <Map<String, dynamic>>[];
    for (final d in dirs) {
      final name = (d as Map)['name'] as String;
      final st = await _stats(t['uri']!, '$rel/$name');
      subs.add({
        'id': '$dirId/$name',
        'name': name,
        'files': st[0],
        'size': fmtBytes(st[1]),
      });
    }
    final fl = <Map<String, dynamic>>[];
    for (final f in files) {
      final m = f as Map;
      final name = m['name'] as String;
      final size = (m['size'] as int?) ?? 0;
      final id = 'sf${++_fileSeq}';
      _files[id] = {'treeUri': t['uri']!, 'relPath': '$rel/$name'};
      fl.add({
        'id': id,
        'dir': dirId,
        'name': name,
        'size': fmtBytes(size),
        'sizeBytes': size,
        'time': fmtTimeMs((m['mtime'] as int?) ?? 0),
      });
    }
    return {'subs': subs, 'files': fl};
  }

  // ---------- 下载 ----------

  @override
  Future<DownloadStream> openDownload({
    required String kind,
    required String ref,
    required String name,
  }) async {
    final Map<String, dynamic> args;
    if (kind == 'photo') {
      args = {'kind': 'photo', 'ref': ref};
    } else {
      final f = _files[ref];
      if (f == null) throw StateError('文件已失效，请在 PC 端刷新列表');
      args = {'kind': 'file', 'uri': f['treeUri'], 'path': f['relPath']};
    }
    final r = await _invoke('openRead', args) as Map?;
    final handle = r?['handle'] as int?;
    if (handle == null) throw StateError('打开文件失败');
    final total = (r?['total'] as int?) ?? -1;
    return _openReadStream(handle, total < 0 ? 0 : total);
  }

  DownloadStream _openReadStream(int handle, int total) {
    final ctrl = StreamController<Uint8List>();
    var closed = false;
    Future<void> release() async {
      if (closed) return;
      closed = true;
      try {
        await _invoke('closeHandle', {'handle': handle});
      } catch (_) {}
      await ctrl.close();
    }
    unawaited(() async {
      try {
        while (!closed) {
          final chunk = await _invoke('readChunk', {'handle': handle});
          if (chunk == null) break; // EOF
          ctrl.add(Uint8List.fromList((chunk as List).cast<int>()));
        }
      } catch (e) {
        if (!closed) ctrl.addError(e);
      }
      await release();
    }());
    return DownloadStream(total: total, chunks: ctrl.stream, cancel: release);
  }

  // ---------- 上传 ----------

  @override
  Future<UploadTarget> beginUpload({
    required String kind,
    String? dir,
    String? album,
    required String name,
    required int size,
    String? mime,
  }) async {
    final safe = safeName(name);
    if (kind == 'photo') {
      final r = await _invoke('photoCreate', {
        'album': (album ?? 'all').toString(),
        'name': safe,
        'mime': (mime ?? 'image/jpeg').toString(),
      }) as Map?;
      final handle = r?['handle'] as int?;
      if (handle == null) throw StateError('创建相册文件失败');
      return _NativeUploadTarget(
        handle: handle,
        finalName: safe,
        conflict: false,
        isPhoto: true,
        album: (album ?? 'all').toString(),
      );
    }
    final rootName = (dir ?? '').split('/').first;
    final t = _findTree(rootName);
    if (t == null || rootName.isEmpty) {
      throw StateError('目录未授权或已失效，请在手机端重新授权');
    }
    final d = dir ?? '';
    final rel = d.length > rootName.length ? d.substring(rootName.length + 1) : '';
    final names = (await _invoke('safNames', {'uri': t['uri'], 'path': rel}) as List?) ??
        const [];
    final existing = names.map((e) => e as String).toSet();
    final finalName = uniqueName(name, existing);
    final conflict = finalName != safe;
    final r = await _invoke('safCreateFile', {
      'uri': t['uri'],
      'path': rel,
      'name': finalName,
      'mime': 'application/octet-stream',
    }) as Map?;
    final handle = r?['handle'] as int?;
    if (handle == null) throw StateError('创建文件失败');
    return _NativeUploadTarget(
      handle: handle,
      finalName: finalName,
      conflict: conflict,
      isPhoto: false,
    );
  }

  // ---------- 相册操作 ----------

  @override
  Future<Map<String, dynamic>> photoOp({
    required String op,
    required List<String> ids,
    String? name,
  }) async {
    if (!albumsGranted) throw StateError('相册未授权');
    final r = (await _invoke('photoOp', {
      'op': op,
      'ids': ids,
      'name': ?name,
    })) as Map?;
    if (r == null || r['ok'] != true) {
      throw StateError((r?['error'] as String?) ?? '操作失败');
    }
    return {
      'photo': r['photo'] == null ? null : Map<String, dynamic>.from(r['photo'] as Map),
    };
  }
}

/// MethodChannel 写入目标（256KB 分块 writeChunk → closeWrite）。
class _NativeUploadTarget implements UploadTarget {
  _NativeUploadTarget({
    required this.handle,
    required this.finalName,
    required this.conflict,
    required this.isPhoto,
    this.album = 'all',
  });

  final int handle;
  @override
  final String finalName;
  @override
  final bool conflict;
  final bool isPhoto;
  final String album;
  bool _closed = false;

  @override
  Future<void> add(Uint8List bytes) async {
    // 以普通 List<int> 传递，确保跨平台编解码为 List<Int>。
    await AndroidBackend._channel
        .invokeMethod('writeChunk', {'handle': handle, 'bytes': bytes.toList()});
  }

  @override
  Future<Map<String, dynamic>> finish() async {
    if (_closed) return const {};
    _closed = true;
    final r = (await AndroidBackend._channel
            .invokeMethod('closeWrite', {'handle': handle})) as Map?;
    if (isPhoto) {
      if (r?['photo'] is Map) {
        return {'photo': Map<String, dynamic>.from(r!['photo'] as Map)};
      }
      return {
        'photo': {
          'id': '',
          'name': finalName,
          'album': album,
          'type': 'image',
          'sizeBytes': (r?['sizeBytes'] as int?) ?? 0,
        }
      };
    }
    return {'conflict': conflict, 'renamed': conflict ? finalName : null};
  }
}
