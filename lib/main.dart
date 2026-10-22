import 'package:flutter/material.dart';

import 'controller.dart';
import 'screens/connect_screen.dart';
import 'screens/grant_screen.dart';
import 'screens/session_screen.dart';
import 'theme.dart';

void main() => runApp(const PhoneBridgeApp());

class PhoneBridgeApp extends StatefulWidget {
  const PhoneBridgeApp({super.key});

  @override
  State<PhoneBridgeApp> createState() => _PhoneBridgeAppState();
}

class _PhoneBridgeAppState extends State<PhoneBridgeApp> {
  late final BridgeController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = BridgeController();
    _ctrl.addListener(_onChange);
  }

  void _onChange() => setState(() {});

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '云桥备份',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.theme,
      home: switch (_ctrl.screen) {
        'grant' => GrantScreen(ctrl: _ctrl),
        'session' => SessionScreen(ctrl: _ctrl),
        _ => ConnectScreen(ctrl: _ctrl),
      },
    );
  }
}
