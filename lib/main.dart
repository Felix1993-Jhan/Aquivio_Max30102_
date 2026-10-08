// ============================================================================
// MAX30102 Handover Tester — MAX30102 K2 交接測試上位機
// ============================================================================
// 應用程式流程：
//   SplashScreen (3 秒) → MainNavigationPage （首頁為 MAX30102 K2 交接頁）
// ============================================================================

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'package:flutter_firmware_tester_unified/shared/widgets/splash_screen.dart';
import 'package:flutter_firmware_tester_unified/main_mode/main_navigation_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化視窗管理器並設定最小尺寸
  await windowManager.ensureInitialized();

  const windowOptions = WindowOptions(
    minimumSize: Size(900, 650),
    size: Size(1280, 860),
    center: true,
    title: 'MAX30102 Handover Tester',
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });
 
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MAX30102 Handover Tester',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const SplashScreen(
        duration: Duration(milliseconds: 3000),
        child: MainNavigationPage(),
      ),
      debugShowCheckedModeBanner: false,
    );
  }
}
 