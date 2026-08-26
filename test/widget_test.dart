// 啟動畫面測試（MAX30102 K2 交接測試上位機）
//
// 說明：這裡不直接 pump MyApp，因為 MyApp 的 child 是 MainNavigationPage，
// 它一掛載就會去掃 COM 埠（libserialport FFI），在測試環境無法運作。
// 改為以輕量替身當 child，單獨驗證 SplashScreen 的顯示與轉場。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_firmware_tester_unified/shared/widgets/splash_screen.dart';

void main() {
  testWidgets('啟動畫面顯示後應淡出並交給主畫面', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SplashScreen(
          duration: Duration(milliseconds: 100),
          child: Scaffold(body: Text('主畫面替身')),
        ),
      ),
    );

    // 開場畫面應該先出現
    expect(find.text('Aquivio MAX30102 Tester'), findsOneWidget);
    expect(find.text('主畫面替身'), findsNothing);

    // 走完計時器與淡出動畫後，應切換到 child
    await tester.pumpAndSettle();

    expect(find.text('Aquivio MAX30102 Tester'), findsNothing);
    expect(find.text('主畫面替身'), findsOneWidget);
  });
}
