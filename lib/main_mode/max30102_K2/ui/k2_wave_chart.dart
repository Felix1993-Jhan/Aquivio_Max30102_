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

import 'package:flutter/material.dart';

import '../../../shared/services/localization_service.dart';
import '../k2_signal.dart';

// ⚠️ K2 版:原本綁 Max30102Controller(ring buffer + troughFates)。
//    K2 核心「只算不存、也不吐谷位置」(顯示是 UI 的事),故改成:
//      · 波形 → 吃 UI 層(adapter)儲存的普通 List
//      · 谷標點 → 由呼叫端傳入(UI 用同一套 signal 自行偵測)
//    命運三色(紅/橘/紫)在 K2 沒有對應資料 → 傳空,不繪製。
class K2WaveChart extends StatelessWidget {
  /// 波形歷史(oldest→newest),由 UI 層儲存。
  final List<int> ir;
  final List<int> red;

  /// 谷位置:對應 [ir]/[red] 的索引(UI 自行偵測後傳入)。
  final List<int> troughs;

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

  const K2WaveChart({
    super.key,
    required this.ir,
    required this.red,
    this.troughs = const [],
    required this.version,
    this.markSeconds = const [],
    required this.displaySamples,
    required this.windowSeconds,
    required this.baselineWindow,
    required this.trimWindow,
    required this.promRatio,
    this.showIr = true,
    this.showRed = true,
    this.fixedAmp,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _Waveform2Painter(
          ir: ir,
          red: red,
          // 索引直接當「絕對位置」用:totalSamples = 長度 → painter 內的換算成立
          totalSamples: ir.length,
          displaySamples: displaySamples,
          windowSeconds: windowSeconds,
          baselineWindow: baselineWindow,
          trimWindow: trimWindow,
          promRatio: promRatio,
          showIr: showIr,
          showRed: showRed,
          hrvTroughAbs: troughs, // 🟡 谷標點
          searchBackAbs: const [], // K2 無補漏拍白點
          cleanRejectAbs: const [], // K2 核心不吐命運 → 不繪
          beatRejectAbs: const [],
          ectopicAbs: const [],
          fixedAmp: fixedAmp,
          version: version, // 外部傳入的單調遞增計數(不可用 ir.length)
          markSeconds: markSeconds,
          // painter 沒有 BuildContext,語言當參數傳進去;它同時是 shouldRepaint
          // 的判斷依據 —— 切語言時 version 不會動,不帶它進去文字就不會更新。
          lang: LocalizationService().currentLanguage,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _Waveform2Painter extends CustomPainter {
  // K2 版:改吃普通 List(UI 層儲存的波形歷史),不再用 ring buffer。
  final List<int> ir;
  final List<int> red;
  final int totalSamples;
  final int displaySamples;
  final int windowSeconds;
  final int baselineWindow;
  final int trimWindow;
  final double promRatio;
  final bool showIr;
  final bool showRed;
  final List<int> hrvTroughAbs; // 🟡 進 HRV(clean 保留拍端點)
  final List<int> searchBackAbs;
  final List<int> cleanRejectAbs; // 🔴 clean(顯示MAD) 剔除拍的終谷(未算進HRV)
  final List<int> beatRejectAbs; // 🟠 BeatSeries(生理閘門/誤拍) 剔除的谷
  final List<int> ectopicAbs; // 🟣 H1 疑似異位拍(短拍終谷=早搏谷);純標記不影響HRV
  final double? fixedAmp; // 非 null → 縱軸固定半振幅;null → 自動
  final int version;
  final List<int> markSeconds; // 「N 秒前」垂直參考線
  final AppLanguage lang; // 只為了讓 shouldRepaint 認得語言變化

  static const Color _irColor = Color(0xFF80DEEA); // IR：青
  static const Color _redColor = Color(0xFFFF8A80); // RED：紅
  static const Color _bg = Color(0xFF101418);
  static const Color _envColor = Color(0xFFFFAB40); // 橘：最高峰/最低谷 包絡

  _Waveform2Painter({
    required this.ir,
    required this.red,
    required this.totalSamples,
    required this.displaySamples,
    required this.windowSeconds,
    required this.baselineWindow,
    required this.trimWindow,
    required this.promRatio,
    required this.showIr,
    required this.showRed,
    required this.hrvTroughAbs,
    required this.searchBackAbs,
    required this.cleanRejectAbs,
    required this.beatRejectAbs,
    required this.ectopicAbs,
    this.fixedAmp,
    required this.version,
    this.markSeconds = const [],
    required this.lang,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    canvas.drawRect(Offset.zero & size, Paint()..color = _bg);

    final channels = <_ChData>[];

    final count = ir.length < red.length ? ir.length : red.length;
    final visible = count < displaySamples ? count : displaySamples;
    final firstWindowIdx = displaySamples - visible;
    double xOfVisible(int i) =>
        w * (firstWindowIdx + i) / (displaySamples - 1);

    if (visible >= 2) {
      if (showIr) {
        channels.add(_buildChannel(ir, visible, _irColor, 'IR'));
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
    double yOf(double d) => mid - (d / amp) * halfPlot;
    // 固定範圍時在左上標「固定 ±值」,讓使用者知道目前縱軸尺度
    if (fixedAmp != null && fixedAmp! > 0) {
      _text(canvas, trParams('k2_chart_fixed_amp', {'v': fixedAmp!.round()}),
          const Offset(4, 2), Colors.lightBlue.shade200, 9);
    }

    // 時間格線（每秒一條）
    final grid = Paint()
      ..color = Colors.white.withValues(alpha: 0.07)
      ..strokeWidth = 1;
    for (int s = 0; s <= windowSeconds; s++) {
      final x = w * s / windowSeconds;
      canvas.drawLine(Offset(x, 0), Offset(x, mainBottom), grid);
    }
    // 中線(baseline)：白色虛線水平置中
    _dashedH(canvas, w, mid, Colors.white.withValues(alpha: 0.5));
    _text(canvas, tr('k2_chart_baseline'), Offset(4, mid - 11),
        Colors.white.withValues(alpha: 0.45), 8);

    // 畫每個通道：去趨勢線 + DC(彎曲虛線) + 峰/谷
    final fsApprox = (displaySamples / windowSeconds);
    final minDist = (60 * fsApprox / 240).round().clamp(1, visible);
    final smWin = (fsApprox / 8).round().clamp(3, visible);

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

    // 峰/谷包絡用:主通道(IR 優先)的平滑線 + 跨通道最大 |平滑值| → 「建議固定 ±」
    List<double>? primarySm;
    double smMaxAbs = 0;

    for (final c in channels) {
      // 偵測用的平滑線(截尾去趨勢 → 13點移動平均)。
      // 直接畫「這條」——它才是找峰找谷實際在看的線,峰谷也標在它上面。
      final sm = Max30102Signal.movingAverage(c.detr, smWin);
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
        final y = yOf(sm[i]).clamp(0.0, mainBottom);
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

    // 谷↔谷 間距標籤。K2 的谷已是核心採用的那批 → 相鄰間距**就是**該筆 RR,
    // 與右側 RR 趨勢圖的數字完全一致(單位 ms,不再重複標出來)。
    final msPerSample = windowSeconds * 1000 / displaySamples;
    final primary = channels.firstWhere((c) => c.name == 'IR',
        orElse: () => channels.first);
    _drawTroughIntervals(canvas, goldVis, primary.color,
        mainBottom - 14, visible, xOfVisible, msPerSample);

    // 最高峰/最低谷包絡：先畫(在底部金點之前) → 橘色「谷」極值標記不會蓋住金點。
    final ps = primarySm;
    if (ps != null) {
      _drawExtremes(canvas, ps, w, mainBottom, xOfVisible, yOf,
          smMaxAbs <= 0 ? 1.0 : smMaxAbs,
          sumY: (fixedAmp != null && fixedAmp! > 0) ? 14.0 : 2.0);
    }

    // ── 真正算進 HRV 的波谷(來自 _peakAbsNew，已含 B 右緣過濾)：
    //    底部固定一排金點 + 短豎線。對齊驗證用——
    //    某個波谷正下方沒有金點 = 它沒被算進 HRV(例如最右剛被 B 丟掉那拍)。
    if (goldVis.isNotEmpty) {
      final markY = mainBottom - 4;
      final gold = Paint()..color = const Color(0xFFFFD740);
      final goldHalo = Paint()..color = _bg; // 深色暈:金點在任何色點(橘/紅)之上都清楚可辨
      final tick = Paint()
        ..color = const Color(0xFFFFD740).withValues(alpha: 0.5)
        ..strokeWidth = 1;
      // 底部金點：與線上波谷同一份 goldVis(時間軸 timeline)。
      // 畫在最後、加深色暈 → 永不被橘(誤拍)/紅(clean)剔除點或橘色「谷」極值標記擋住,
      // 才能確切判讀:有金點=算進 HRV、無金點=真的被剔掉(非被遮住)。
      for (final i in goldVis) {
        final x = xOfVisible(i);
        canvas.drawLine(Offset(x, markY - 8), Offset(x, markY), tick);
        canvas.drawCircle(Offset(x, markY), 4.0, goldHalo);
        canvas.drawCircle(Offset(x, markY), 3.0, gold);
      }
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
      final x = w * (1 - sec / windowSeconds);
      final mp = Paint()
        ..color = Colors.white.withValues(alpha: 0.30)
        ..strokeWidth = 1;
      for (double y = 0; y < mainBottom - 14; y += 8) {
        canvas.drawLine(Offset(x, y), Offset(x, y + 4), mp);
      }
      _text(canvas, '-${sec}s', Offset(x + 2, 2),
          Colors.white.withValues(alpha: 0.45), 9);
    }

    // 左下時間標記
    _text(canvas, '-${windowSeconds}s', Offset(2, mainBottom - 12),
        Colors.grey.shade600, 9);
    _text(canvas, 'now', Offset(w - 22, mainBottom - 12),
        Colors.grey.shade600, 9);
    // 絕對樣本索引「#」軸:對應「HRV 篩除記錄」的 #位置(每 index = 1/fs 秒,fs=100→10ms)。
    // 沿每隔幾秒的格線標一次,避開最左/最右(留給 -Ns / now)。
    final idxStep = (windowSeconds / 5).ceil().clamp(1, windowSeconds);
    for (int s = idxStep; s < windowSeconds; s += idxStep) {
      final di = (s / windowSeconds * (displaySamples - 1)).round();
      final vi = di - firstWindowIdx; // 視窗內索引
      if (vi < 0 || vi >= visible) continue;
      final label = '#${firstAbs + vi}';
      final tw = _textW(label, 8);
      _text(canvas, label,
          Offset((w * s / windowSeconds) - tw / 2, mainBottom - 12),
          Colors.grey.shade500, 8);
    }
  }

  /// 取 List 尾端可見段 → 算 baseline(中心化移動平均) → detrended
  /// (K2 版:原本是讀 ring buffer,改成從普通 List 的最後 visible 筆取)
  _ChData _buildChannel(
      List<int> src, int visible, Color color, String name) {
    final raw = List<int>.filled(visible, 0);
    final from = src.length - visible;
    for (int i = 0; i < visible; i++) {
      raw[i] = src[from + i];
    }
    // 先截尾去突波(同 HR-B),線才乾淨;再用截尾訊號去趨勢
    final rawD = List<double>.generate(visible, (i) => raw[i].toDouble());
    final trimmed = Max30102Signal.slidingTrimmedMean(rawD, trimWindow);
    final base = Max30102Signal.movingAverage(trimmed, baselineWindow);
    final detr = List<double>.generate(visible, (i) => trimmed[i] - base[i]);
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

  /// 谷↔谷 時間標記：相鄰波谷間畫平行線 + 間距數值（類似時間軸）。
  /// troughs=視窗索引(遞增)。K2 版只印數字不印單位(都是 ms,不必每格重複)。
  void _drawTroughIntervals(Canvas canvas, List<int> troughs, Color color,
      double yLine, int visible, double Function(int) xOfVisible,
      double msPerSample) {
    if (troughs.length < 2) return;
    final line = Paint()
      ..color = color.withValues(alpha: 0.7)
      ..strokeWidth = 1;
    for (int i = 1; i < troughs.length; i++) {
      final k1 = troughs[i - 1], k2 = troughs[i];
      if (k1 < 0 || k2 >= visible) continue;
      final x1 = xOfVisible(k1), x2 = xOfVisible(k2);
      canvas.drawLine(Offset(x1, yLine), Offset(x2, yLine), line);
      canvas.drawLine(Offset(x1, yLine - 3), Offset(x1, yLine + 3), line);
      canvas.drawLine(Offset(x2, yLine - 3), Offset(x2, yLine + 3), line);
      if (x2 - x1 > 20) {
        final ms = ((k2 - k1) * msPerSample).round().toString();
        _text(canvas, ms, Offset((x1 + x2) / 2 - _textW(ms, 8) / 2, yLine - 11),
            color, 8);
      }
    }
  }

  // (K2 版已移除 _drawAcStrip:AC 回血/供血折上帶不再顯示)

  // ---- helpers ----
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
      old.displaySamples != displaySamples ||
      old.windowSeconds != windowSeconds ||
      old.baselineWindow != baselineWindow ||
      old.trimWindow != trimWindow ||
      old.promRatio != promRatio ||
      old.showIr != showIr ||
      old.showRed != showRed ||
      old.fixedAmp != fixedAmp ||
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
