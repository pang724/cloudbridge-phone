import 'package:flutter/material.dart';

import '../controller.dart';
import '../theme.dart';

/// 连接页：扫码（cloudbridge:// 深链自动预填）或手动填写 ip/port/token。
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key, required this.ctrl});

  final BridgeController ctrl;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  late final TextEditingController _ip =
      TextEditingController(text: widget.ctrl.ip);
  late final TextEditingController _port =
      TextEditingController(text: widget.ctrl.port);
  late final TextEditingController _token =
      TextEditingController(text: widget.ctrl.token);
  int _synced = -1;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 深链预填后同步输入框
    if (_synced != widget.ctrl.connVersion) {
      _synced = widget.ctrl.connVersion;
      if (widget.ctrl.ip.isNotEmpty) _ip.text = widget.ctrl.ip;
      if (widget.ctrl.port.isNotEmpty) _port.text = widget.ctrl.port;
      if (widget.ctrl.token.isNotEmpty) _token.text = widget.ctrl.token;
    }
  }

  @override
  void dispose() {
    _ip.dispose();
    _port.dispose();
    _token.dispose();
    super.dispose();
  }

  void _connect() {
    final c = widget.ctrl;
    c.ip = _ip.text.trim();
    c.port = _port.text.trim().isEmpty ? c.port : _port.text.trim();
    c.token = _token.text.trim();
    if (c.ip.isEmpty || c.token.isEmpty) {
      c.error = '请填写 IP 地址与连接令牌';
      return;
    }
    c.connect();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.ctrl;
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 40),
              const _Brand(),
              const SizedBox(height: 32),
              CardBox(
                title: '连接 PC 端服务',
                child: Column(
                  children: [
                    _Field(
                        label: 'IP 地址',
                        controller: _ip,
                        hint: '192.168.x.x',
                        keyboard: TextInputType.number),
                    const SizedBox(height: 12),
                    _Field(
                        label: '端口',
                        controller: _port,
                        hint: '18888',
                        keyboard: TextInputType.number),
                    const SizedBox(height: 12),
                    _Field(label: '连接令牌', controller: _token, hint: 'PC 端显示的 token'),
                  ],
                ),
              ),
              const Text(
                '在 PC 端「云桥备份」中启动服务后，用本应用扫描二维码（自动填充），或手动填写以上信息。',
                style: TextStyle(color: AppTheme.text3, fontSize: 12.5, height: 1.55),
              ),
              const SizedBox(height: 22),
              FilledButton(
                onPressed: c.connecting ? null : _connect,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                  backgroundColor: AppTheme.primary,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: c.connecting
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('连接', style: TextStyle(fontSize: 16)),
              ),
              if (c.error != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.danger.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppTheme.danger.withValues(alpha: 0.35)),
                  ),
                  child: Text(c.error!,
                      style: const TextStyle(color: AppTheme.danger, fontSize: 13)),
                ),
              ],
              const SizedBox(height: 30),
              const Center(
                child: Text(
                  '云桥备份 PhoneBridge · v1.0.0 · P3 真机版',
                  style: TextStyle(color: AppTheme.text3, fontSize: 11.5),
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: AppTheme.primary,
            borderRadius: BorderRadius.circular(18),
          ),
          child: const Icon(Icons.cloud, color: Colors.white, size: 34),
        ),
        const SizedBox(height: 12),
        const Text('云桥备份',
            style: TextStyle(
                fontSize: 22, fontWeight: FontWeight.w800, color: AppTheme.text)),
        const SizedBox(height: 4),
        const Text('PC 手机资料备份 · 连接手机',
            style: TextStyle(fontSize: 13, color: AppTheme.text3)),
      ],
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.controller,
    required this.hint,
    this.keyboard,
  });

  final String label;
  final TextEditingController controller;
  final String hint;
  final TextInputType? keyboard;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 13, color: AppTheme.text2)),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          keyboardType: keyboard,
          style: const TextStyle(fontSize: 15, color: AppTheme.text),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: AppTheme.text3, fontSize: 14),
            filled: true,
            fillColor: AppTheme.bg,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ],
    );
  }
}
