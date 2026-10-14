// ============================================================================
// 玻璃質感（Glassmorphism）—— 全 App 共用的開關與元件
// ============================================================================
// 開關在設定頁，執行期可切換（和語言切換同一個模式）。
//
// ── 為什麼要有共用元件，而不是每頁各寫一次 ────────────────────────────
//
// 玻璃感是三個東西疊出來的，**少一個就不像**：
//   ① [ClipRRect]      限制模糊範圍 —— 沒有它模糊會溢出到整個畫面
//   ② [BackdropFilter] 模糊「它後面已經畫好的東西」
//   ③ 半透明容器        上色 + 邊框，否則只有模糊、沒有一片玻璃的實體感
//
// 寫一次在這裡，每頁只要用 [GlassCard]，就不會有人漏掉其中一個。
//
// ── ⚠️ 玻璃必須有東西可以模糊 ──────────────────────────────────────
//
// 白色半透明卡片疊在白色背景上，**和原本完全一樣** —— 模糊一片純白還是純白。
// 所以 [GlassBackground] 要鋪在最底層給它東西模糊，不然整件事是白做的。
//
// ── ⚠️ 成本 ────────────────────────────────────────────────────────
//
// 每個 [BackdropFilter] 會強制一個 save layer 而且**每一幀重算**。
// K2 頁的波形圖本來就 10Hz 在重畫，底下再疊好幾層模糊，掉幀是真的風險。
// 所以原則是：**同一個畫面上限制在 2~3 個模糊層**（外層包一個大的，
// 不是見框就包），密集資料區直接用 `solid: true` 退出。
// ============================================================================

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// 全域玻璃質感開關（唯一實例）。設定頁切換，所有頁面跟著變。
///
/// 關掉時每個 [GlassCard] / [GlassBackground] 都會退回原本的 Material 樣子，
/// 所以可以隨時一鍵比較，也可以在發現掉幀時直接關掉。
final ValueNotifier<bool> globalGlassNotifier = ValueNotifier<bool>(true);

/// 玻璃用色。
///
/// 一律用 [Color.fromRGBO] 而不是 `withOpacity` / `withValues` ——
/// 那兩個 API 在不同 Flutter 版本之間一個被棄用、一個還不存在，
/// `fromRGBO` 從以前到現在都一樣。
class GlassColors {
  static const shell = Color.fromRGBO(255, 255, 255, 0.72);
  static const shellEdge = Color.fromRGBO(255, 255, 255, 0.65);

  /// 帶色玻璃：警示（橘）。
  static const warnFill = Color.fromRGBO(255, 167, 38, 0.20);
  static const warnEdge = Color.fromRGBO(239, 108, 0, 0.50);

  /// 帶色玻璃：強調（青，與 App 主色一致）。
  static const tealFill = Color.fromRGBO(0, 150, 136, 0.13);
  static const tealEdge = Color.fromRGBO(0, 150, 136, 0.38);
}

/// 鋪在最底層的淡漸層，給玻璃「東西可以模糊」。
///
/// 刻意調得很淡：它的工作是讓玻璃浮起來，不是搶眼。關掉玻璃時就退回
/// 單色底，和原本一模一樣。
class GlassBackground extends StatelessWidget {
  const GlassBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: globalGlassNotifier,
      builder: (context, glass, _) {
        if (!glass) return child;
        return DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFFE6F2F1), // 左上偏青
                Color(0xFFF7F8FA), // 中段近白
                Color(0xFFEDEFF4), // 右下偏灰
              ],
              stops: [0.0, 0.55, 1.0],
            ),
          ),
          child: child,
        );
      },
    );
  }
}

/// 一片玻璃卡片。玻璃關掉時自動退回 [plainColor] / [plainBorder] 的樣子。
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(12),
    this.radius = 14,
    this.blur = 18,
    this.fill,
    this.edge,
    this.plainColor,
    this.plainBorder,
    this.solid = false,
    this.width,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final double blur;

  /// 玻璃的底色與邊框。不給就用 [GlassColors.shell] / [GlassColors.shellEdge]。
  final Color? fill;
  final Color? edge;

  /// 玻璃關掉時用的底色與邊框。不給就是透明 + 淡灰邊。
  final Color? plainColor;
  final Color? plainBorder;

  /// **這一塊是資料區，永遠不要玻璃。**
  ///
  /// 玻璃感的本質是降低對比，而密集的數值（HRV 表、等寬的封包內容、日誌）
  /// 正好是最需要對比的東西。這個旗標讓它們不受全域開關影響。
  final bool solid;

  final double? width;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: globalGlassNotifier,
      builder: (context, glass, _) {
        final on = glass && !solid;
        final box = Container(
          width: width,
          padding: padding,
          decoration: BoxDecoration(
            color: on ? (fill ?? GlassColors.shell) : plainColor,
            border: Border.all(
              color: on
                  ? (edge ?? GlassColors.shellEdge)
                  : (plainBorder ?? Colors.grey.shade300),
              width: on ? 1.2 : 1,
            ),
            borderRadius: BorderRadius.circular(radius),
          ),
          child: child,
        );
        if (!on) return box;
        return ClipRRect(
          // ⚠️ 一定要裁切，否則模糊會溢出到整個畫面。
          borderRadius: BorderRadius.circular(radius),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
            child: box,
          ),
        );
      },
    );
  }
}
