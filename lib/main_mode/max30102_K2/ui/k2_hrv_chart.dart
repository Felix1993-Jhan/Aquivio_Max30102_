// ============================================================================
// 波形圖3 / HRV：心率變異視覺化
// ----------------------------------------------------------------------------
// 左：RR 趨勢圖(Tachogram) — 每拍 RR 間距(ms) 隨時間的折線(看起伏/長短拍)。
// 右：Poincaré 散點圖 — (RRₙ, RRₙ₊₁) 散點 + SD1/SD2 橢圓(HRV 最經典的圖)。
// 資料來自 controller.rrHistory(最近約 300 拍 / 2 分鐘),不受 5/10/20s 視窗限制。
// ============================================================================

import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../../../shared/services/localization_service.dart';
import '../k2_hrv_calculator.dart';

// ⚠️ K2 版:原本的「controller 驅動版(Max30102HrvChart)」已移除 ——
//    K2 沒有 controller,一律由頁面把「已算好的 rr / cont / hv」傳進來。
//    短期(滾動30s)與長期(累積300拍)各用一次,直接對照形狀。

/// 靜態資料版:直接吃「已算好的 RR / 連續性旗標 / HRV 統計」繪 RR趨勢 + Poincaré。
/// 活的量測(controller)與波形快照(存檔資料)共用同一組 painter,不再各自抄。
class Max30102HrvChartView extends StatelessWidget {
  final List<double> rr;
  final List<bool> cont; // cont[i]=true：第 i 筆與第 i-1 筆時間相鄰
  final HrvStats? hv; // SD1/SD2/平均 由此取;null=拍數不足

  /// 在 RR 趨勢圖上加「N 秒前」的垂直參考線(例:[10, 20])。
  /// x 軸是「拍序」不是時間 → 由本檔從最新拍往回累加 RR 換算出對應拍號,
  /// 與上方波形圖的同名秒數線對得起來。
  final List<int> markSeconds;

  const Max30102HrvChartView({
    super.key,
    required this.rr,
    required this.cont,
    this.hv,
    this.markSeconds = const [],
  });

  static const Color _bg = Color(0xFF101418);

  @override
  Widget build(BuildContext context) {
    BoxDecoration deco() =>
        BoxDecoration(color: _bg, borderRadius: BorderRadius.circular(4));
    // painter 內的文字也要跟著語言走。painter 沒有 BuildContext,所以把當下語言
    // 當成建構參數傳進去 —— 它同時是 shouldRepaint 的判斷依據:切語言時資料
    // 可能一個位元都沒變(例如「等待資料…」畫面),不帶它進去就不會重繪。
    final lang = LocalizationService().currentLanguage;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Container(
            decoration: deco(),
            child:
                CustomPaint(painter: _TachogramPainter(rr, markSeconds, lang)),
          ),
        ),
        const SizedBox(width: 8),
        AspectRatio(
          aspectRatio: 1,
          child: Container(
            decoration: deco(),
            child: CustomPaint(
              painter: _PoincarePainter(
                rr,
                cont,
                hv?.meanRr ?? 0,
                hv?.sd1 ?? 0,
                hv?.sd2 ?? 0,
                lang,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 只畫 Poincaré 散點(給分段HRV快照 3 欄各一個用;重用同一個 _PoincarePainter)。
class Max30102PoincareView extends StatelessWidget {
  final List<double> rr;
  final List<bool> cont; // cont[i]=true：第 i 筆與第 i-1 筆時間相鄰
  final HrvStats? hv;
  const Max30102PoincareView({
    super.key,
    required this.rr,
    required this.cont,
    this.hv,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF101418),
        borderRadius: BorderRadius.circular(4),
      ),
      child: CustomPaint(
        painter: _PoincarePainter(
          rr,
          cont,
          hv?.meanRr ?? 0,
          hv?.sd1 ?? 0,
          hv?.sd2 ?? 0,
          LocalizationService().currentLanguage,
        ),
      ),
    );
  }
}

void _text(
  Canvas canvas,
  String s,
  Offset at,
  Color color,
  double size, {
  bool bold = false,
}) {
  final tp = TextPainter(
    text: TextSpan(
      text: s,
      style: TextStyle(
        color: color,
        fontSize: size,
        fontWeight: bold ? FontWeight.bold : FontWeight.normal,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(canvas, at);
}

/// RR 趨勢圖(Tachogram)：每拍 RR(ms) 折線
class _TachogramPainter extends CustomPainter {
  final List<double> rr;
  final List<int> markSeconds; // 要標的「N 秒前」垂直線
  final AppLanguage lang; // 只為了讓 shouldRepaint 認得語言變化
  _TachogramPainter(this.rr, this.markSeconds, this.lang);

  /// 從最新一拍往回累加 RR,找出「[sec] 秒前」落在哪一拍(回傳拍序索引)。
  /// 累加不到該秒數(資料還不夠長)→ 回 -1,不畫線。
  int _idxSecondsAgo(int sec) {
    final limit = sec * 1000.0;
    double acc = 0;
    for (int i = rr.length - 1; i >= 0; i--) {
      acc += rr[i];
      if (acc >= limit) return i;
    }
    return -1;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    _text(
      canvas,
      tr('k2_chart_rr_trend'),
      const Offset(4, 2),
      Colors.grey.shade400,
      9,
      bold: true,
    );
    if (rr.length < 2) {
      _text(
        canvas,
        tr('k2_chart_waiting_beats'),
        Offset(4, h / 2 - 6),
        Colors.grey.shade600,
        10,
      );
      return;
    }
    double lo = rr.reduce(math.min), hi = rr.reduce(math.max);
    final pad = (hi - lo) < 1 ? 20.0 : (hi - lo) * 0.12;
    lo -= pad;
    hi += pad;
    final span = (hi - lo) <= 0 ? 1.0 : (hi - lo);
    const top = 16.0;
    final bottom = h - 4;
    const left = 4.0;
    final right = w - 44; // 右邊留給 y 標籤
    final plotW = right - left;
    double xOf(int i) => left + plotW * i / (rr.length - 1);
    double yOf(double v) => top + (bottom - top) * (1 - (v - lo) / span);

    // 平均線(虛線)
    final mean = rr.reduce((a, b) => a + b) / rr.length;
    final my = yOf(mean);
    final gp = Paint()
      ..color = Colors.white.withValues(alpha: 0.18)
      ..strokeWidth = 1;
    for (double x = left; x < right; x += 8) {
      canvas.drawLine(
        Offset(x, my),
        Offset((x + 4).clamp(left, right), my),
        gp,
      );
    }
    _text(
      canvas,
      trParams('k2_chart_mean', {'v': mean.toStringAsFixed(0)}),
      Offset(right + 2, my - 6),
      Colors.grey.shade500,
      8,
    );
    _text(
      canvas,
      hi.toStringAsFixed(0),
      Offset(right + 2, top - 4),
      Colors.grey.shade600,
      8,
    );
    _text(
      canvas,
      lo.toStringAsFixed(0),
      Offset(right + 2, bottom - 8),
      Colors.grey.shade600,
      8,
    );

    // 「N 秒前」垂直參考線(與上方波形圖同秒數對齊;先畫→不蓋住資料)
    for (final sec in markSeconds) {
      final idx = _idxSecondsAgo(sec);
      if (idx < 0) continue; // 資料還不夠長
      final x = xOf(idx);
      final mp = Paint()
        ..color = Colors.white.withValues(alpha: 0.30)
        ..strokeWidth = 1;
      for (double y = top; y < bottom; y += 7) {
        canvas.drawLine(Offset(x, y), Offset(x, (y + 3.5).clamp(top, bottom)), mp);
      }
      _text(canvas, '-${sec}s', Offset(x + 2, bottom - 10),
          Colors.white.withValues(alpha: 0.45), 8);
    }

    // RR 折線
    final line = Paint()
      ..color = const Color(0xFF40C4FF)
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;
    final path = Path();
    for (int i = 0; i < rr.length; i++) {
      final x = xOf(i), y = yOf(rr[i]);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, line);
    // 點(資料少時才畫,避免太密)
    if (rr.length <= 80) {
      final dot = Paint()..color = const Color(0xFF40C4FF);
      for (int i = 0; i < rr.length; i++) {
        canvas.drawCircle(Offset(xOf(i), yOf(rr[i])), 1.8, dot);
      }
    }
    // 最新值
    _text(
      canvas,
      trParams('k2_chart_now',
          {'v': rr.last.toStringAsFixed(0), 'beats': rr.length}),
      Offset(left + 70, 2),
      const Color(0xFF40C4FF),
      9,
      bold: true,
    );
  }

  @override
  bool shouldRepaint(covariant _TachogramPainter old) =>
      old.rr != rr || old.markSeconds != markSeconds || old.lang != lang;
}

/// Poincaré 散點圖：(RRₙ, RRₙ₊₁) + SD1/SD2 橢圓
class _PoincarePainter extends CustomPainter {
  final List<double> rr;
  final List<bool> cont; // cont[i]=true：第 i 筆與第 i-1 筆時間相鄰(可畫散點/進 SD1)
  final double mean, sd1, sd2; // 由 controller(連續性校正後)給,與 HRV 面板同一組
  final AppLanguage lang; // 只為了讓 shouldRepaint 認得語言變化
  _PoincarePainter(
      this.rr, this.cont, this.mean, this.sd1, this.sd2, this.lang);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    _text(
      canvas,
      'Poincaré',
      const Offset(4, 2),
      Colors.grey.shade400,
      9,
      bold: true,
    );
    _text(
      canvas,
      tr('k2_chart_poincare_axis'),
      const Offset(56, 3),
      Colors.grey.shade600,
      8,
    );
    if (rr.length < 3) {
      _text(canvas, tr('k2_chart_waiting'), Offset(4, h / 2 - 6),
          Colors.grey.shade600, 10);
      return;
    }
    // 範圍(兩軸同尺度，方形;X=上拍 RRₙ₋₁、Y=這拍 RRₙ)
    double lo = rr.reduce(math.min), hi = rr.reduce(math.max);
    final pad = (hi - lo) < 1 ? 20.0 : (hi - lo) * 0.15;
    lo -= pad;
    hi += pad;
    final span = (hi - lo) <= 0 ? 1.0 : (hi - lo);
    // 非對稱邊距：左留 Y 刻度、下留 X 刻度、上留標題；繪圖區仍維持正方形
    const leftM = 30.0, rightM = 6.0, topM = 15.0, botM = 14.0;
    final plot = math.min(w - leftM - rightM, h - topM - botM);
    final left = leftM, top = topM;
    final sc = plot / span; // px per ms
    double px(double x) => left + (x - lo) * sc;
    double py(double y) => top + plot * (1 - (y - lo) / span);

    // 外框 + 對角(identity)線
    final frame = Paint()
      ..color = Colors.white.withValues(alpha: 0.12)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRect(Rect.fromLTWH(left, top, plot, plot), frame);
    canvas.drawLine(
      Offset(px(lo), py(lo)),
      Offset(px(hi), py(hi)),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.18)
        ..strokeWidth = 1,
    );

    // 軸刻度範圍：X(上拍) 在下緣 lo→hi、Y(這拍) 在左緣 lo→hi
    final axc = Colors.grey.shade500;
    final loS = lo.toStringAsFixed(0), hiS = hi.toStringAsFixed(0);
    _text(canvas, loS, Offset(left, top + plot + 2), axc, 8); // X 左
    _text(canvas, hiS, Offset(left + plot - 22, top + plot + 2), axc, 8); // X 右
    _text(canvas, tr('k2_chart_prev_beat'),
        Offset(left + plot / 2 - 12, top + plot + 2), axc, 8);
    _text(canvas, hiS, Offset(2, top - 1), axc, 8); // Y 上
    _text(canvas, loS, Offset(2, top + plot - 9), axc, 8); // Y 下
    _text(canvas, tr('k2_chart_this_beat'), Offset(2, top + plot / 2 - 5), axc,
        8); // Y 名

    // 散點：只畫「時間相鄰」的配對(跨掉拍/跨離群的假配對不畫,與 SD1 一致)
    //   紅點 = 「大跳」(相鄰差 > bigJumpRel×平均)，就是拉高「亂跳」的那些點,
    //   會落在遠離對角線處;正常拍=青點,貼近對角線。
    final dot = Paint()..color = const Color(0xFF80DEEA);
    final bigDot = Paint()..color = const Color(0xFFFF5252);
    for (int i = 1; i < rr.length; i++) {
      if (i >= cont.length || !cont[i]) continue;
      final big =
          mean > 0 &&
          (rr[i] - rr[i - 1]).abs() / mean > Max30102HrvCalculator.bigJumpRel;
      canvas.drawCircle(
        Offset(px(rr[i - 1]), py(rr[i])),
        big ? 2.6 : 2.0,
        big ? bigDot : dot,
      );
    }

    // 橢圓：SD1/SD2 由 controller(連續性校正)給,只有有值才畫。
    // 中心(mean,mean)，沿 identity(右上,螢幕 -45°) 為長軸 SD2、垂直為短軸 SD1。
    // (圓團橘色示警已移除:圓/雪茄形狀看人、看當下狀態,不當品質判準。)
    const shapeColor = Color(0xFFFFD740);
    if (sd1 > 0 && sd2 > 0) {
      final cx = px(mean), cy = py(mean);
      canvas.save();
      canvas.translate(cx, cy);
      canvas.rotate(-math.pi / 4);
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset.zero,
          width: 2 * sd2 * sc,
          height: 2 * sd1 * sc,
        ),
        Paint()
          ..color = shapeColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4,
      );
      canvas.restore();
      canvas.drawCircle(Offset(cx, cy), 2.5, Paint()..color = Colors.white);
    }

    // 標 SD1/SD2（繪圖區左上）+ 大跳圖例
    _text(
      canvas,
      'SD1 ${sd1.toStringAsFixed(1)}ms',
      Offset(left + 3, top + 2),
      shapeColor,
      9,
      bold: true,
    );
    _text(
      canvas,
      'SD2 ${sd2.toStringAsFixed(1)}ms',
      Offset(left + 3, top + 13),
      shapeColor,
      9,
      bold: true,
    );
    _text(
      canvas,
      tr('k2_chart_big_jump'),
      Offset(left + 3, top + 24),
      const Color(0xFFFF5252),
      8,
    );
  }

  @override
  bool shouldRepaint(covariant _PoincarePainter old) =>
      old.rr != rr || old.lang != lang;
}
