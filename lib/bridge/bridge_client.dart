import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'backend.dart';
import 'protocol.dart';

/// WebSocket 工厂（可注入，便于单测）。
typedef SocketFactory = WebSocketChannel Function(Uri uri);

/// 会话状态机：idle → connecting → awaitingGrant → authed → closed。
enum BridgeState { idle, connecting, awaitingGrant, authed, closing, closed }

/// 云桥备份 P3 协议客户端（手机 → PC）。
///
/// 严格对齐 P2 server.js 协议：
///  - 手机→PC：hello / grant / deny / list-res / file-head / 二进制块 / file-end /
///    upload-res / photo-upload-res / photo-res
///  - PC→手机：welcome / grant-res / list-req / file-req / upload-head / upload-tail / photo-op
///  - 连接：ws://ip:port/?token=xxx；4001=token 吊销(kick)；4000=被顶替。
class BridgeClient {
  BridgeClient(this.backend, {SocketFactory? socketFactory})
      : _socketFactory =
            socketFactory ?? ((uri) => WebSocketChannel.connect(uri));

  final PhoneBackend backend;
  final SocketFactory _socketFactory;

  BridgeState state = BridgeState.idle;

  /// PC 信息（welcome 帧）：{name, ip, app}。
  final Map<String, String> pcInfo = {};

  /// 连接关闭回调 (closeCode, closeReason)。
  final List<void Function(int? code, String? reason)> onClose = [];

  /// 状态变化回调。
  final List<void Function(BridgeState state)> onState = [];

  /// 传输/操作日志回调 (text, kind: info|ok|warn|error)。
  final List<void Function(String text, String kind)> onLog = [];

  WebSocketChannel? _ws;
  StreamSubscription<dynamic>? _sub;
  Timer? _closeGuard;

  /// 当前进行中的上传（PC 顺序上传，任一时刻至多一个活跃）。
  Map<String, dynamic>? _active;
  final Map<String, Map<String, dynamic>> _uploads = {};

  void log(String text, [String kind = 'info']) {
    for (final f in List.of(onLog)) {
      f(text, kind);
    }
  }

  void _change(BridgeState s) {
    if (state == s) return;
    state = s;
    for (final f in List.of(onState)) {
      f(s);
    }
  }

  /* ---------- 连接管理 ---------- */

  Future<void> connect({
    required String ip,
    required int port,
    required String token,
  }) async {
    if (state != BridgeState.idle && state != BridgeState.closed) {
      throw StateError('当前状态（$state）不可发起连接');
    }
    _change(BridgeState.connecting);
    final uri = Uri.parse('ws://$ip:$port/?token=$token');
    final ws = _socketFactory(uri);
    try {
      await ws.ready;
    } catch (e) {
      _change(BridgeState.closed);
      throw StateError('无法连接 $ip:$port（$e）');
    }
    _ws = ws;
    await _sub?.cancel();
    _sub = ws.stream.listen(_onData,
        onDone: _handleDone,
        onError: (Object e) {
          log('连接异常：$e', 'error');
          _handleDone();
        });
    final name = await backend.deviceName();
    send('hello', {'name': name, 'platform': 'android', 'ver': kAppVersion});
    log('已连接 $ip:$port，等待 PC 端确认', 'info');
  }

  /// 用户同意授权：albums=是否暴露全部相册；trees=已选 SAF 目录（uri+name）。
  Future<void> grant({
    required bool albums,
    required List<Map<String, String>> trees,
  }) async {
    await backend.applyGrant(albums: albums, trees: trees);
    send('grant', {
      'id': 'g1',
      'albums': albums ? ['all'] : <String>[],
      'dirs': trees.map((t) => t['name'] as String).toList(),
      'dirsMode': 'ro',
    });
  }

  /// 用户拒绝连接。
  Future<void> deny() async {
    send('deny', {});
  }

  Future<void> close() async {
    if (state == BridgeState.closed) return;
    _change(BridgeState.closing);
    try {
      await _ws?.sink.close();
    } catch (_) {}
    // 兜底：onDone 迟迟不来（网络黑洞）时强制收尾。
    _closeGuard?.cancel();
    _closeGuard = Timer(const Duration(seconds: 3), _handleDone);
  }

  void _handleDone() {
    _closeGuard?.cancel();
    final code = _ws?.closeCode;
    final reason = _ws?.closeReason ?? '';
    if (state == BridgeState.closed) return;
    _sub?.cancel();
    _sub = null;
    _ws = null;
    _active = null;
    _uploads.clear();
    _change(BridgeState.closed);
    for (final f in List.of(onClose)) {
      f(code, reason);
    }
  }

  /* ---------- 发送 ---------- */

  void send(String t, [Map<String, dynamic>? payload]) {
    final ws = _ws;
    if (ws == null) return;
    final m = <String, dynamic>{'t': t};
    if (payload != null) m.addAll(payload);
    ws.sink.add(jsonEncode(m));
  }

  void sendBytes(List<int> bytes) {
    _ws?.sink.add(bytes);
  }

  /* ---------- 接收 ---------- */

  void _onData(dynamic data) {
    if (data is List<int>) {
      _onBytes(Uint8List.fromList(data));
      return;
    }
    final raw = data is String ? data : utf8.decode(data as List<int>);
    _onText(raw);
  }

  void _onText(String raw) {
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final t = msg['t'];
    switch (t) {
      case 'welcome':
        final pc = msg['pc'];
        if (pc is Map) {
          pcInfo
            ..['name'] = (pc['name'] ?? '') as String
            ..['ip'] = (pc['ip'] ?? '') as String
            ..['app'] = (pc['app'] ?? '') as String;
        }
        if (state == BridgeState.connecting) _change(BridgeState.awaitingGrant);
        break;
      case 'grant-res':
        if (msg['ok'] == true && state == BridgeState.awaitingGrant) {
          _change(BridgeState.authed);
        }
        break;
      case 'list-req':
        unawaited(_handleList(msg));
        break;
      case 'file-req':
        unawaited(_handleFileReq(msg));
        break;
      case 'upload-head':
        _handleUploadHead(msg);
        break;
      case 'upload-tail':
        unawaited(_handleUploadTail(msg));
        break;
      case 'photo-op':
        unawaited(_handlePhotoOp(msg));
        break;
      default:
        break;
    }
  }

  /* ---------- 列表 ---------- */

  Future<void> _handleList(Map<String, dynamic> msg) async {
    final id = (msg['id'] ?? '') as String;
    final what = (msg['what'] ?? '') as String;
    final dir = (msg['dir'] ?? '') as String;
    try {
      final res = <String, dynamic>{'id': id};
      switch (what) {
        case 'albums':
          res['albums'] = await backend.listAlbums();
          break;
        case 'photos':
          res['photos'] = await backend.listPhotos();
          break;
        case 'root':
          res['dirs'] = await backend.listRoot();
          break;
        case 'dir':
          final r = await backend.listDir(dir);
          res['subs'] = r['subs'];
          res['files'] = r['files'];
          break;
        default:
          break;
      }
      send('list-res', res);
    } catch (e) {
      log('列表请求失败（$what）：$e', 'warn');
      send('list-res', {'id': id});
    }
  }

  /* ---------- 下载（手机 → PC） ---------- */

  Future<void> _handleFileReq(Map<String, dynamic> msg) async {
    final id = (msg['id'] ?? '') as String;
    final kind = (msg['kind'] ?? 'photo') as String;
    final ref = (msg['ref'] ?? '') as String;
    final name = (msg['name'] ?? 'file') as String;
    DownloadStream? stream;
    try {
      stream = await backend.openDownload(kind: kind, ref: ref, name: name);
      send('file-head', {'id': id, 'total': stream.total});
    } catch (e) {
      log('下载失败：$name（$e）', 'warn');
      send('file-head', {'id': id, 'total': 0});
      send('file-end', {'id': id, 'ok': false, 'error': '$e'});
      return;
    }
    log('开始下载 $name', 'info');
    var ok = true;
    try {
      await for (final chunk in stream.chunks) {
        sendBytes(chunk);
      }
    } catch (e) {
      ok = false;
      log('下载中断：$name（$e）', 'warn');
    }
    await stream.cancel();
    if (ok) {
      send('file-end', {'id': id, 'ok': true});
      log('下载完成 $name', 'ok');
    } else {
      send('file-end', {'id': id, 'ok': false, 'error': '传输中断'});
    }
  }

  /* ---------- 上传（PC → 手机，块可能先于文件创建到达，需缓冲） ---------- */

  void _handleUploadHead(Map<String, dynamic> msg) {
    final id = (msg['id'] ?? '') as String;
    final up = <String, dynamic>{
      'id': id,
      'kind': (msg['kind'] ?? 'file') as String,
      'name': (msg['name'] ?? 'upload') as String,
      'size': (msg['size'] ?? 0) as int,
      'dir': (msg['dir'] ?? '') as String,
      'album': (msg['album'] ?? '') as String,
      'mime': (msg['mime'] ?? '') as String,
      'buffered': <Uint8List>[],
      'target': null,
      'ready': false,
      'tail': false,
      'finished': false,
      'error': null,
    };
    _uploads[id] = up;
    _active = up;
    log('开始上传 ${up['name']}（${fmtBytes(up['size'] as int)}）', 'info');
    unawaited(_prepareUpload(up));
  }

  Future<void> _prepareUpload(Map<String, dynamic> up) async {
    try {
      final target = await backend.beginUpload(
        kind: up['kind'] as String,
        dir: up['kind'] == 'photo' ? null : up['dir'] as String,
        album: up['kind'] == 'photo' ? up['album'] as String : null,
        name: up['name'] as String,
        size: up['size'] as int,
        mime: up['mime'] as String,
      );
      up['target'] = target;
      up['ready'] = true;
      await _maybeFinishUpload(up);
    } catch (e) {
      up['error'] = e.toString();
      log('上传失败：${up['name']}（$e）', 'warn');
      await _maybeFinishUpload(up);
    }
  }

  void _onBytes(Uint8List bytes) {
    final up = _active;
    if (up == null || up['finished'] == true) return;
    if (up['ready'] == true) {
      unawaited((up['target'] as UploadTarget).add(bytes));
    } else {
      (up['buffered'] as List<Uint8List>).add(bytes);
    }
  }

  Future<void> _handleUploadTail(Map<String, dynamic> msg) async {
    final up = _uploads[(msg['id'] ?? '') as String];
    if (up == null || up['finished'] == true) return;
    up['tail'] = true;
    await _maybeFinishUpload(up);
  }

  Future<void> _maybeFinishUpload(Map<String, dynamic> up) async {
    if (up['finished'] == true) return;
    if (up['tail'] != true) return;
    if (up['ready'] != true && up['error'] == null) return; // 等待文件创建完成
    up['finished'] = true;
    final id = up['id'] as String;
    final kind = up['kind'] as String;
    final resType = kind == 'photo' ? 'photo-upload-res' : 'upload-res';
    if (up['error'] != null) {
      send(resType, {'id': id, 'ok': false});
      _afterUploadDone(up);
      return;
    }
    try {
      for (final b in up['buffered'] as List<Uint8List>) {
        await (up['target'] as UploadTarget).add(b);
      }
      final info = await (up['target'] as UploadTarget).finish();
      if (kind == 'photo') {
        send(resType, {'id': id, 'ok': true, 'photo': info['photo']});
        log('已上传到相册 ${up['name']}', 'ok');
      } else {
        final conflict = info['conflict'] == true;
        send(resType, {
          'id': id,
          'ok': true,
          if (conflict) 'conflict': true,
          if (conflict) 'renamed': info['renamed'],
        });
        log(conflict
            ? '已上传 ${up['name']}（同名，改存为 ${info['renamed']}，未覆盖）'
            : '已上传 ${up['name']}',
            conflict ? 'warn' : 'ok');
      }
    } catch (e) {
      log('上传失败：${up['name']}（$e）', 'warn');
      send(resType, {'id': id, 'ok': false});
    }
    _afterUploadDone(up);
  }

  void _afterUploadDone(Map<String, dynamic> up) {
    _uploads.remove(up['id']);
    if (identical(_active, up)) _active = null;
  }

  /* ---------- 相册操作 ---------- */

  Future<void> _handlePhotoOp(Map<String, dynamic> msg) async {
    final id = (msg['id'] ?? '') as String;
    final op = (msg['op'] ?? 'del') as String;
    final ids = ((msg['ids'] as List?) ?? const []).map((e) => e as String).toList();
    try {
      final r = await backend.photoOp(
          op: op, ids: ids, name: msg['name'] as String?);
      send('photo-res', {'id': id, 'ok': true, 'photo': r['photo']});
      log(op == 'del' ? '已删除 ${ids.length} 个媒体' : '已重命名', 'ok');
    } catch (e) {
      log('相册操作失败：$e', 'warn');
      send('photo-res', {'id': id, 'ok': false});
    }
  }
}
