import 'dart:typed_data';

/// 一条可下载的字节流：总大小 + 256KB 分块流 + 取消（释放句柄）。
class DownloadStream {
  DownloadStream({required this.total, required this.chunks, required this.cancel});

  final int total;
  final Stream<Uint8List> chunks;
  final Future<void> Function() cancel;
}

/// 上传目标：目标文件/照片已创建完毕，调用方持续 add() 写入，finish() 收尾。
abstract class UploadTarget {
  /// 最终保存的文件名（同名冲突时可能与请求名不同）。
  String get finalName;

  /// 是否触发了同名改名。
  bool get conflict;

  Future<void> add(Uint8List bytes);

  /// 关闭写入并返回结果：photo 类含 photo 信息；file 类含 conflict/renamed。
  Future<Map<String, dynamic>> finish();
}

/// 手机侧数据能力（Android 原生层实现；协议单测中用 fake 注入）。
abstract class PhoneBackend {
  /// 设备显示名（hello 帧）。
  Future<String> deviceName();

  /// 全部相册 [{id, name, count, size}]（头部含 'all' 虚拟相册）。
  Future<List<Map<String, dynamic>>> listAlbums();

  /// 全部照片 [{id, name, type, size, sizeBytes, time, album, icon, grad, duration?}]
  /// （PC 前端自行按相册过滤，一次返回全部）。
  Future<List<Map<String, dynamic>>> listPhotos();

  /// 已授权根目录（SAF 树）[{id, name, files, size}]。
  Future<List<Map<String, dynamic>>> listRoot();

  /// 目录内容 {subs: [{id,name,files,size}], files: [{id,dir,name,size,sizeBytes,time}]}。
  Future<Map<String, dynamic>> listDir(String dirId);

  /// 应用用户授权（相册开关 + 已选目录树）。
  Future<void> applyGrant({
    required bool albums,
    required List<Map<String, String>> trees,
  });

  /// 打开 SAF 目录选择器，返回 {ok, uri?, name?}（用户取消时 ok=false）。
  Future<Map<String, dynamic>> pickSafDir();

  /// 请求媒体权限（授权相册前调用）。
  Future<bool> requestMediaPermission();

  /// 启动时携带的 deep link（cloudbridge://connect?ip&port&token）。
  Future<String?> initialDeepLink();

  /// deep link 实时回调（应用在前台时收到新的 cloudbridge:// 链接）。
  final List<void Function(String uri)> onDeepLink = [];

  /// 打开下载流。kind: 'photo' | 'file'；ref: 照片 id 或文件 id。
  Future<DownloadStream> openDownload({
    required String kind,
    required String ref,
    required String name,
  });

  /// 创建上传目标。kind: 'photo'（album=相册 id）| 'file'（dir=目录 id）。
  Future<UploadTarget> beginUpload({
    required String kind,
    String? dir,
    String? album,
    required String name,
    required int size,
    String? mime,
  });

  /// 相册操作：op 'del'（批量删除）| 'rename'（ids 取第一个 + name）。
  Future<Map<String, dynamic>> photoOp({
    required String op,
    required List<String> ids,
    String? name,
  });
}
