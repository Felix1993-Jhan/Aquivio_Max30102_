// ============================================================================
// 波形圖2：baseline 置中疊圖
// ----------------------------------------------------------------------------
// - 以 baseline(中心化移動平均) 為中線,固定畫在主圖垂直正中。
// - 訊號 = raw − baseline(去趨勢/置中),IR(紅外/HR) 與 RED(紅光/SpO2) 疊在同框。
// - IR / RED 共用同一垂直縮放(可比較絕對振幅)。
// - 在「置中後訊號」上用 HR-B 的 prominence 法重抓峰(回血)與谷(供血) → 標點。
// - 橘色包絡:視窗內最高峰/最低谷(值=相對 baseline)+ p2p + 「建議固定 ±」。
//   振幅 ≈ DC × PI(接觸/灌注)每天會變 → 固定範圍不能寫死,看這些數字設。
// - 下方依開啟通道各放一條半波 AC 帶。
// 純顯示用,不影響現有 HR/SpO2 計算路徑。
// ============================================================================

import 'package:flutter/foundation.dart'; // listEquals(點選的谷有沒有變)
import 'package:flutter/gestures.dart'; // 滾輪縮放(PointerScrollEvent / 搶在頁面捲動之前)
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // Ctrl + 滾輪 = 振幅縮放

import '../../../shared/services/localization_service.dart';
import '../k2_config.dart';
import '../k2_signal.dart';
// 0.0.0.7 對照:畫它找谷用的移動平均線(見 max30102_K2_v007/README)
import '../../max30102_K2_v007/k2_signal.dart' as v7;

// ⚠️ K2 版:原本綁 Max30102Controller(ring buffer + troughFates)。
//    K2 核心「只算不存、也不吐谷位置」(顯示是 UI 的事),故改成:
//      · 波形 → 吃 UI 層(adapter)儲存的普通 List
//      · 谷標點 → 由呼叫端傳入(UI 用同一套 signal 自行偵測)
//    命運三色(紅/橘/紫)在 K2 沒有對應資料 → 傳空,不繪製。
class K2WaveChart extends StatefulWidget {
  /// 波形歷史(oldest→newest),由 UI 層儲存。
  final List<int> ir;
  final List<int> red;

  /// 谷位置:對應 [ir]/[red] 的索引(UI 自行偵測後傳入)。
  final List<int> troughs;

  /// 對照用的第二組谷(0.0.0.7 對照核心),索引規則同 [troughs]。
  /// 畫成金色:波形上一個空心圈 + 底部時間線上方的金色直條。
  final List<int> troughsAlt;

  /// 真正的 RR(起谷 → 終谷,索引規則同 [troughs]),底部時間線的數字標在這些上面。
  /// null → 退回「相鄰兩顆谷的距離」(快照檢視器只有谷、沒有 RR 時用)——
  /// 那樣跨過空洞也會標一個數字,但它不是 RR,所以有 RR 時一律傳這個。
  final List<({int from, int to})>? rrSpans;

  /// 0.0.0.7 對照的 RR,規則同 [rrSpans],金字標在時間線上方。
  final List<({int from, int to})>? rrSpansAlt;

  /// 疊一條**原始 IR**(白線,只轉正、不濾波)。獨立刻度:DC 約 8 萬、
  /// 漂移常比脈搏大,沒辦法與去趨勢後的線共用 ±振幅。
  final bool showRawIr;

  /// 疊一條 **0.0.0.7 找谷用的線**(金線,截尾 → 減 2 秒移動平均 → 13 點平均),
  /// 與 IR 線(現行 0.0.0.8 的帶通線)共用刻度,形狀可以直接比。
  final bool showAltLine;

  /// [ir] 第 0 筆的**絕對樣本位置**。只用來記住「點選了哪顆谷」——
  /// 滾動模式下陣列一直往前裁,索引會變,絕對位置不會,直線才跟得住那顆谷。
  /// 快照檢視器之類資料不動的地方不用給。
  final int absOffset;

  /// 已經處理好的 IR 線(找谷用的那條),與 [ir] 逐筆對齊;null 的位置圖自己算。
  ///
  /// 定長模式傳核心的 newIrWave(= server 送出的 wave)—— 那是等右邊資料到齊才算的,
  /// 每一筆都有完整前後文;圖自己算的話,陣列最右邊那段只能用截斷的視窗。
  /// 算法是同一支(Max30102Signal.troughLine),有值的位置兩者本來就該相同。
  final List<double?>? irWave;

  /// 低通移動平均的視窗寬(找谷前的最後一步,見 Max30102Signal.lowpassWindow)。
  /// 畫出來的線要與找谷用的線相同,這一步不能省。
  final int lowpassWindow;

  final int displaySamples;
  final int windowSeconds;
  final int baselineWindow; // = FS / bandLow（中心化移動平均視窗寬）
  final int trimWindow; // 截尾去突波視窗（讓線乾淨）
  final double promRatio;
  final bool showIr;
  final bool showRed;
  final double? fixedAmp; // 非 null → 縱軸固定用此半振幅(±);null → 自動縮放

  /// 重繪版本號:**必須單調遞增**(例如「累計收到的樣本數」)。
  /// ⚠ 不可用 ir.length —— 波形歷史滿了以後長度恆定,shouldRepaint 會永遠回 false
  ///   → 畫面在緩衝填滿的那一刻凍住。
  final int version;

  /// 「N 秒前」垂直參考線(例:[10, 20]);與下方 RR 趨勢圖用同一組秒數。
  final List<int> markSeconds;

  /// 時間區塊底色(定長模式用:空轉 / 沉澱 / 方向判定 / 正常)。
  /// `from`/`to` 是**相對 [ir] 第 0 筆**的索引;顏色與文字由呼叫端決定 ——
  /// 這裡只負責畫,語意留在上層(定長窗模組不 import material)。
  /// 滾動模式傳空陣列(開頭早就滑出畫面了)。
  final List<({int from, int to, String label, Color color})> bands;

  /// 事件標記:垂直虛線 + 文字。`at` 是**相對 [ir] 第 0 筆**的索引。
  /// 用來標出核心裡那幾個精確的瞬間(判定開始 / 釋放 / baseline 可信起點)。
  final List<({int at, String label, Color color})> events;

  const K2WaveChart({
    super.key,
    required this.ir,
    required this.red,
    this.troughs = const [],
    this.troughsAlt = const [],
    this.rrSpans,
    this.rrSpansAlt,
    this.showRawIr = false,
    this.showAltLine = false,
    this.absOffset = 0,
    this.irWave,
    required this.version,
    this.markSeconds = const [],
    required this.displaySamples,
    required this.windowSeconds,
    required this.baselineWindow,
    required this.lowpassWindow,
    required this.trimWindow,
    required this.promRatio,
    this.showIr = true,
    this.showRed = true,
    this.fixedAmp,
    this.bands = const [],
    this.events = const [],
  });

  @override
  State<K2WaveChart> createState() => _K2WaveChartState();
}

/// 圖內的放大縮小 —— **只是看**,資料與計算都不動。
///
///   滾輪          時間軸 1~10 倍,以游標為中心(游標底下那一點縮放前後不動)
///   Ctrl + 滾輪   振幅 0.5~8 倍(超出框外的線切掉)
///   左右拖曳      放大後左右移動
///   雙擊          全部還原
///   點時間線直條  從那顆谷畫一條貫穿整張圖的直線,標出它落在每條線的哪個點;
///                 線上方點 = 對照 0.0.0.7(金)、線下方點 = 現行(IR 色);再點一次取消,
///                 點時間線上的空白處全部取消。可以同時選好幾顆。
///
/// 縮放狀態存在這裡,所以頁面每秒 / 每 0.1 秒重建圖時不會被重設;
/// 頁面換了 key(切定長 / 滾動等)才會回到 1 倍。
/// 滾動模式下資料一直往左滑,放大的是「畫面上的某個位置」,波形會從那裡滑過去 ——
/// 要定住看就切定長模式、按停止量測,或在快照檢視器裡看。
class _K2WaveChartState extends State<K2WaveChart> {
  double _zoomX = 1;
  double _zoomY = 1;

  /// 畫面左緣 = 整段寬度的第幾成(0 ~ 1 − 1/_zoomX)。
  double _viewStart = 0;

  static const double _maxZoomX = 10;
  static const double _minZoomY = 0.5;
  static const double _maxZoomY = 8;
  static const double _step = 1.25; // 滾輪一格

  /// 點選的谷:絕對樣本位置 + 是不是對照(0.0.0.7)那一組(見 [K2WaveChart.absOffset])。
  final Set<({int abs, bool alt})> _picked = {};

  void _clampView() => _viewStart = _viewStart.clamp(0.0, 1 - 1 / _zoomX);

  @override
  void didUpdateWidget(covariant K2WaveChart old) {
    super.didUpdateWidget(old);
    // 絕對位置倒退 = 核心歸零(下一次量測)→ 記住的谷全部失效
    if (widget.absOffset < old.absOffset) _picked.clear();
  }

  /// 點在時間線附近 → 找最近的直條(左右 6px 內)切換它;附近沒有直條 → 全部取消。
  /// 線的上方找對照 0.0.0.7(金,往上凸),下方找現行(往下凸)—— 兩版同位置時才分得開。
  /// 位置換算與 painter 完全相同(xOfVisible / 時間線高度)。
  void _onTap(Offset p, Size size) {
    final c = widget;
    final w = size.width;
    final tlY = size.height - _Waveform2Painter.timelineFromBottom;
    if ((p.dy - tlY).abs() > 14) return; // 不是點在時間線上
    final count = c.ir.length < c.red.length ? c.ir.length : c.red.length;
    final visible = count < c.displaySamples ? count : c.displaySamples;
    if (visible < 2) return;
    final firstWindowIdx = c.displaySamples - visible;
    final firstIdx = c.ir.length - visible;
    double xOf(int idx) =>
        (w * (firstWindowIdx + idx - firstIdx) / (c.displaySamples - 1) -
            _viewStart * w) *
        _zoomX;
    final alt = p.dy < tlY;
    int? best;
    double bestD = 6;
    for (final t in alt ? c.troughsAlt : c.troughs) {
      final d = (xOf(t) - p.dx).abs();
      if (d <= bestD) {
        bestD = d;
        best = t;
      }
    }
    setState(() {
      if (best == null) {
        _picked.clear();
      } else {
        final key = (abs: best + c.absOffset, alt: alt);
        if (!_picked.remove(key)) _picked.add(key);
      }
    });
  }

  void _onScroll(PointerScrollEvent e, double width) {
    if (width <= 0) return;
    final f = e.scrollDelta.dy < 0 ? _step : 1 / _step;
    setState(() {
      if (HardwareKeyboard.instance.isControlPressed) {
        _zoomY = (_zoomY * f).clamp(_minZoomY, _maxZoomY);
      } else {
        final px = e.localPosition.dx;
        final at = _viewStart + px / (width * _zoomX); // 游標在整段裡的位置(0~1)
        _zoomX = (_zoomX * f).clamp(1.0, _maxZoomX);
        _viewStart = at - px / (width * _zoomX);
        _clampView();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget;
    return LayoutBuilder(
      builder: (context, box) => Listener(
        // 先向 resolver 登記 → 這一次滾輪只給圖,外層頁面不會跟著捲動
        onPointerSignal: (e) {
          if (e is PointerScrollEvent) {
            GestureBinding.instance.pointerSignalResolver.register(
              e,
              (ev) => _onScroll(ev as PointerScrollEvent, box.maxWidth),
            );
          }
        },
        child: GestureDetector(
          // 有雙擊時,單擊要等雙擊判定逾時(約 0.3 秒)才會觸發 —— 正常現象
          onTapUp: (d) =>
              _onTap(d.localPosition, Size(box.maxWidth, box.maxHeight)),
          onDoubleTap: () => setState(() {
            _zoomX = 1;
            _zoomY = 1;
            _viewStart = 0;
          }),
          onHorizontalDragUpdate: _zoomX <= 1
              ? null
              : (d) => setState(() {
                    _viewStart -= d.delta.dx / (box.maxWidth * _zoomX);
                    _clampView();
                  }),
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _Waveform2Painter(
                ir: c.ir,
                red: c.red,
                irWave: c.irWave,
                // 索引直接當「絕對位置」用:totalSamples = 長度 → painter 內的換算成立
                totalSamples: c.ir.length,
                displaySamples: c.displaySamples,
                windowSeconds: c.windowSeconds,
                baselineWindow: c.baselineWindow,
                lowpassWindow: c.lowpassWindow,
                trimWindow: c.trimWindow,
                promRatio: c.promRatio,
                bands: c.bands,
                events: c.events,
                showIr: c.showIr,
                showRed: c.showRed,
                hrvTroughAbs: c.troughs, // 🟡 谷標點
                altTroughAbs: c.troughsAlt, // 金:0.0.0.7 對照的谷
                rrSpans: c.rrSpans,
                rrSpansAlt: c.rrSpansAlt,
                showRawIr: c.showRawIr,
                showAltLine: c.showAltLine,
                searchBackAbs: const [], // K2 無補漏拍白點
                cleanRejectAbs: const [], // K2 核心不吐命運 → 不繪
                beatRejectAbs: const [],
                ectopicAbs: const [],
                fixedAmp: c.fixedAmp,
                version: c.version, // 外部傳入的單調遞增計數(不可用 ir.length)
                markSeconds: c.markSeconds,
                zoomX: _zoomX,
                zoomY: _zoomY,
                viewStart: _viewStart,
                // 記的是絕對位置,換回這一次的陣列索引再交給 painter
                picked: [
                  for (final p in _picked)
                    (index: p.abs - c.absOffset, alt: p.alt),
                ],
                // painter 沒有 BuildContext,語言當參數傳進去;它同時是 shouldRepaint
                // 的判斷依據 —— 切語言時 version 不會動,不帶它進去文字就不會更新。
                lang: LocalizationService().currentLanguage,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
  }
}

class _Waveform2Painter extends CustomPainter {
  // K2 版:改吃普通 List(UI 層儲存的波形歷史),不再用 ring buffer。
  final List<int> ir;
  final List<int> red;
  final List<double?>? irWave; // 見 K2WaveChart.irWave
  final int totalSamples;
  final int displaySamples;
  final int windowSeconds;
  final int baselineWindow;
  final int lowpassWindow;
  final int trimWindow;
  final double promRatio;
  final bool showIr;
  final bool showRed;
  final List<int> hrvTroughAbs; // 🟡 進 HRV(clean 保留拍端點)
  final List<int> altTroughAbs; // 金:0.0.0.7 對照核心的谷
  final List<({int from, int to})>? rrSpans; // IR 色字:現行核心(0.0.0.8)的 RR
  final List<({int from, int to})>? rrSpansAlt; // 金字:0.0.0.7 對照的 RR
  final bool showRawIr; // 白線:原始 IR(獨立刻度)
  final bool showAltLine; // 金線:0.0.0.7 的移動平均線(與 IR 同刻度)
  // 圖內縮放(見 _K2WaveChartState):時間倍數 / 振幅倍數 / 畫面左緣在整段的第幾成
  final double zoomX;
  final double zoomY;
  final double viewStart;
  // 點選的谷(陣列索引 + 是不是 0.0.0.7 對照):畫一條貫穿整張圖的直線
  final List<({int index, bool alt})> picked;
  final List<int> searchBackAbs;

  /// 底部時間線距圖底的高度。點擊判定(_K2WaveChartState._onTap)與畫圖共用這一個數字。
  static const double timelineFromBottom = 30;
  final List<int> cleanRejectAbs; // 🔴 clean(顯示MAD) 剔除拍的終谷(未算進HRV)
  final List<int> beatRejectAbs; // 🟠 BeatSeries(生理閘門/誤拍) 剔除的谷
  final List<int> ectopicAbs; // 🟣 H1 疑似異位拍(短拍終谷=早搏谷);純標記不影響HRV
  final double? fixedAmp; // 非 null → 縱軸固定半振幅;null → 自動
  final int version;
  final List<int> markSeconds; // 「N 秒前」垂直參考線
  final List<({int from, int to, String label, Color color})> bands;
  final List<({int at, String label, Color color})> events;
  final AppLanguage lang; // 只為了讓 shouldRepaint 認得語言變化

  static const Color _irColor = Color(0xFF80DEEA); // IR：青
  static const Color _redColor = Color(0xFFFF8A80); // RED：紅
  static const Color _bg = Color(0xFF101418);
  static const Color _envColor = Color(0xFFFFAB40); // 橘：最高峰/最低谷 包絡

  _Waveform2Painter({
    required this.ir,
    required this.red,
    this.irWave,
    required this.totalSamples,
    required this.displaySamples,
    required this.windowSeconds,
    required this.baselineWindow,
    required this.lowpassWindow,
    required this.trimWindow,
    required this.promRatio,
    required this.showIr,
    required this.showRed,
    required this.hrvTroughAbs,
    this.altTroughAbs = const [],
    this.rrSpans,
    this.rrSpansAlt,
    this.showRawIr = false,
    this.showAltLine = false,
    this.zoomX = 1,
    this.zoomY = 1,
    this.viewStart = 0,
    this.picked = const [],
    required this.searchBackAbs,
    required this.cleanRejectAbs,
    required this.beatRejectAbs,
    required this.ectopicAbs,
    this.fixedAmp,
    required this.version,
    this.bands = const [],
    this.events = const [],
    this.markSeconds = const [],
    required this.lang,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    canvas.clipRect(Offset.zero & size); // 放大後超出框的線、字一律切掉
    canvas.drawRect(Offset.zero & size, Paint()..color = _bg);

    final channels = <_ChData>[];

    final count = ir.length < red.length ? ir.length : red.length;
    final visible = count < displaySamples ? count : displaySamples;
    final firstWindowIdx = displaySamples - visible;
    // 時間軸縮放:未縮放時的 x(0~w)→ 畫面上的 x。**所有水平位置都要經過它**
    // (波形、谷、時間線、區塊、事件線、秒格線、# 軸),圖上的東西才會一起縮放。
    double zx(double x) => (x - viewStart * w) * zoomX;
    double xOfVisible(int i) =>
        zx(w * (firstWindowIdx + i) / (displaySamples - 1));

    if (visible >= 2) {
      if (showIr) {
        channels.add(_buildChannel(ir, visible, _irColor, 'IR', given: irWave));
      }
      if (showRed) {
        channels.add(_buildChannel(red, visible, _redColor, 'RED'));
      }
    }

    // K2 版:移除下方「AC 回血/供血(折上)」帶 → 主圖用滿整個高度
    final mainBottom = h;

    // 主圖中線(=baseline 參考)固定在正中央
    final mid = mainBottom / 2;
    final halfPlot = (mainBottom / 2) * 0.88; // 上下各留邊

    if (channels.isEmpty) {
      _text(
          canvas,
          visible < 2 ? tr('k2_chart_waiting') : tr('k2_chart_no_channel'),
          Offset(8, mid - 7),
          Colors.grey.shade500,
          12);
      return;
    }

    // 共用縮放：固定範圍(fixedAmp)時用固定半振幅,方便跨時間比較振幅大小;
    //           否則自動 = 跨所有開啟通道求最大 |detrended|(每幀重算,會忽大忽小)。
    double amp;
    if (fixedAmp != null && fixedAmp! > 0) {
      amp = fixedAmp!;
    } else {
      amp = 1;
      for (final c in channels) {
        if (c.amp > amp) amp = c.amp;
      }
    }
    // 振幅縮放:半振幅縮小 zoomY 倍 = 線放大 zoomY 倍(超出框的部分由 clipRect 切掉)
    final ampView = amp / zoomY;
    double yOf(double d) => mid - (d / ampView) * halfPlot;
    // 固定範圍時在左上標「固定 ±值」,讓使用者知道目前縱軸尺度
    if (fixedAmp != null && fixedAmp! > 0) {
      _text(canvas, trParams('k2_chart_fixed_amp', {'v': fixedAmp!.round()}),
          const Offset(4, 2), Colors.lightBlue.shade200, 9);
    }
    // 縮放中:上方正中標倍數與還原方式
    if (zoomX != 1 || zoomY != 1) {
      final z = trParams('k2_chart_zoom', {
        'x': zoomX.toStringAsFixed(1),
        'y': zoomY.toStringAsFixed(1),
      });
      _text(canvas, z, Offset(w / 2 - _textW(z, 9) / 2, 2),
          Colors.amberAccent.shade100, 9);
    }

    // 時間格線（每秒一條）
    final grid = Paint()
      ..color = Colors.white.withValues(alpha: 0.07)
      ..strokeWidth = 1;
    for (int s = 0; s <= windowSeconds; s++) {
      final x = zx(w * s / windowSeconds);
      canvas.drawLine(Offset(x, 0), Offset(x, mainBottom), grid);
    }
    // ── 時間區塊底色 ──────────────────────────────────────────────
    // 索引是相對 ir[0] 的,只有「整段波形都放得下」時才對得上;滾動模式
    // 傳空陣列所以平常不會執行。畫在格線之後、波形之前 → 不蓋住資料。
    if (bands.isNotEmpty && count <= displaySamples) {
      for (final b in bands) {
        final x0 = xOfVisible(b.from.clamp(0, visible));
        final x1 = xOfVisible(b.to.clamp(0, visible));
        if (x1 - x0 < 0.5) continue;
        canvas.drawRect(
            Rect.fromLTRB(x0, 0, x1, mainBottom), Paint()..color = b.color);
        canvas.drawLine(Offset(x1, 0), Offset(x1, mainBottom),
            Paint()..color = Colors.white.withValues(alpha: 0.18));
        if (b.label.isNotEmpty && x1 - x0 > 30) {
          _text(canvas, b.label, Offset(x0 + 3, mainBottom - 13),
              Colors.white.withValues(alpha: 0.55), 9);
        }
      }
    }

    // 事件標記:垂直虛線 + 文字。與區塊同一套索引,所以同樣只在整段放得下時畫。
    if (events.isNotEmpty && count <= displaySamples) {
      for (final e in events) {
        final x = xOfVisible(e.at.clamp(0, visible));
        _dashedV(canvas, x, mainBottom, e.color);
        _text(canvas, e.label, Offset(x + 3, 15), e.color, 9);
      }
    }

    // 中線(baseline)：白色虛線水平置中
    _dashedH(canvas, w, mid, Colors.white.withValues(alpha: 0.5));
    _text(canvas, tr('k2_chart_baseline'), Offset(4, mid - 11),
        Colors.white.withValues(alpha: 0.45), 8);

    // 畫每個通道：去趨勢線 + DC(彎曲虛線) + 峰/谷
    final fsApprox = (displaySamples / windowSeconds);
    final minDist = (60 * fsApprox / 240).round().clamp(1, visible);

    // 「計算用的波谷」(= hrvTroughAbs，HR 與 HRV 同一批)換成視窗內索引。
    // 線上波谷標點、藍色間距、底部金點全部共用這份 → 不再各自重抓波谷。
    final firstAbs = totalSamples - visible; // 視窗最左樣本的絕對位置
    final goldVis = <int>[
      for (final absPos in hrvTroughAbs)
        if (absPos - firstAbs >= 0 && absPos - firstAbs < visible)
          absPos - firstAbs
    ];
    // clean 剔(🔴)、BeatSeries 剔(🟠) 的谷→視窗索引(Set 供 O(1) 查);未算進 HRV
    final cleanRejVis = <int>{
      for (final absPos in cleanRejectAbs)
        if (absPos - firstAbs >= 0 && absPos - firstAbs < visible)
          absPos - firstAbs
    };
    final beatRejVis = <int>{
      for (final absPos in beatRejectAbs)
        if (absPos - firstAbs >= 0 && absPos - firstAbs < visible)
          absPos - firstAbs
    };
    // 🟣 H1 疑似異位拍(早搏):是「被接受的拍」(仍在 goldVis 內、仍算進 HRV),
    //    A 階段只用紫圈標「疑似早搏」,不剔除、不改數字。
    final ectopicVis = <int>{
      for (final absPos in ectopicAbs)
        if (absPos - firstAbs >= 0 && absPos - firstAbs < visible)
          absPos - firstAbs
    };
    final altVis = <int>[
      for (final absPos in altTroughAbs)
        if (absPos - firstAbs >= 0 && absPos - firstAbs < visible)
          absPos - firstAbs
    ];

    // 峰/谷包絡用:主通道(IR 優先)的平滑線 + 跨通道最大 |平滑值| → 「建議固定 ±」
    List<double>? primarySm;
    double smMaxAbs = 0;

    for (final c in channels) {
      // 直接畫找谷用的那條線(c.detr = 截尾 → 減 baseline → 13 點低通,
      // 與核心 / server 的 wave 同一支 troughLine),峰谷也標在它上面。
      // ⚠️ 不可以再疊一次移動平均:10/29 把 13 點低通併進 troughLine 之後,
      //    這裡原本的那次平滑沒拿掉,畫出來的線被平滑了兩次、谷比實際鈍 ——
      //    看不出核心實際是在哪裡拿到谷的。
      final sm = c.detr;
      if (primarySm == null || c.name == 'IR') primarySm = sm;
      for (final v in sm) {
        final a = v.abs();
        if (a > smMaxAbs) smMaxAbs = a;
      }

      final linePaint = Paint()
        ..color = c.color
        ..strokeWidth = 1.4
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round;
      final path = Path();
      for (int i = 0; i < visible; i++) {
        final x = xOfVisible(i);
        final y = yOf(sm[i]); // 不夾:振幅放大後超出框的部分交給 clipRect 切掉
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(path, linePaint);

      // DC − baseline（置中座標下會是彎曲虛線；使用者已接受）
      _dcCurve(canvas, c, visible, xOfVisible, yOf, mainBottom);

      // 波峰：維持自抓(純視覺，HR-B 不用波峰)
      final peaks =
          Max30102Signal.findProminentPeaks(sm, minDist, promRatio);
      _drawMarks(canvas, peaks, sm, visible, xOfVisible, yOf, mainBottom,
          c.color,
          isPeak: true);
      // 波谷：直接用「計算用的波谷」(goldVis)，不重抓 → 線上點 = 算 HR/HRV 的點
      _drawMarks(canvas, goldVis, sm, visible, xOfVisible, yOf, mainBottom,
          c.color,
          isPeak: false);
      // clean 剔(🔴紅) 與 BeatSeries 剔(🟠橘) 的谷：疊實心+圈,標「偵測到但未算進 HRV」
      void overlay(Set<int> vis, Color col) {
        if (vis.isEmpty) return;
        final fill = Paint()..color = col;
        final ring = Paint()
          ..color = col
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.3;
        for (final i in vis) {
          if (i < 0 || i >= visible) continue;
          final o = Offset(xOfVisible(i), yOf(sm[i]).clamp(0.0, mainBottom));
          canvas.drawCircle(o, 3.0, fill);
          canvas.drawCircle(o, 4.6, ring);
        }
      }

      overlay(cleanRejVis, const Color(0xFFFF5252)); // 🔴 clean 剔
      overlay(beatRejVis, const Color(0xFFFF9800)); // 🟠 生理閘門·誤拍 剔
      // 🟣 H1 疑似異位拍:紫色空心圈套在「被接受的拍」外圈 → 不蓋底下標點,
      //    一眼看出「有抓到早搏、但沒剔除(數字不變)」。
      if (ectopicVis.isNotEmpty) {
        final ring = Paint()
          ..color = const Color(0xFFE040FB)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0;
        for (final i in ectopicVis) {
          if (i < 0 || i >= visible) continue;
          final o = Offset(xOfVisible(i), yOf(sm[i]).clamp(0.0, mainBottom));
          canvas.drawCircle(o, 6.0, ring);
        }
      }
    }

    // ── 對照用的兩條線(開關,預設關)─────────────────────────────────────
    const cmpColor = Color(0xFFFFD740); // 對照(0.0.0.7)一律金色(線、谷圈、時間線)
    final rawFrom = ir.length - visible;
    // 白線:原始 IR,只轉正、不濾波。獨立刻度 —— 撐滿上下 88%,左上標峰峰值。
    double Function(int i)? rawYOf; // 點選直線要在白線上標交會點,換算留著
    if (showRawIr && visible >= 2) {
      double lo = double.infinity, hi = -double.infinity;
      for (int i = 0; i < visible; i++) {
        final v = ir[rawFrom + i].toDouble();
        if (v < lo) lo = v;
        if (v > hi) hi = v;
      }
      final span = hi - lo < 1 ? 1.0 : hi - lo;
      // 未縮放時撐滿上下 88%;振幅縮放以中線為中心一起放大
      rawYOf = (i) =>
          mid - (ir[rawFrom + i] - (lo + hi) / 2) / (span / 2) * halfPlot * zoomY;
      final path = Path();
      for (int i = 0; i < visible; i++) {
        final y = rawYOf(i);
        if (i == 0) {
          path.moveTo(xOfVisible(i), y);
        } else {
          path.lineTo(xOfVisible(i), y);
        }
      }
      canvas.drawPath(
          path,
          Paint()
            ..color = Colors.white.withValues(alpha: 0.85)
            ..strokeWidth = 1.1
            ..style = PaintingStyle.stroke);
      _text(canvas, trParams('k2_chart_raw_ir', {'v': span.round()}),
          const Offset(4, 28), Colors.white, 9);
    }
    // 金線:0.0.0.7 找谷用的線 = 截尾 → 減 2 秒移動平均 → 13 點平均(與 IR 線同刻度)。
    // 用 0.0.0.7 對照核心自己的那支函式,算法與它當時一模一樣。
    List<double>? altLine;
    if (showAltLine && visible >= 2) {
      final rawD =
          List<double>.generate(visible, (i) => ir[rawFrom + i].toDouble());
      final line = v7.Max30102Signal.troughLine(
        rawD,
        trimWindow: trimWindow,
        baselineWindow: baselineWindow,
        lowpassWindow: lowpassWindow,
      );
      altLine = line;
      final path = Path();
      for (int i = 0; i < visible; i++) {
        final y = yOf(line[i]);
        if (i == 0) {
          path.moveTo(xOfVisible(i), y);
        } else {
          path.lineTo(xOfVisible(i), y);
        }
      }
      canvas.drawPath(
          path,
          Paint()
            ..color = cmpColor
            ..strokeWidth = 1.4
            ..style = PaintingStyle.stroke
            ..strokeJoin = StrokeJoin.round);
      _text(canvas, tr('k2_chart_v7_line'), const Offset(4, 40), cmpColor, 9);
    }

    // ── 底部時間線:白線,谷 = 穿過白線的直條,RR = 直條之間的數字 ─────────────
    //    現行核心(IR 色):直條往下凸、數字在線下;0.0.0.7 對照(金):往上凸、數字在線上。
    //    兩版同一顆谷 → 上下接成一條貫穿的直線;位置不同 → 錯開,一眼看出移了多少。
    //    數字只標真正的 RR(rrSpans);沒給就退回相鄰谷距(那樣跨空洞也會標,但不是 RR)。
    final msPerSample = windowSeconds * 1000 / displaySamples;
    // 線下的字約到 mainBottom − 17,不碰最底下的時間軸文字;點擊判定也用這個高度
    final tlY = mainBottom - timelineFromBottom;
    if (visible >= 2) {
      canvas.drawLine(
          Offset(xOfVisible(0), tlY),
          Offset(xOfVisible(visible - 1), tlY),
          Paint()
            ..color = Colors.white.withValues(alpha: 0.55)
            ..strokeWidth = 1);
    }
    List<({int from, int to})> spansVis(
            List<({int from, int to})>? spans, List<int> vis) =>
        spans == null
            ? [for (int k = 1; k < vis.length; k++) (from: vis[k - 1], to: vis[k])]
            : [
                for (final s in spans)
                  if (s.from - firstAbs >= 0 && s.to - firstAbs < visible)
                    (from: s.from - firstAbs, to: s.to - firstAbs),
              ];
    void timeline(List<int> vis, List<({int from, int to})> spans, Color col,
        {required bool up}) {
      final tick = Paint()
        ..color = col
        ..strokeWidth = 1.5;
      for (final i in vis) {
        final x = xOfVisible(i);
        // 穿過白線:主要往外凸 9px,另一側只露 3px
        canvas.drawLine(Offset(x, up ? tlY + 3 : tlY - 3),
            Offset(x, up ? tlY - 9 : tlY + 9), tick);
      }
      for (final s in spans) {
        final x1 = xOfVisible(s.from), x2 = xOfVisible(s.to);
        if (x2 - x1 <= 20) continue;
        final ms = ((s.to - s.from) * msPerSample).round().toString();
        _text(canvas, ms, Offset((x1 + x2) / 2 - _textW(ms, 8) / 2,
            up ? tlY - 12 : tlY + 2), col, 8);
      }
    }

    // 現行核心用 IR 線的顏色(與波形上的 IR 線、谷標點同色),0.0.0.7 對照用金色 —— 兩版徹底分開
    timeline(goldVis, spansVis(rrSpans, goldVis), _irColor, up: false);
    timeline(altVis, spansVis(rrSpansAlt, altVis), cmpColor, up: true);

    // ── 點選的谷:貫穿整張圖的直線 + 與每條線的交會點 ─────────────────────────
    //    看「這顆谷落在線的哪個位置」:正好在最低點、還是偏在坡上。
    //    直線顏色 = 那顆谷的版本(現行 IR 色 / 0.0.0.7 對照金);交會點用各條線自己的顏色。
    for (final p in picked) {
      final i = p.index - firstAbs;
      if (i < 0 || i >= visible) continue;
      final x = xOfVisible(i);
      final col = p.alt ? cmpColor : _irColor;
      canvas.drawLine(
          Offset(x, 0),
          Offset(x, mainBottom),
          Paint()
            ..color = col.withValues(alpha: 0.9)
            ..strokeWidth = 1);
      void cross(double y, Color c) {
        canvas.drawCircle(Offset(x, y), 4.2, Paint()..color = _bg);
        canvas.drawCircle(Offset(x, y), 3.2, Paint()..color = c);
      }

      for (final ch in channels) {
        cross(yOf(ch.detr[i]), ch.color);
      }
      if (altLine != null) cross(yOf(altLine[i]), cmpColor);
      if (rawYOf != null) cross(rawYOf(i), Colors.white);
      // 標號與底部 # 軸同一套(陣列索引),兩邊對得起來
      final label = '#${p.index}';
      _text(canvas, label, Offset(x + 3, p.alt ? 52 : 64), col, 9);
    }

    // 最高峰/最低谷包絡：先畫(在底部金點之前) → 橘色「谷」極值標記不會蓋住金點。
    final ps = primarySm;
    if (ps != null) {
      _drawExtremes(canvas, ps, w, mainBottom, xOfVisible, yOf,
          smMaxAbs <= 0 ? 1.0 : smMaxAbs,
          sumY: (fixedAmp != null && fixedAmp! > 0) ? 14.0 : 2.0);
    }

    // ── 0.0.0.7 對照核心的谷:波形上的金色空心圈(底部的金色直條見上方時間線) ─────
    //    金線開著 → 圈在金線上(那才是 0.0.0.7 找谷的線);關著 → 圈在 IR 線上,
    //    那條不是 0.0.0.7 找谷用的線,所以圈不一定剛好在最低點。
    final ringLine = altLine ?? ps;
    if (altVis.isNotEmpty && ringLine != null) {
      final ring = Paint()
        ..color = cmpColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6;
      for (final i in altVis) {
        if (i < 0 || i >= visible) continue;
        canvas.drawCircle(
            Offset(xOfVisible(i), yOf(ringLine[i]).clamp(0.0, mainBottom)),
            5.5,
            ring);
      }
    }

    // ── 真正算進 HRV 的波谷:改畫成上方時間線的金色直條(原本是底部一排金點)。
    //    某個波谷正下方沒有金色直條 = 它沒被算進 HRV(例如最右剛被 B 丟掉那拍)。
    //    以下只剩補漏拍(search-back)的白點 —— K2 不傳,平常不會畫。
    if (goldVis.isNotEmpty) {
      final markY = mainBottom - 4;
      // search-back 補回的谷：白點(更明顯，與偵測金點區分)
      final white = Paint()..color = Colors.white;
      final whiteTick = Paint()
        ..color = Colors.white.withValues(alpha: 0.7)
        ..strokeWidth = 1.2;
      final whiteVis = <int>[];
      for (final absPos in searchBackAbs) {
        final i = absPos - firstAbs;
        if (i < 0 || i >= visible) continue;
        whiteVis.add(i);
        final x = xOfVisible(i);
        canvas.drawLine(Offset(x, markY - 9), Offset(x, markY), whiteTick);
        canvas.drawCircle(Offset(x, markY), 3.2, white);
      }
      // 補漏拍切出的間距(白字)：每個白點標「前段|後段」ms，看 gap 被切成多少。
      // 原本的長間距(金點↔金點)由上方 _drawTroughIntervals 保留不動。
      if (whiteVis.isNotEmpty) {
        final merged = [...goldVis, ...whiteVis]..sort();
        for (final w in whiteVis) {
          final pos = merged.indexOf(w);
          final parts = <String>[];
          if (pos > 0) {
            parts.add(((w - merged[pos - 1]) * msPerSample).round().toString());
          }
          if (pos < merged.length - 1) {
            parts.add(((merged[pos + 1] - w) * msPerSample).round().toString());
          }
          if (parts.isEmpty) continue;
          final label = '${parts.join("|")}ms';
          final tw = _textW(label, 8);
          // 往上提，與藍色(原本)間距標籤錯開
          _text(canvas, label, Offset(xOfVisible(w) - tw / 2, markY - 34),
              Colors.white, 8);
        }
      }
    }

    // 通道圖例（右上）
    double lx = w - 6;
    for (final c in channels.reversed) {
      final label = c.name;
      final tw = _textW(label, 10);
      lx -= tw + 16;
      canvas.drawCircle(Offset(lx, 8), 4, Paint()..color = c.color);
      _text(canvas, label, Offset(lx + 7, 2), c.color, 10);
    }

    // (K2 版已移除下方 AC 帶)

    // 「N 秒前」垂直參考線(與下方 RR 趨勢圖同秒數對齊)。
    // x 由右緣(now)往左推:sec 秒前 → x = w × (1 − sec/windowSeconds)。
    for (final sec in markSeconds) {
      if (sec <= 0 || sec >= windowSeconds) continue; // 等於視窗寬 = 最左緣,不用畫
      final x = zx(w * (1 - sec / windowSeconds));
      final mp = Paint()
        ..color = Colors.white.withValues(alpha: 0.30)
        ..strokeWidth = 1;
      for (double y = 0; y < mainBottom - 14; y += 8) {
        canvas.drawLine(Offset(x, y), Offset(x, y + 4), mp);
      }
      _text(canvas, '-${sec}s', Offset(x + 2, 2),
          Colors.white.withValues(alpha: 0.45), 9);
    }

    // 左下時間標記 —— 只在沒放大時畫:放大後畫面兩端已經不是 −N 秒與 now
    if (zoomX == 1) {
      _text(canvas, '-${windowSeconds}s', Offset(2, mainBottom - 12),
          Colors.grey.shade600, 9);
      _text(canvas, 'now', Offset(w - 22, mainBottom - 12),
          Colors.grey.shade600, 9);
    }
    // 絕對樣本索引「#」軸:對應「HRV 篩除記錄」的 #位置(每 index = 1/fs 秒,fs=100→10ms)。
    // 沿每隔幾秒的格線標一次,避開最左/最右(留給 -Ns / now)。
    // 間隔跟著時間軸縮放變密:畫面上永遠大約 5 個(放大後才找得到某顆谷的 #位置)。
    final idxStep =
        (windowSeconds / zoomX / 5).ceil().clamp(1, windowSeconds);
    for (int s = idxStep; s < windowSeconds; s += idxStep) {
      final di = (s / windowSeconds * (displaySamples - 1)).round();
      final vi = di - firstWindowIdx; // 視窗內索引
      if (vi < 0 || vi >= visible) continue;
      final label = '#${firstAbs + vi}';
      final tw = _textW(label, 8);
      _text(canvas, label,
          Offset(zx(w * s / windowSeconds) - tw / 2, mainBottom - 12),
          Colors.grey.shade500, 8);
    }
  }

  /// 取 List 尾端可見段 → 算 baseline(中心化移動平均) → detrended
  /// (K2 版:原本是讀 ring buffer,改成從普通 List 的最後 visible 筆取)
  ///
  /// [given] = 已經處理好的線(與 [src] 逐筆對齊);有值的位置直接用,null 的位置用自己算的。
  _ChData _buildChannel(
      List<int> src, int visible, Color color, String name,
      {List<double?>? given}) {
    final raw = List<int>.filled(visible, 0);
    final from = src.length - visible;
    for (int i = 0; i < visible; i++) {
      raw[i] = src[from + i];
    }
    // 截尾 → 0.7~3.5 Hz 帶通:與核心找谷、newIrWave 同一支(Max30102Signal.bandpass),
    // 畫出來的線就是找谷用的那條線。base(2 秒移動平均)只留給下面的 DC 虛線用。
    // 有 [given](核心的 newIrWave)的位置一律用它 —— 那是核心找谷當下看到的值;
    // 這裡自己算的只補「核心還沒交出來」的位置(開頭段、最新約 1.5 秒)。
    final rawD = List<double>.generate(visible, (i) => raw[i].toDouble());
    final trimmed = Max30102Signal.slidingTrimmedMean(rawD, trimWindow);
    final base = Max30102Signal.movingAverage(trimmed, baselineWindow);
    final line = Max30102Signal.bandpass(
      trimmed,
      Max30102Config.samplingRateHz,
      lowHz: Max30102Config.beatBandLowHz,
      highHz: Max30102Config.beatBandHighHz,
    );
    final detr = List<double>.generate(visible, (i) {
      final g = (given != null && from + i < given.length) ? given[from + i] : null;
      return g ?? line[i];
    });
    double amp = 1;
    for (final d in detr) {
      final a = d.abs();
      if (a > amp) amp = a;
    }
    // dcMinusBase = 「最後 baselineWindow 筆的平均」− baseline（置中座標）
    final dcN = baselineWindow < visible ? baselineWindow : visible;
    double sum = 0;
    for (int i = visible - dcN; i < visible; i++) {
      sum += raw[i];
    }
    final dcMean = sum / dcN;
    final dcMinusBase =
        List<double>.generate(visible, (i) => dcMean - base[i]);
    return _ChData(raw, detr, dcMinusBase, amp, color, name);
  }

  void _dcCurve(Canvas canvas, _ChData c, int visible,
      double Function(int) xOfVisible, double Function(double) yOf,
      double mainBottom) {
    final paint = Paint()
      ..color = c.color.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    // 虛線：每隔幾筆畫一段
    final step = (visible / 60).clamp(2, 40).round();
    for (int i = 1; i < visible; i++) {
      if ((i ~/ step) % 2 != 0) continue;
      canvas.drawLine(
        Offset(xOfVisible(i - 1), yOf(c.dcMinusBase[i - 1]).clamp(0.0, mainBottom)),
        Offset(xOfVisible(i), yOf(c.dcMinusBase[i]).clamp(0.0, mainBottom)),
        paint,
      );
    }
  }

  void _drawMarks(Canvas canvas, List<int> idxs, List<double> ys, int visible,
      double Function(int) xOfVisible, double Function(double) yOf,
      double mainBottom, Color color,
      {required bool isPeak}) {
    final fill = Paint()..color = color;
    final ring = Paint()
      ..color = isPeak ? Colors.white : Colors.black54
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1;
    for (final k in idxs) {
      if (k < 0 || k >= visible) continue;
      final p = Offset(xOfVisible(k), yOf(ys[k]).clamp(0.0, mainBottom));
      canvas.drawCircle(p, 3.0, fill);
      canvas.drawCircle(p, 3.0, ring);
    }
  }

  /// 最高峰 / 最低谷:畫的是去趨勢訊號、中線 = baseline = 0,所以峰值本身就是
  /// 「相對 baseline 的差」、谷值是負的差;p2p = 峰 − 谷。
  /// 另標「建議固定 ±」= 目前視窗兩通道最大 |振幅|。原始振幅 ≈ DC × PI
  /// (接觸/壓力/灌注)每天都會變 → 「固定範圍」不能寫死,要看這些數字來設。
  void _drawExtremes(Canvas canvas, List<double> sm, double w,
      double mainBottom, double Function(int) xOfVisible,
      double Function(double) yOf, double suggestAmp,
      {required double sumY}) {
    if (sm.length < 2) return;
    int hiI = 0, loI = 0;
    for (int i = 1; i < sm.length; i++) {
      if (sm[i] > sm[hiI]) hiI = i;
      if (sm[i] < sm[loI]) loI = i;
    }
    final hi = sm[hiI], lo = sm[loI];
    final hiY = yOf(hi).clamp(0.0, mainBottom);
    final loY = yOf(lo).clamp(0.0, mainBottom);

    // 峰/谷 水平虛線(包絡)
    final faint = _envColor.withValues(alpha: 0.4);
    _dashedH(canvas, w, hiY, faint);
    _dashedH(canvas, w, loY, faint);

    // 標記點
    final fill = Paint()..color = _envColor;
    final ring = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (final p in [
      Offset(xOfVisible(hiI), hiY),
      Offset(xOfVisible(loI), loY)
    ]) {
      canvas.drawCircle(p, 4.2, fill);
      canvas.drawCircle(p, 4.2, ring);
    }

    double clampX(double x, double tw) {
      final maxX = w - 2 - tw;
      return maxX <= 2 ? 2.0 : x.clamp(2.0, maxX);
    }

    final hiL = trParams(
        'k2_chart_peak', {'v': '${hi >= 0 ? "+" : ""}${hi.round()}'});
    final loL = trParams(
        'k2_chart_trough', {'v': '${lo >= 0 ? "+" : ""}${lo.round()}'});
    _text(
        canvas,
        hiL,
        Offset(clampX(xOfVisible(hiI) + 7, _textW(hiL, 9)),
            (hiY - 14).clamp(0.0, mainBottom - 11)),
        _envColor,
        9);
    _text(
        canvas,
        loL,
        Offset(clampX(xOfVisible(loI) + 7, _textW(loL, 9)),
            (loY + 3).clamp(0.0, mainBottom - 11)),
        _envColor,
        9);

    // 摘要:p2p + 建議固定±(左上;有「固定 ±」標籤時往下讓一行)
    final sum = trParams('k2_chart_p2p',
        {'v': (hi - lo).round(), 'amp': suggestAmp.round()});
    _text(canvas, sum, Offset(4, sumY), _envColor, 9);
  }

  // (谷↔谷 間距原本由 _drawTroughIntervals 畫成 IR 色的線,已改成 paint() 裡的白色時間線)

  // (K2 版已移除 _drawAcStrip:AC 回血/供血折上帶不再顯示)

  // ---- helpers ----
  void _dashedV(Canvas canvas, double x, double h, Color color) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    const dash = 5.0, gap = 4.0;
    double y = 0;
    while (y < h) {
      canvas.drawLine(Offset(x, y), Offset(x, (y + dash).clamp(0, h)), paint);
      y += dash + gap;
    }
  }

  void _dashedH(Canvas canvas, double w, double y, Color color) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    const dash = 6.0, gap = 5.0;
    double x = 0;
    while (x < w) {
      canvas.drawLine(Offset(x, y), Offset((x + dash).clamp(0, w), y), paint);
      x += dash + gap;
    }
  }

  double _textW(String s, double size) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(fontSize: size)),
      textDirection: TextDirection.ltr,
    )..layout();
    return tp.width;
  }

  void _text(Canvas canvas, String s, Offset at, Color color, double size) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: color, fontSize: size)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(covariant _Waveform2Painter old) =>
      old.version != version ||
      old.altTroughAbs.length != altTroughAbs.length ||
      old.rrSpans?.length != rrSpans?.length ||
      old.rrSpansAlt?.length != rrSpansAlt?.length ||
      old.showRawIr != showRawIr ||
      old.showAltLine != showAltLine ||
      old.zoomX != zoomX ||
      old.zoomY != zoomY ||
      old.viewStart != viewStart ||
      !listEquals(old.picked, picked) ||
      old.displaySamples != displaySamples ||
      old.windowSeconds != windowSeconds ||
      old.baselineWindow != baselineWindow ||
      old.lowpassWindow != lowpassWindow ||
      old.trimWindow != trimWindow ||
      old.promRatio != promRatio ||
      old.showIr != showIr ||
      old.showRed != showRed ||
      old.fixedAmp != fixedAmp ||
      old.bands.length != bands.length ||
      old.events.length != events.length ||
      (events.isNotEmpty && old.events.last.at != events.last.at) ||
      (bands.isNotEmpty && old.bands.last.to != bands.last.to) ||
      old.lang != lang;
}

/// 單通道的計算結果
class _ChData {
  final List<int> raw;
  final List<double> detr; // raw − baseline（置中）
  final List<double> dcMinusBase; // DC − baseline（置中座標的 DC 線）
  final double amp; // max(|detr|)
  final Color color;
  final String name;
  _ChData(this.raw, this.detr, this.dcMinusBase, this.amp, this.color,
      this.name);
}
