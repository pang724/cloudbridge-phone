import 'package:flutter/material.dart';

/// 品牌色（与 P1 原型 styles.css 一致）。
class AppTheme {
  static const Color primary = Color(0xFF2563EB);
  static const Color success = Color(0xFF12B76A);
  static const Color warn = Color(0xFFF79009);
  static const Color danger = Color(0xFFF04438);
  static const Color bg = Color(0xFFF5F7FA);
  static const Color surface = Colors.white;
  static const Color text = Color(0xFF101828);
  static const Color text2 = Color(0xFF475467);
  static const Color text3 = Color(0xFF98A2B3);
  static const Color border = Color(0xFFE4E7EC);

  static ThemeData get theme => ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: bg,
        colorScheme: ColorScheme.fromSeed(
            seedColor: primary, brightness: Brightness.light),
        splashFactory: NoSplash.splashFactory,
      );
}

/// 白色圆角卡片容器。
class CardBox extends StatelessWidget {
  const CardBox({super.key, required this.title, required this.child, this.note});

  final String title;
  final Widget child;
  final String? note;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.text)),
          if (note != null) ...[
            const SizedBox(height: 4),
            Text(note!,
                style: const TextStyle(fontSize: 12, color: AppTheme.text3)),
          ],
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}
