import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:phone_bridge/bridge/backend.dart';
import 'package:phone_bridge/bridge/bridge_client.dart';
import 'package:phone_bridge/bridge/protocol.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/* ================= 测试桩 ================= */

/// 模拟 PC 端 WebSocket。
class FakeSocket extends Fake implements WebSocketChannel {
  final _stream = StreamController<dynamic>();
  final sent = <dynamic>[];
  int? _cc;
  String? _cr;
  FakeSink? _sink;

  @override
  Future<void> get ready async {}

  @override
  Stream<dynamic> get stream => _stream.stream;

  @override
  WebSocketSink get sink => _sink ??= FakeSink(this);

  @override
  int? get closeCode => _cc;

  @override
  String? get closeReason => _cr;

  void serverText(Map<String, dynamic> m) => _stream.add(jsonEncode(m));
  void serverBytes(List<int> b) => _stream.add(b);

  void serverClose([int code = 1000, String reason = '']) {
    _cc = code;
    _cr = reason;
    _stream.close();
  }

  void clientClosed(int? code, String? reason) {
    _cc ??= 1000;
    _cr ??= '';
    _stream.close();
  }

  bool get lastIs => sent.isNotEmpty && sent.last is String;
  Map<String, dynamic> get lastText =>
      jsonDecode(sent.last as String) as Map<String, dynamic>;
}

class FakeSink extends Fake implements WebSocketSink {
  FakeSink(this._socket);
  final FakeSocket _socket;

  @override
  void add(dynamic data) => _socket.sent.add(data);

  @override
  Future<void> close([int? closeCode, String? closeReason]) {
    _socket.clientClosed(closeCode, closeReason);
    return Future.value();
  }
}

/// 模拟手机数据层。
class FakeBackend implements PhoneBackend {
  String device = '测试手机';
  final albums = [
    {'id': 'all', 'name': '全部', 'count': 2, 'size': '300.0 KB'},
    {'id': 'i1', 'name': 'DCIM', 'count': 2, 'size': '300.0 KB'},
  ];
  final photos = [
    {
      'id': 'i100',
      'name': 'a.jpg',
      'type': 'image',
      'size': '150.0 KB',
      'sizeBytes': 153600,
      'time': '2026-01-01 10:00',
      'album': 'i1',
      'icon': 'image',
      'grad': ['#2563EB', '#60A5FA'],
    },
  ];
  final rootDirs = [
    {'id': 'Download', 'name': 'Download', 'files': 1, 'size': '100.0 KB'},
  ];
  Uint8List downloadData = Uint8List(0);
  final uploaded = BytesBuilder();
  final photoOps = <Map<String, Object?>>[];
  final appliedGrants = <Map<String, Object>>[];
  bool failDownload = false;

  @override
  final List<void Function(String uri)> onDeepLink = [];

  @override
  Future<String> deviceName() async => device;

  @override
  Future<List<Map<String, dynamic>>> listAlbums() async => albums;

  @override
  Future<List<Map<String, dynamic>>> listPhotos() async => photos;

  @override
  Future<List<Map<String, dynamic>>> listRoot() async => rootDirs;

  @override
  Future<Map<String, dynamic>> listDir(String dirId) async =>
      {'subs': <Map<String, dynamic>>[], 'files': <Map<String, dynamic>>[]};

  @override
  Future<void> applyGrant({
    required bool albums,
    required List<Map<String, String>> trees,
  }) async {
    appliedGrants.add({'albums': albums, 'trees': trees});
  }

  @override
  Future<Map<String, dynamic>> pickSafDir() async => {'ok': false};

  @override
  Future<bool> requestMediaPermission() async => true;

  @override
  Future<String?> initialDeepLink() async => null;

  @override
  Future<DownloadStream> openDownload({
    required String kind,
    required String ref,
    required String name,
  }) async {
    if (failDownload) throw StateError('打开失败');
    final data = downloadData;
    final ctrl = StreamController<Uint8List>();
    unawaited(() async {
      for (var off = 0; off < data.length; off += kChunkSize) {
        final end = off + kChunkSize < data.length ? off + kChunkSize : data.length;
        ctrl.add(Uint8List.sublistView(data, off, end));
      }
      await ctrl.close();
    }());
    return DownloadStream(
        total: data.length, chunks: ctrl.stream, cancel: () async {});
  }

  @override
  Future<UploadTarget> beginUpload({
    required String kind,
    String? dir,
    String? album,
    required String name,
    required int size,
    String? mime,
  }) async {
    return _FakeTarget(this, kind, name);
  }

  @override
  Future<Map<String, dynamic>> photoOp({
    required String op,
    required List<String> ids,
    String? name,
  }) async {
    photoOps.add({'op': op, 'ids': ids, 'name': name});
    if (op == 'rename') return {'photo': {'id': ids.first, 'name': name}};
    return {'photo': null};
  }
}

class _FakeTarget implements UploadTarget {
  _FakeTarget(this.backend, this.kind, this.finalName);
  final FakeBackend backend;
  final String kind;

  @override
  final String finalName;

  @override
  bool get conflict => kind == 'file';

  @override
  Future<void> add(Uint8List bytes) async => backend.uploaded.add(bytes);

  @override
  Future<Map<String, dynamic>> finish() async => kind == 'photo'
      ? {
          'photo': {
            'id': 'i999',
            'name': finalName,
            'album': 'i1',
            'type': 'image',
            'sizeBytes': 10,
          }
        }
      : {'conflict': true, 'renamed': '$finalName (1)'};
}

/// 连接 + 授权完成的环境。
class Env {
  Env() {
    client = BridgeClient(backend, socketFactory: (_) => fake);
  }
  final backend = FakeBackend();
  final fake = FakeSocket();
  late final BridgeClient client;

  Future<void> auth() async {
    await client.connect(ip: '1.1.1.1', port: 18888, token: 't');
    fake.sent.clear();
    fake.serverText({
      't': 'welcome',
      'ok': true,
      'pc': {'name': 'PC1', 'ip': '1.1.1.1', 'app': '云桥备份 P2'}
    });
    await until(() => client.state == BridgeState.awaitingGrant);
    await client.grant(
        albums: true,
        trees: [
          {'uri': 'content://t1', 'name': 'Download'}
        ]);
    final g = jsonDecode(fake.sent.removeAt(0)) as Map<String, dynamic>;
    expect(g['t'], 'grant');
    expect(g['albums'], ['all']);
    expect(g['dirs'], ['Download']);
    expect(g['dirsMode'], 'ro');
    fake.sent.clear();
    fake.serverText({'t': 'grant-res', 'id': g['id'], 'ok': true, 'token': 't'});
    await until(() => client.state == BridgeState.authed);
    fake.sent.clear();
  }
}

/// 轮询等待条件成立（每轮让出一个事件循环）。
Future<void> until(bool Function() cond, {int max = 2000}) async {
  for (var i = 0; i < max && !cond(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  if (!cond()) {
    fail('等待超时：条件在 $max 轮内未满足');
  }
}

bool lastIsType(FakeSocket s, String type) =>
    s.lastIs && s.lastText['t'] == type;

/* ================= 用例 ================= */

void main() {
  group('协议常量与纯函数', () {
    test('uniqueName 同名改名规则与 server.js 一致', () {
      expect(uniqueName('a.txt', {}), 'a.txt');
      expect(uniqueName('a.txt', {'a.txt'}), 'a (1).txt');
      expect(uniqueName('a.txt', {'a.txt', 'a (1).txt'}), 'a (2).txt');
      expect(uniqueName('noext', {'noext'}), 'noext (1)');
      expect(uniqueName('x.mp4', {'x.mp4', 'x (1).mp4', 'x (2).mp4'}),
          'x (3).mp4');
    });

    test('safeName 清理非法字符', () {
      expect(safeName('a/b:c*d?.txt'), 'a_b_c_d_.txt');
      expect(safeName('ok.txt'), 'ok.txt');
    });

    test('fmtBytes 与 server.js 一致', () {
      expect(fmtBytes(512), '512 B');
      expect(fmtBytes(1024 * 300), '300.0 KB');
      expect(fmtBytes(1024 * 1024 * 5), '5.0 MB');
    });
  });

  group('BridgeClient', () {
    test('握手：hello → welcome → awaitingGrant', () async {
      final env = Env();
      await env.client.connect(ip: '1.2.3.4', port: 18888, token: 'tok');
      expect(env.client.state, BridgeState.connecting);
      expect(env.fake.sent, hasLength(1));
      final hello = jsonDecode(env.fake.sent.removeAt(0)) as Map<String, dynamic>;
      expect(hello['t'], 'hello');
      expect(hello['name'], '测试手机');
      expect(hello['platform'], 'android');
      expect(hello['ver'], kAppVersion);

      env.fake.serverText({
        't': 'welcome',
        'ok': true,
        'pc': {'name': 'PC1', 'ip': '1.2.3.4', 'app': '云桥备份 P2'}
      });
      await until(() => env.client.state == BridgeState.awaitingGrant);
      expect(env.client.pcInfo['name'], 'PC1');
    });

    test('授权与列表：grant-res → authed；list-req → list-res', () async {
      final env = Env();
      await env.auth();
      expect(env.backend.appliedGrants, hasLength(1));

      env.fake.serverText(
          {'t': 'list-req', 'id': 'c1', 'what': 'albums', 'dir': ''});
      await until(() => lastIsType(env.fake, 'list-res'));
      expect(env.fake.lastText['id'], 'c1');
      expect(env.fake.lastText['albums'], env.backend.albums);
      env.fake.sent.clear();

      env.fake.serverText(
          {'t': 'list-req', 'id': 'c2', 'what': 'photos', 'dir': ''});
      await until(() => lastIsType(env.fake, 'list-res'));
      expect(env.fake.lastText['photos'], env.backend.photos);
      env.fake.sent.clear();

      env.fake.serverText({'t': 'list-req', 'id': 'c3', 'what': 'root', 'dir': ''});
      await until(() => lastIsType(env.fake, 'list-res'));
      expect(env.fake.lastText['dirs'], env.backend.rootDirs);
      env.fake.sent.clear();

      env.fake.serverText(
          {'t': 'list-req', 'id': 'c4', 'what': 'dir', 'dir': 'Download'});
      await until(() => lastIsType(env.fake, 'list-res'));
      expect(env.fake.lastText['subs'], isEmpty);
      expect(env.fake.lastText['files'], isEmpty);
    });

    test('下载：file-req → file-head + 256KB 分块 + file-end，字节一致', () async {
      final env = Env();
      await env.auth();
      final data = Uint8List(256 * 1024 * 2 + 123);
      for (var i = 0; i < data.length; i++) {
        data[i] = i % 251;
      }
      env.backend.downloadData = data;

      env.fake.serverText(
          {'t': 'file-req', 'id': 'c9', 'kind': 'photo', 'ref': 'i100', 'name': 'a.jpg'});
      await until(() => lastIsType(env.fake, 'file-end'));

      final head =
          jsonDecode(env.fake.sent[0]) as Map<String, dynamic>;
      expect(head['t'], 'file-head');
      expect(head['id'], 'c9');
      expect(head['total'], data.length);

      final bin = BytesBuilder();
      for (var i = 1; i < env.fake.sent.length - 1; i++) {
        bin.add(env.fake.sent[i] as List<int>);
      }
      expect(env.fake.lastText['ok'], true);
      expect(bin.toBytes(), data);
    });

    test('下载失败：file-head(total:0) + file-end(ok:false)', () async {
      final env = Env();
      await env.auth();
      env.backend.failDownload = true;
      env.fake.serverText(
          {'t': 'file-req', 'id': 'c10', 'kind': 'photo', 'ref': 'iX', 'name': 'x.jpg'});
      await until(() => lastIsType(env.fake, 'file-end'));
      final head =
          jsonDecode(env.fake.sent[0]) as Map<String, dynamic>;
      expect(head['t'], 'file-head');
      expect(head['total'], 0);
      expect(env.fake.lastText['ok'], false);
      expect(env.fake.sent, hasLength(2));
    });

    test('文件上传：块先于文件创建到达（缓冲）→ upload-res 同名改名', () async {
      final env = Env();
      await env.auth();
      final data = Uint8List(kChunkSize + 1);
      data.fillRange(0, data.length, 7);

      env.fake.serverText({
        't': 'upload-head',
        'id': 'c11',
        'kind': 'file',
        'dir': 'Download',
        'album': '',
        'name': 'up.bin',
        'size': data.length,
        'mime': '',
      });
      // PC 端不等响应立即 pump 分块，随后 upload-tail
      env.fake.serverBytes(Uint8List.sublistView(data, 0, kChunkSize));
      env.fake.serverBytes(Uint8List.sublistView(data, kChunkSize));
      env.fake.serverText({'t': 'upload-tail', 'id': 'c11'});
      await until(() => lastIsType(env.fake, 'upload-res'));

      final res = env.fake.lastText;
      expect(res['id'], 'c11');
      expect(res['ok'], true);
      expect(res['conflict'], true);
      expect(res['renamed'], 'up.bin (1)');
      expect(env.backend.uploaded.toBytes(), data);
    });

    test('照片上传：photo-upload-res 携带 photo 信息', () async {
      final env = Env();
      await env.auth();
      env.fake.serverText({
        't': 'upload-head',
        'id': 'c12',
        'kind': 'photo',
        'dir': '',
        'album': 'i1',
        'name': 'p.jpg',
        'size': 10,
        'mime': 'image/jpeg',
      });
      env.fake.serverBytes(Uint8List(10));
      env.fake.serverText({'t': 'upload-tail', 'id': 'c12'});
      await until(() => lastIsType(env.fake, 'photo-upload-res'));
      final res = env.fake.lastText;
      expect(res['ok'], true);
      expect(res['photo']['id'], 'i999');
      expect(res['photo']['album'], 'i1');
    });

    test('相册操作：photo-op del/rename → photo-res', () async {
      final env = Env();
      await env.auth();
      env.fake.serverText(
          {'t': 'photo-op', 'id': 'c13', 'op': 'del', 'ids': ['i100', 'i101']});
      await until(() => lastIsType(env.fake, 'photo-res'));
      expect(env.fake.lastText['ok'], true);
      env.fake.sent.clear();

      env.fake.serverText({
        't': 'photo-op',
        'id': 'c14',
        'op': 'rename',
        'ids': ['i100'],
        'name': 'new.jpg'
      });
      await until(() => lastIsType(env.fake, 'photo-res'));
      expect(env.fake.lastText['photo']['name'], 'new.jpg');
      expect(env.backend.photoOps, [
        {'op': 'del', 'ids': ['i100', 'i101'], 'name': null},
        {'op': 'rename', 'ids': ['i100'], 'name': 'new.jpg'},
      ]);
    });

    test('断开：close → closed + onClose(1000)', () async {
      final env = Env();
      await env.auth();
      final codes = <int?>[];
      env.client.onClose.add((c, r) => codes.add(c));
      await env.client.close();
      await until(() => env.client.state == BridgeState.closed);
      expect(codes, [1000]);
    });

    test('PC 吊销：4001 关闭 → onClose(4001)', () async {
      final env = Env();
      await env.auth();
      final codes = <int?>[];
      env.client.onClose.add((c, r) => codes.add(c));
      env.fake.serverClose(4001, 'kicked');
      await until(() => env.client.state == BridgeState.closed);
      expect(codes, [4001]);
    });
  });
}
