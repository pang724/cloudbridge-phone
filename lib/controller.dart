import 'dart:async';

import 'package:flutter/foundation.dart';

import 'backend/android_backend.dart';
import 'bridge/backend.dart';
import 'bridge/bridge_client.dart';
import 'bridge/protocol.dart';

class LogEntry {
  LogEntry(this.text, this.kind) : at = DateTime.now();
  final String text;
  final String kind; // info | ok | warn | error
  final DateTime at;

  String get time {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(at.hour)}:${two(at.minute)}:${two(at.second)}';
  }
}

/// 应用状态中枢：连接参数 / 深链 / 授权 / 传输日志 / 自动重连。
class BridgeController extends ChangeNotifier {
  BridgeController({PhoneBackend? backend, SocketFactory? socketFactory}) {
    final b = backend ?? AndroidBackend();
    _backend = b;
    _client = BridgeClient(b, socketFactory: socketFactory);
    _client.onState.add(_onState);
    _client.onClose.add(_onClose);
    _client.onLog.add((t, k) => addLog(t, k));
    b.onDeepLink.add(applyDeepLink);
    unawaited(_init());
  }

  late final PhoneBackend _backend;
  late final BridgeClient _client;

  // ---------- 连接参数（连接页输入 / 深链预填） ----------
  String ip = '';
  String port = '$kDefaultPort';
  String token = '';

  /// 深链/外部修改连接参数后自增，供连接页同步输入框。
  int connVersion = 0;

  String? error;
  String deviceName = '';

  int get portInt => int.tryParse(port) ?? kDefaultPort;

  bool get connecting =>
      _client.state == BridgeState.connecting || _client.state == BridgeState.closing;

  // ---------- 授权页 ----------
  String get screen => _screen;
  String _screen = 'connect'; // connect | grant | session

  String get pcName => _client.pcInfo['name'] ?? '';
  String get pcIp => _client.pcInfo['ip'] ?? '';

  bool albums = true;
  final List<Map<String, String>> trees = []; // {uri, name}

  // ---------- 已连接页 ----------
  final List<LogEntry> logs = [];
  bool _hadGrant = false;
  Map<String, dynamic>? _lastGrant;
  int _retries = 0;
  Timer? _reconnectTimer;

  void _setScreen(String s) {
    if (_screen == s) return;
    _screen = s;
    notifyListeners();
  }

  void addLog(String text, [String kind = 'info']) {
    logs.add(LogEntry(text, kind));
    if (logs.length > 200) logs.removeRange(0, logs.length - 200);
    notifyListeners();
  }

  // ---------- 深链 ----------

  Future<void> _init() async {
    try {
      final uri = await _backend.initialDeepLink();
      if (uri != null && uri.isNotEmpty) applyDeepLink(uri);
    } catch (_) {}
  }

  /// cloudbridge://connect?ip=..&port=..&token=..
  void applyDeepLink(String uri) {
    final q = Uri.tryParse(uri)?.queryParameters;
    if (q == null) return;
    if (q['ip'] != null && q['token'] != null) {
      ip = q['ip']!;
      if (q['port'] != null) port = q['port']!;
      token = q['token']!;
      connVersion++;
      addLog('已读取连接信息（$ip:$port）', 'ok');
    }
  }

  // ---------- 连接 / 断开 ----------

  Future<void> connect() async {
    error = null;
    _retries = 0;
    _lastGrant = null;
    notifyListeners();
    try {
      await _client.connect(ip: ip, port: portInt, token: token);
      deviceName = await _backend.deviceName();
    } catch (e) {
      error = '$e';
      addLog('$e', 'error');
    }
    notifyListeners();
  }

  Future<void> disconnect() async {
    _lastGrant = null;
    _hadGrant = false;
    _stopAutoReconnect();
    await _client.close();
    _setScreen('connect');
    addLog('已断开连接', 'info');
  }

  // ---------- 授权 ----------

  void setAlbums(bool v) {
    albums = v;
    notifyListeners();
  }

  bool get hasScope => albums || trees.isNotEmpty;

  Future<void> pickSafDir() async {
    try {
      final r = await _backend.pickSafDir();
      if (r['ok'] == true) {
        trees.add({'uri': r['uri'], 'name': r['name']});
        addLog('已添加目录 ${r['name']}（只读暴露）', 'info');
      }
    } catch (e) {
      error = '$e';
    }
    notifyListeners();
  }

  void removeTree(int index) {
    if (index < 0 || index >= trees.length) return;
    final t = trees.removeAt(index);
    addLog('已移除目录 ${t['name']}');
  }

  Future<void> confirmGrant() async {
    error = null;
    notifyListeners();
    if (albums) {
      try {
        await _backend.requestMediaPermission();
      } catch (_) {}
    }
    _lastGrant = {'albums': albums, 'trees': List.of(trees)};
    _hadGrant = true;
    _retries = 0;
    try {
      await _client.grant(albums: albums, trees: trees);
      addLog('已允许连接：相册${albums ? ' 全部' : ' 无'} + 目录 ${trees.length} 个（只读）', 'ok');
    } catch (e) {
      error = '$e';
      addLog('授权失败：$e', 'error');
    }
    notifyListeners();
  }

  Future<void> denyGrant() async {
    _lastGrant = null;
    _hadGrant = false;
    await _client.deny();
    await _client.close();
    _setScreen('connect');
    addLog('已拒绝本次连接', 'warn');
  }

  // ---------- 状态 / 关闭事件 ----------

  void _onState(BridgeState s) {
    switch (s) {
      case BridgeState.awaitingGrant:
        _setScreen('grant');
        break;
      case BridgeState.authed:
        _setScreen('session');
        break;
      default:
        break;
    }
  }

  void _onClose(int? code, String? reason) {
    if (code == 4001) {
      // PC 端吊销 token（kick）
      _stopAutoReconnect();
      _lastGrant = null;
      _hadGrant = false;
      error = 'PC 端已吊销本次连接（token 失效），请重新扫码或手动连接';
      _setScreen('connect');
      addLog('连接被 PC 端吊销（token 失效）', 'error');
      return;
    }
    if (code == 4000) {
      _stopAutoReconnect();
      _lastGrant = null;
      _hadGrant = false;
      error = '连接已被其他设备顶替，请重新连接';
      _setScreen('connect');
      addLog('连接被其他设备顶替', 'warn');
      return;
    }
    if (_hadGrant && _lastGrant != null) {
      addLog('连接断开，将自动重连并重新授权…', 'warn');
      _scheduleReconnect();
    } else {
      _setScreen('connect');
      addLog('与 PC 的连接已断开', 'warn');
    }
  }

  void _stopAutoReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  void _scheduleReconnect() {
    if (_retries >= 5) {
      _giveUpReconnect();
      return;
    }
    _reconnectTimer = Timer(const Duration(seconds: 2), _doReconnect);
  }

  Future<void> _doReconnect() async {
    _reconnectTimer = null;
    final g = _lastGrant;
    if (g == null) return;
    _retries++;
    addLog('自动重连（第 $_retries/5 次）…');
    notifyListeners();
    try {
      await _client.connect(ip: ip, port: portInt, token: token);
      await _client.grant(
        albums: g['albums'] as bool,
        trees: (g['trees'] as List).cast<Map<String, String>>(),
      );
      _retries = 0;
      addLog('已自动重连并重新授权', 'ok');
    } catch (e) {
      addLog('自动重连失败：$e', 'warn');
      if (_retries >= 5) {
        _giveUpReconnect();
      } else {
        _scheduleReconnect();
      }
    }
    notifyListeners();
  }

  void _giveUpReconnect() {
    _lastGrant = null;
    _hadGrant = false;
    error = '自动重连失败（已重试 5 次），请手动连接';
    _setScreen('connect');
    addLog('自动重连已停止', 'error');
  }
}
