import 'package:flutter/material.dart';

import '../controller.dart';
import '../theme.dart';

/// 已连接页：暴露范围 + 传输日志 + 断开。
class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key, required this.ctrl});

  final BridgeController ctrl;

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  @override
  Widget build(BuildContext context) {
    final c = widget.ctrl;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // 头部：已连接状态
            Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppTheme.border),
              ),
              child: Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: const BoxDecoration(
                        color: AppTheme.success, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            c.pcName.isEmpty ? '已连接' : '已连接 · ${c.pcName}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.text)),
                        const SizedBox(height: 2),
                        Text(
                            '${c.pcIp} · 本机：${c.deviceName}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                const TextStyle(fontSize: 12, color: AppTheme.text3)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 暴露范围
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppTheme.surface,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: AppTheme.border),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('已暴露范围',
                              style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.text)),
                          const SizedBox(height: 10),
                          _ScopeRow(
                              icon: Icons.photo_library_outlined,
                              label: '相册',
                              value: c.albums ? '全部（可读写）' : '未授权'),
                          const SizedBox(height: 8),
                          _ScopeRow(
                              icon: Icons.folder_outlined,
                              label: '目录',
                              value: c.trees.isEmpty
                                  ? '未授权'
                                  : '${c.trees.length} 个 · 只读',
                              chips:
                                  c.trees.isEmpty ? null : c.trees.map((t) => t['name'] ?? '')),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    // 传输日志
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppTheme.surface,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: AppTheme.border),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('传输日志',
                              style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.text)),
                          const SizedBox(height: 10),
                          if (c.logs.isEmpty)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 10),
                              child: Text('暂无传输记录。在 PC 端下载 / 上传文件后，进度会显示在这里。',
                                  style:
                                      TextStyle(fontSize: 13, color: AppTheme.text3)),
                            )
                          else
                            ...c.logs.reversed.map((l) {
                              final color = switch (l.kind) {
                                'ok' => AppTheme.success,
                                'warn' => AppTheme.warn,
                                'error' => AppTheme.danger,
                                _ => AppTheme.text2,
                              };
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(l.time,
                                        style: const TextStyle(
                                            fontSize: 11.5, color: AppTheme.text3)),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(l.text,
                                          style: TextStyle(
                                              fontSize: 13, color: color)),
                                    ),
                                  ],
                                ),
                              );
                            }),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(
                  color: AppTheme.surface,
                  border: Border(top: BorderSide(color: AppTheme.border))),
              child: OutlinedButton(
                onPressed: () => c.disconnect(),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  foregroundColor: AppTheme.danger,
                  side: BorderSide(color: AppTheme.border),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('断开连接'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScopeRow extends StatelessWidget {
  const _ScopeRow({
    required this.icon,
    required this.label,
    required this.value,
    this.chips,
  });

  final IconData icon;
  final String label;
  final String value;
  final Iterable<String>? chips;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20, color: AppTheme.text3),
        const SizedBox(width: 8),
        Text(label,
            style: const TextStyle(fontSize: 13.5, color: AppTheme.text2)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.text)),
        ),
        if (chips != null) ...[
          const SizedBox(width: 8),
          ...chips!
              .take(3)
              .map((n) => Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: AppTheme.bg,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: AppTheme.border),
                      ),
                      child: Text(n.length > 8 ? '${n.substring(0, 8)}…' : n,
                          style: const TextStyle(
                              fontSize: 11, color: AppTheme.text2)),
                    ),
                  )),
        ],
      ],
    );
  }
}
