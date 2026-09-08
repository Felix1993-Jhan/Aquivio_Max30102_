// ============================================================================
// 憋氣血氧曲線圖
// ============================================================================
// 移植自 Flutter_AutoCleaningTester 的 max30102_breathhold_chart,兩處改動:
//
// ① **Y 軸下緣會自動往下延伸。** 原版固定 94~105%,那是為了「看得清楚小變化」,
//    但我們這次的目的正好相反 —— 要把血氧壓低才分得出兩片板子的差,
//    釘死在 94 會把最有價值的那一段裁掉。所以下緣跟著資料走(地板 70%),
//    沒事的時候仍然維持 94 的解析度。
//
// ② **可以疊上一次的錄製。** 實驗要比的是「同一個人、不同板子」,
//    一次只畫一條線的話還要自己記上次的數字。
//
// ⚠️ painter 沒有 BuildContext,所以語言當建構參數傳進來,**並納入
//    shouldRepaint** —— 切語言時資料可能一個位元都沒變(例如停在空狀態),
//    不比對 lang 就不會重繪,文字會卡在舊語言。與其他兩張圖表的做法一致。
// ============================================================================

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../shared/services/localization_service.dart';
import 'k2_breathhold.dart';

class K2BreathHoldChart extends StatelessWidget {
  final K2BreathHold rec;
  final AppLanguage lang;
  const K2BreathHoldChart({super.key, required this.rec, required this.lang});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: rec,
        builder: (context, _) => CustomPaint(
          painter: _Painter(
            points: rec.points,
            resumeT: rec.resumeT,
            active: rec.active,
            label: rec.orientLabel,
            previous: rec.previous,
            // 經過時間跟著真實時間走(不是跟著點數)—— 沒訊號的那幾秒
            // 時間軸照樣要前進,不然畫面看起來像凍住。
            elapsed: rec.elapsedSec,
            // ⚠️ 一定要傳版本號。`points` 是**同一個 list 物件**,
            //    painter 拿 length 比對永遠相等 → 畫面凍住(踩過一次)。
            version: rec.version,
            lang: lang,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _Painter extends CustomPainter {
  final List<BreathHoldPoint> points;
  final double? resumeT;
  final bool active;
  final String label;
  final BreathHoldRun? previous;

  /// 錄製至今的經過秒數(跟著真實時間,不是跟著點數)。
  final double elapsed;

  /// 記錄器的版本號 —— **這才是判斷「有沒有變化」的依據**。
  /// [points] 是同一個 list 物件,拿它的 length 比對永遠相等。
  final int version;

  /// **只為了讓 shouldRepaint 認得語言變化** —— 實際翻譯走全域 `tr()`
  /// (與 k2_hrv_chart / k2_wave_chart 的做法一致)。
  final AppLanguage lang;

  _Painter({
    required this.points,
    required this.resumeT,
    required this.active,
    required this.label,
    required this.previous,
    required this.elapsed,
    required this.version,
    required this.lang,
  });

  static const Color _bg = Color(0xFF101418);
  static const Color _raw = Color(0x8880DEEA); // 淺青:未平滑
  static const Color _smooth = Color(0xFF42A5F5); // 藍:平滑
  static const Color _prev = Color(0x99FFAB91); // 橘紅:上一次(對照)
  static const Color _mark = Color(0xFFFFB74D); // 橘:最低點
  static const Color _resume = Color(0xFFCE93D8); // 紫:恢復呼吸標記

  String _tr(String k) => tr(k);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    canvas.drawRect(Offset.zero & size, Paint()..color = _bg);

    const padL = 34.0, padR = 8.0, padT = 14.0, padB = 18.0;
    final plotW = w - padL - padR;
    final plotH = h - padT - padB;
    if (plotW <= 0 || plotH <= 0) return;

    // ── Y 範圍:上緣固定 101,下緣跟著資料走(地板 70)────────────────
    const yMax = 101.0;
    double lo = 94.0;
    for (final s in points) {
      lo = math.min(lo, s.smooth);
      lo = math.min(lo, s.raw);
    }
    for (final s in previous?.points ?? const <BreathHoldPoint>[]) {
      lo = math.min(lo, s.smooth);
    }
    final yMin = (lo.floorToDouble() - 1).clamp(70.0, 94.0);

    double yOf(double v) =>
        padT + plotH * (1 - (v.clamp(yMin, yMax) - yMin) / (yMax - yMin));

    final gridP = Paint()
      ..color = Colors.white.withValues(alpha: 0.08)
      ..strokeWidth = 1;

    // Y 格線:範圍越寬,間隔越大,避免擠在一起
    final yStep = (yMax - yMin) > 16 ? 5 : 2;
    for (int v = yMin.ceil(); v <= yMax; v += yStep) {
      final y = yOf(v.toDouble());
      canvas.drawLine(Offset(padL, y), Offset(w - padR, y), gridP);
      _text(canvas, '$v', Offset(2, y - 6), Colors.grey.shade500, 9);
    }
    canvas.drawLine(
        Offset(padL, yOf(100)),
        Offset(w - padR, yOf(100)),
        Paint()
          ..color = Colors.white.withValues(alpha: 0.22)
          ..strokeWidth = 1);

    if (points.isEmpty && previous == null) {
      _text(
          canvas,
          active
              ? '${_tr('k2_bh_waiting')}  ${elapsed.toInt()}s'
              : _tr('k2_bh_press_start'),
          Offset(padL + 8, padT + plotH / 2 - 7),
          Colors.grey.shade500,
          12);
      return;
    }

    // ── X 範圍:兩次錄製取較長的那個(至少 30s)────────────────────────
    double tMax = 30.0;
    tMax = math.max(tMax, elapsed); // 沒訊號時仍要前進
    if (points.isNotEmpty) tMax = math.max(tMax, points.last.t);
    if (previous != null && previous!.points.isNotEmpty) {
      tMax = math.max(tMax, previous!.points.last.t);
    }
    double xOf(double t) => padL + plotW * (t / tMax);

    final step = tMax <= 60 ? 10.0 : (tMax <= 180 ? 30.0 : 60.0);
    for (double t = 0; t <= tMax + 0.1; t += step) {
      final x = xOf(t);
      canvas.drawLine(Offset(x, padT), Offset(x, padT + plotH), gridP);
      _text(canvas, '${t.toInt()}s', Offset(x + 1, padT + plotH + 3),
          Colors.grey.shade600, 9);
    }

    void drawLine(List<BreathHoldPoint> src, double Function(BreathHoldPoint) sel,
        Color color, double width) {
      if (src.isEmpty) return;
      final p = Paint()
        ..color = color
        ..strokeWidth = width
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round;
      final path = Path();
      for (int i = 0; i < src.length; i++) {
        final x = xOf(src[i].t), y = yOf(sel(src[i]));
        i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
      canvas.drawPath(path, p);
    }

    // 上一次(對照)畫在最底層,只畫平滑線,不搶焦點
    drawLine(previous?.points ?? const [], (s) => s.smooth, _prev, 1.6);

    // 「恢復呼吸」標記:垂直虛線。繼續記錄,只是標出時刻。
    final rt = resumeT;
    if (rt != null && rt >= 0 && rt <= tMax) {
      final rx = xOf(rt);
      final mp = Paint()
        ..color = _resume
        ..strokeWidth = 1.4;
      for (double y = padT; y < padT + plotH; y += 8) {
        canvas.drawLine(
            Offset(rx, y), Offset(rx, (y + 4).clamp(padT, padT + plotH)), mp);
      }
      _text(canvas, '${_tr('k2_bh_resume')} ${rt.toInt()}s',
          Offset(rx + 2, padT + 1), _resume, 9);
    }

    drawLine(points, (s) => s.raw, _raw, 1.0);
    drawLine(points, (s) => s.smooth, _smooth, 2.0);

    if (points.isEmpty) return;

    // ── 最低點(以平滑為準)────────────────────────────────────────────
    int minI = 0;
    for (int i = 1; i < points.length; i++) {
      if (points[i].smooth < points[minI].smooth) minI = i;
    }
    final mn = points[minI];
    final mp = Offset(xOf(mn.t), yOf(mn.smooth));
    canvas.drawCircle(mp, 3.5, Paint()..color = _mark);
    _text(
        canvas,
        '${_tr('k2_bh_min')} ${mn.smooth.toStringAsFixed(1)}% @${mn.t.toInt()}s',
        Offset((mp.dx - 50).clamp(padL, w - padR - 110), mp.dy + 6),
        _mark,
        9);

    // ── 降幅 + 恢復時間 ──────────────────────────────────────────────
    // 基線取前 5 點的平均;恢復目標 = min(99, 基線 − 0.3)。
    final baseN = math.min(5, points.length);
    var baseSum = 0.0;
    for (int i = 0; i < baseN; i++) {
      baseSum += points[i].smooth;
    }
    final baseline = baseSum / baseN;
    final drop = baseline - mn.smooth;
    final recTarget = math.min(99.0, baseline - 0.3);
    var recIdx = -1;
    for (int i = minI; i < points.length; i++) {
      if (points[i].smooth >= recTarget) {
        recIdx = i;
        break;
      }
    }
    final String recStr;
    if (mn.smooth >= recTarget) {
      recStr = '—'; // 沒有明顯下降
    } else if (recIdx >= 0) {
      recStr = '${(points[recIdx].t - mn.t).toStringAsFixed(0)}s';
      canvas.drawCircle(Offset(xOf(points[recIdx].t), yOf(points[recIdx].smooth)),
          3.0, Paint()..color = const Color(0xFF66BB6A));
    } else {
      recStr = _tr('k2_bh_recovering');
    }
    _textRight(
        canvas,
        '${_tr('k2_bh_drop')} -${drop.toStringAsFixed(1)}%   '
            '${_tr('k2_bh_recover')} $recStr',
        w - padR - 2,
        padT - 12,
        Colors.white.withValues(alpha: 0.85),
        10);

    // ── 左上:即時值 + 這次是哪片板子 ────────────────────────────────
    final cur = points.last;
    final tag = label.isEmpty ? '' : '  [$label]';
    _text(
        canvas,
        '${cur.raw.toStringAsFixed(1)}% / ${cur.smooth.toStringAsFixed(1)}%'
            '  (${cur.t.toInt()}s${active ? " ●" : ""})$tag',
        Offset(padL + 4, padT - 12),
        Colors.white.withValues(alpha: 0.85),
        10);

    // 對照組的圖例(有才畫)
    final prev = previous;
    if (prev != null && prev.points.isNotEmpty) {
      _text(
          canvas,
          '${_tr('k2_bh_previous')}${prev.orientLabel.isEmpty ? "" : " [${prev.orientLabel}]"}',
          Offset(padL + 4, padT + plotH - 12),
          _prev,
          9);
    }
  }

  void _text(Canvas c, String s, Offset at, Color color, double size) {
    (TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: color, fontSize: size)),
      textDirection: TextDirection.ltr,
    )..layout())
        .paint(c, at);
  }

  void _textRight(
      Canvas c, String s, double rightX, double topY, Color color, double size) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: color, fontSize: size)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, Offset(rightX - tp.width, topY));
  }

  @override
  bool shouldRepaint(covariant _Painter old) =>
      old.version != version || // ← 主要判準;不可以改用 points.length
      old.elapsed != elapsed ||
      old.active != active ||
      old.previous != previous ||
      old.lang != lang; // ← 切語言時資料可能沒變,不比這個文字會卡住
}
