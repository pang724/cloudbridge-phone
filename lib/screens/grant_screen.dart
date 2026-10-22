import 'package:flutter/material.dart';

import '../controller.dart';
import '../theme.dart';

/// 授权页：PC 端连接请求已到达，用户确认暴露范围（相册 / 文件目录）。
class GrantScreen extends StatefulWidget {
  const GrantScreen({super.key, required this.ctrl});

  final BridgeController ctrl;

  @override
  State<GrantScreen> createState() => _GrantScreenState();
}

class _GrantScreenState extends State<GrantScreen> {
  @override
  Widget build(BuildContext context) {
    final c = widget.ctrl;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: AppTheme.primary.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.laptop_mac_outlined,
                              color: AppTheme.primary, size: 24),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                  c.pcName.isEmpty ? 'PC 设备' : c.pcName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.w700,
                                      color: AppTheme.text)),
                              const SizedBox(height: 2),
                              Text('「云桥备份」请求连接${c.pcIp.isEmpty ? '' : '（${c.pcIp}）'}',
                                  style: const TextStyle(
                                      fontSize: 12.5, color: AppTheme.text3)),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    CardBox(
                      title: '相册',
                      note: '允许后 PC 端可下载照片/视频，并支持回传、删除、重命名',
                      child: SwitchListTile(
                        value: c.albums,
                        onChanged: c.setAlbums,
                        title: const Text('全部相册',
                            style:
                                TextStyle(fontSize: 14, color: AppTheme.text)),
                        secondary: const Icon(Icons.photo_library_outlined,
                            color: AppTheme.primary, size: 22),
                        activeThumbColor: AppTheme.primary,
                      ),
                    ),
                    CardBox(
                      title: '文件目录（可选）',
                      note: '目录为只读暴露：PC 端可下载文件、上传新文件；同名文件自动改名，不覆盖',
                      child: Column(
                        children: [
                          if (c.trees.isEmpty)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 6),
                              child: Text('未添加目录（可以只授权相册）',
                                  style:
                                      TextStyle(fontSize: 13, color: AppTheme.text3)),
                            )
                          else
                            ...c.trees.asMap().entries.map((e) {
                              final t = e.value;
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Row(
                                  children: [
                                    const Icon(Icons.folder_outlined,
                                        color: AppTheme.warn, size: 22),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(t['name'] ?? '',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              fontSize: 14,
                                              color: AppTheme.text)),
                                    ),
                                    Text('只读',
                                        style: TextStyle(
                                            fontSize: 11,
                                            color: AppTheme.text3,
                                            fontWeight: FontWeight.w600)),
                                    const SizedBox(width: 8),
                                    IconButton(
                                        visualDensity: VisualDensity.compact,
                                        icon: const Icon(Icons.close,
                                            size: 18, color: AppTheme.text3),
                                        onPressed: () => c.removeTree(e.key)),
                                  ],
                                ),
                              );
                            }),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              onPressed: c.pickSafDir,
                              icon: const Icon(Icons.add, size: 18),
                              label: const Text('添加目录'),
                              style: TextButton.styleFrom(
                                  foregroundColor: AppTheme.primary),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (c.error != null)
                      Container(
                        margin: const EdgeInsets.only(top: 4),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppTheme.danger.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color: AppTheme.danger.withValues(alpha: 0.35)),
                        ),
                        child: Text(c.error!,
                            style: const TextStyle(
                                color: AppTheme.danger, fontSize: 13)),
                      ),
                  ],
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(
                  color: AppTheme.surface,
                  border: Border(top: BorderSide(color: AppTheme.border))),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => c.denyGrant(),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        foregroundColor: AppTheme.danger,
                        side: BorderSide(color: AppTheme.border),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('拒绝'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      onPressed: c.hasScope ? () => c.confirmGrant() : null,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        backgroundColor: AppTheme.primary,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('允许连接',
                          style: TextStyle(fontSize: 15)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
