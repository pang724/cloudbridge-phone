# 云桥备份 PhoneBridge · P3 手机端（Android APK）

PC 端手机资料备份软件「云桥备份」的手机侧应用（Flutter，仅 Android）。
与 PC 端 P2（`phone-bridge-p2`，Electron 本地服务）通过局域网 WebSocket 配对：

- PC 启动服务生成二维码（`cloudbridge://connect?ip&port&token`）
- 手机扫码（或手输 ip/端口/token）连接 → 用户确认授权（全部相册 + 可选 SAF 目录，目录只读）
- PC 端可：下载照片/文件（256KB 分块）、上传照片/文件（同名自动改名不覆盖）、删除/重命名照片
- 断线自动重连并自动重新授权；PC 端吊销 token（4001）/ 被顶替（4000）时退回连接页

## 结构

```
lib/
  bridge/protocol.dart      # 协议常量 + safeName/uniqueName（对齐 P2 server.js）
  bridge/backend.dart       # PhoneBackend 抽象（数据能力接口）
  bridge/bridge_client.dart # 协议客户端（握手/授权/列表/下载分块/上传缓冲/photo-op）
  backend/android_backend.dart  # Android 实现（MethodChannel "cloudbridge/native"）
  controller.dart           # 状态中枢（深链预填/授权/传输日志/自动重连）
  screens/                  # 连接页 / 授权页 / 已连接页
android/.../MainActivity.kt # 原生层（MediaStore 相册 + SAF 目录 + 权限 + deep link）
```

## 构建

```bash
flutter pub get
flutter test
flutter build apk --release --split-per-abi
```

CI：`.github/workflows/build-apk.yml`（JDK 17 + Flutter 3.47.2，release 签名用 `android/key.properties` + `android/app/release.keystore`）。

部署：`python tools/pb_deploy.py create|sync|poll`（GitHub Trees API 同步 + CI 构建 + 下载 APK 到 `apk/`）。
