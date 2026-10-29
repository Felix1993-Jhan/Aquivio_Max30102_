// ============================================================================
// K2FixedWindow — 定長量測:只算「這次量測的前 N 秒」
// ============================================================================
// ★ 這一層不屬於交接內容,是我們自己驗證用的 UI 層。
//
// 為什麼需要:
//   畫面原本是滾動視窗,數字每秒都在變 —— 想回答「10 秒到底能給什麼」只能
//   靠存快照事後重算。這裡提供一個凍結的對照組:**固定一段資料,反覆比對**。
//
// 怎麼做(刻意不做狀態機):
//   從每次量測的**第一筆輸出樣本**開始,一直收前 cap 筆(預設 30 秒),滿了就
//   停止成長。開關只是切換畫面的資料來源 —— 所以「使用者何時按下開關」
//   完全不影響結果,中途才打開也拿得到完整的前 N 秒。
//
//   `view(N)` 是純函式 + memo:同樣的輸入回傳**同一個物件實例**,
//   既省掉每秒一次的 FFT,也讓「真的凍結了」變成可以被測試斷言的事實。
//
// ⚠️ 與已移除的「長期 RR 池(allPoints)」不是同一件事。那個池會跨量測累積,
//    把不同使用者的拍混在一起;這裡的緩衝**嚴格綁定一次量測**,下一次量測的
//    第一筆樣本進來就整個清掉。
//
// 時間軸(本專案 resetOnFingerOff = true,手指離開時核心絕對索引歸零,
//        無手指的空檔不前進 → 手指放上那一刻的絕對索引恆為 0):
//
//   abs 0 ────────── 150 ────────── 350 ──────── X ──────────▶
//       │  空轉 1.5s  │  沉澱 2.0s   │ 方向判定  │  正常輸出
//       │  核心丟棄   │ 只進核心緩衝 │ 壓著不送  │
//                                   └ _base     └ 第一批輸出的尾端
//
//   定長窗的 N 秒一律從 [_base] 起算 —— 那是「開始吐訊號」的那一刻。
//   空轉與沉澱兩段由 adapter 另外還原後塞進 [preIr](見 setPreRoll),
//   **只用來顯示,不進任何計算**。
// ============================================================================

import 'package:flutter/foundation.dart';

import '../k2_config.dart';
import '../k2_core.dart';
import '../k2_hrv_calculator.dart';
import '../k2_vitals_metrics.dart';

/// 波形圖上的時間區塊種類。這裡只給語意,顏色與文字由呈現層決定
/// (本檔不 import material,才能被純 Dart 測試直接使用)。
///
/// [gap] / [sqiBad] 是**問題點**(哪裡出問題就標在哪裡),疊在 [normal] 之上:
///   · [gap]    RR 空洞 —— 有一拍沒通過考驗、補漏拍也沒補回(= `confidence` 的空洞條件)
///   · [sqiBad] SQI 沒過的輪次(相鄰的合併成一塊)
enum K2HeadBand { dead, settle, orientWait, normal, gap, sqiBad }

/// 一次 `view(N)` 的完整結果。
typedef K2FixedView = ({
  // ── 計算用(只含定長窗內的資料)────────────────────────────────
  List<HrvRrPoint> pts,
  List<int> ir,
  List<int> red,
  HrvStats? hv,
  VitalsMetrics metrics,
  // ── 顯示用(含還原的開頭段;索引相對 chartIr[0])──────────────
  List<int> chartIr,
  List<int> chartRed,
  List<int> chartTroughs,
  List<({int from, int to, K2HeadBand kind})> bands,
  // ── 狀態 ────────────────────────────────────────────────────
  int base,
  int filledSamples,
  int needSamples,
  bool sealed,
  bool ended,
  int rebases,
  bool preMissing,
  int sqiOkRounds,
  int rounds,
  double? spo2,
  K2ChannelOrient orient,
});

/// 窗內每一輪的摘要。整輪的 [K2Compute] 不留(裡面有整個 RR 池,留 30 份太浪費),
/// 只留重算不出來的那幾個:SQI 是逐輪二元閘門、血氧與方向是逐輪值。
typedef _Round = ({int abs, bool sqiOk, double? spo2, K2ChannelOrient orient});

class K2FixedWindow extends ChangeNotifier {
  static const int _fs = Max30102Config.samplingRateHz;

  // ── 開頭緩衝 ──────────────────────────────────────────────────
  // ⚠️ 只 append,**永遠不從前面裁**。裁掉 [_base] 就與資料脫鉤了
  //    (這正是 waveIr 與它不同的地方:那個是滾動窗,這個是固定的開頭)。
  final List<int> _ir = [];
  final List<int> _red = [];

  /// `_ir[0]` 的絕對索引 = 核心第一筆輸出樣本 = 「開始吐訊號」那一刻。
  int _base = -1;

  /// 還原回來的空轉 + 沉澱段(由 adapter 從原始封包解出來後塞進來)。
  final List<int> _preIr = [];
  final List<int> _preRed = [];

  final List<HrvRrPoint> _pts = [];
  int _lastEndAbs = -1;

  /// 目前看過的最新樣本絕對位置。用來判斷「這一輪還在不在開頭窗裡」——
  /// 不可以拿 `_base + _ir.length` 代替:緩衝收滿之後它就不動了,
  /// 之後每一輪都會被誤認成還在窗內,把 SQI 的分母灌爆。
  int _lastAbs = -1;

  final List<_Round> _rounds = [];

  /// 第一批輸出的長度 —— 那一段就是「方向判定期」被壓著、鎖定時一次吐出的。
  int _firstBatchLen = 0;

  /// 本次量測已結束(確認手指離開)。**資料不清** —— 一鬆手就清掉的話,
  /// 連手動存快照都來不及按(確認離開只要約 0.3 秒)。
  bool _ended = false;

  /// 波形斷層導致重新起算的次數。>0 時畫面要標示,否則「第 0 秒」無法解釋。
  int _rebases = 0;

  int _cap = 0;
  int _deadSamples = 0;
  int _settleSamples = 0;

  /// 樣本**真的變長**時才 +1 → 凍結之後波形圖一次都不會重繪。
  /// 「畫面真的靜止」本身就是最直覺的凍結證明。
  final ValueNotifier<int> growVersion = ValueNotifier(0);

  // ── 唯讀狀態 ──────────────────────────────────────────────────
  int get base => _base;
  int get filledSamples => _ir.length;
  bool get ended => _ended;
  int get rebases => _rebases;
  bool get hasData => _ir.isNotEmpty;
  bool get preMissing => _preIr.isEmpty;
  List<HrvRrPoint> get points => List.unmodifiable(_pts);

  /// 還原回來的開頭段(空轉 + 沉澱)。**只用於顯示與完整存檔,不進計算。**
  List<int> get preIr => List.unmodifiable(_preIr);
  List<int> get preRed => List.unmodifiable(_preRed);

  /// 區塊邊界(存檔時一起寫下去,之後離線看圖才知道哪一段是哪一段)。
  int get deadSamples => _deadSamples;
  int get settleSamples => _settleSamples;

  /// 第一批輸出的長度 = 方向判定期被壓著、鎖定時一次吐出的那一段。
  int get firstBatchLen => _firstBatchLen;

  /// 開頭要還原幾筆。adapter 照這個數字回頭去原始緩衝撈,兩邊共用同一個定義。
  ///
  /// ⚠️ **不是固定的 `空轉 + 沉澱`**。核心是逐批判斷的:空轉期的條件是
  /// 「累計樣本 ≤ fingerDeadSamples」、沉澱期是「緩衝 < settleSamples」,
  /// 兩者都在**批次邊界**上才會翻,所以實際的零點會落在標稱值附近而不是正中。
  /// （實機一批約 10 筆 → 很接近 350;測試用 24 筆/批 → 336。）
  /// 既然 [_base] 就是核心親口說的第一筆輸出位置,直接用它最準。
  int get expectedPreSamples =>
      _base >= 0 ? _base : _deadSamples + _settleSamples;

  // ══════════════════════════════════════════════════════════════
  // 進料
  // ══════════════════════════════════════════════════════════════

  /// 每收到一個封包就呼叫一次(不論核心有沒有輸出樣本或算出結果)。
  ///
  /// ⚠️ 不可以只在「有樣本」或「有 computed」時才呼叫 —— [didReset] 與
  ///    [computed] 是兩條獨立的資訊,少接一條就會漏掉量測結束或漏掉拍。
  void feed({
    required int firstAbs,
    required List<int> newIr,
    required List<int> newRed,
    required K2Compute? computed,
    required bool didReset,
    required int cap,
    required int deadSamples,
    required int settleSamples,
  }) {
    _cap = cap;
    _deadSamples = deadSamples;
    _settleSamples = settleSamples;

    if (didReset) {
      // 量測結束。資料留著讓人看、讓人存快照,只標記狀態。
      if (!_ended && _ir.isNotEmpty) {
        _ended = true;
        notifyListeners();
      }
      return;
    }

    // 上一次量測已結束,而新的樣本開始進來 → 這是下一位使用者,現在才清。
    if (_ended && newIr.isNotEmpty) {
      hardClear();
    }

    var grew = false;

    if (newIr.isNotEmpty) {
      _lastAbs = firstAbs + newIr.length;
      if (_ir.isEmpty) {
        _base = firstAbs;
        _firstBatchLen = newIr.length;
      } else if (firstAbs != _base + _ir.length) {
        // 斷層。**不可以照 waveIr 那樣「清空並以新 firstAbs 重設」就算了** ——
        // 那裡是滾動窗,起點本來就會動;這裡的語意是「某個固定零點之後的前 N 秒」,
        // 零點挪了就不是同一段時間,必須整段作廢並明確記錄,否則第 0 秒無法解釋。
        //
        // 已經收滿的話就不理會:那是一段完整的開頭,之後的斷層與它無關。
        if (_ir.length < _cap) {
          _ir.clear();
          _red.clear();
          _pts.clear();
          _rounds.clear();
          _lastEndAbs = -1;
          _preIr.clear();
          _preRed.clear();
          _base = firstAbs;
          _firstBatchLen = newIr.length;
          _rebases++;
        }
      }

      if (_ir.length < _cap) {
        final room = _cap - _ir.length;
        final take = newIr.length < room ? newIr.length : room;
        for (int i = 0; i < take; i++) {
          _ir.add(newIr[i]);
          _red.add(newRed[i]);
        }
        grew = take > 0;
      }
    }

    final c = computed;
    if (c != null && _base >= 0) {
      final end = _base + _cap;
      for (final p in c.rrPoints) {
        // 沉澱期那 200 筆仍在核心緩衝裡參與找谷,所以第一輪會有早於 _base 的拍。
        // 不濾掉的話,窗頭會多出沒有波形對應的拍,左欄拍數與波形標點就對不起來。
        if (p.startAbs < _base) continue;
        if (p.endAbs > end) continue;
        if (p.endAbs <= _lastEndAbs) continue; // 相鄰兩輪高度重疊,靠 endAbs 去重
        _pts.add(p);
        _lastEndAbs = p.endAbs;
      }
      // 只記開頭窗以內的輪次。窗滿之後就停止 —— 否則之後每一輪都會被算進
      // SQI 的多數票裡,凍結的數字會繼續被窗外的資料改寫。
      if (c.fingerPresent &&
          !c.settling &&
          _ir.isNotEmpty &&
          _lastAbs >= 0 &&
          _lastAbs <= end) {
        _rounds.add((
          abs: _lastAbs,
          sqiOk: c.sqiOk,
          spo2: c.spo2,
          orient: c.orient,
        ));
      }
    }

    if (grew) {
      growVersion.value++;
      notifyListeners();
    }
  }

  /// adapter 從原始封包還原出來的「空轉 + 沉澱」段。**只用來顯示。**
  /// 長度應為 [deadSamples] + [settleSamples];取不到就不要呼叫(畫面會標示未還原)。
  void setPreRoll(List<int> ir, List<int> red) {
    if (ir.isEmpty || _preIr.isNotEmpty) return;
    _preIr.addAll(ir);
    _preRed.addAll(red);
    growVersion.value++;
    notifyListeners();
  }

  /// 整個歸零(手動「清除」按鈕,或下一次量測開始)。
  void hardClear() {
    _ir.clear();
    _red.clear();
    _preIr.clear();
    _preRed.clear();
    _pts.clear();
    _rounds.clear();
    _base = -1;
    _lastEndAbs = -1;
    _lastAbs = -1;
    _firstBatchLen = 0;
    _ended = false;
    _rebases = 0;
    _memoKey = null;
    _memo = null;
    growVersion.value++;
    notifyListeners();
  }

  // ══════════════════════════════════════════════════════════════
  // 取用:切出前 N 秒並重算
  // ══════════════════════════════════════════════════════════════

  String? _memoKey;
  K2FixedView? _memo;

  /// 切出「本次量測的前 [seconds] 秒」並重算所有衍生數值。
  ///
  /// 沒有任何資料時回 null(畫面顯示「等待資料」)。
  ///
  /// **memo**:輸入沒變就回傳**同一個物件實例** —— 凍結之後每秒一次的
  /// Lomb-Scargle 與 4096 點 FFT 全部省掉,而且物件 identity 不變本身
  /// 就是測試可以斷言的「真的凍結了」。
  K2FixedView? view(int seconds) {
    if (_ir.isEmpty || _base < 0) return null;
    final key = '$seconds/${_ir.length}/${_pts.length}/${_preIr.length}'
        '/${_rounds.length}/$_ended/$_rebases';
    if (key == _memoKey) return _memo;

    final need = seconds * _fs;
    final endAbs = _base + need;

    final pts = [
      for (final p in _pts)
        if (p.endAbs <= endAbs) p,
    ];
    final take = _ir.length < need ? _ir.length : need;
    final ir = _ir.sublist(0, take);
    final red = _red.sublist(0, take);

    final hv = pts.isEmpty ? null : Max30102HrvCalculator.hrvFrom(pts);

    // 窗內的輪次:SQI 取多數票,血氧/方向取窗內最後一輪。
    // 為什麼不是「最後一輪」或「全部 AND」:一輪壞運氣不該代表整段,
    // 28 輪裡 1 輪不過就歸零又太嚴。多數票 + 旁邊公開比例,讓人自己判斷。
    final inWin = [
      for (final r in _rounds)
        if (r.abs <= endAbs) r,
    ];
    final okRounds = inWin.where((r) => r.sqiOk).length;
    final sqiOk = inWin.isNotEmpty && okRounds * 2 >= inWin.length;

    final metrics = Max30102VitalsMetrics.compute(
      pts: pts,
      hv: hv,
      sqiOk: sqiOk,
      // 窗內的樣本按定義全在沉澱期之後(核心沉澱期根本不輸出),
      // 傳 true 在邏輯上不可能發生。
      settling: false,
      // ⚠️ 用 hv.meanHr 而不是即時的 bpm:bpm 是「最近 6 拍中位」的滾動值,
      //    拿它去算一個凍結的 snr_db,會讓凍結的數字跟著即時心率飄。
      bpm: hv?.meanHr,
      ir: ir,
    );

    // 谷標點直接由 pts 的端點導出,不另存一份 —— 保證「標在圖上的點」與
    // 「算進數字的拍」永遠同源。
    final preLen = _preIr.length;
    final marks = <int>{};
    for (final p in pts) {
      marks.add(p.startAbs - _base + preLen);
      marks.add(p.endAbs - _base + preLen);
    }
    final troughs = marks.toList()..sort();

    final chartIr = [..._preIr, ...ir];
    final chartRed = [..._preRed, ...red];

    final bands = <({int from, int to, K2HeadBand kind})>[];
    if (preLen > 0) {
      // 還原段的長度理論上 = 空轉 + 沉澱;若少了一截(緩衝不夠深)就按比例收尾,
      // 寧可少畫一段,也不要畫一條對不上的分界線。
      final dead = _deadSamples < preLen ? _deadSamples : preLen;
      if (dead > 0) bands.add((from: 0, to: dead, kind: K2HeadBand.dead));
      if (preLen > dead) {
        bands.add((from: dead, to: preLen, kind: K2HeadBand.settle));
      }
    }
    final orientEnd = preLen + (_firstBatchLen < take ? _firstBatchLen : take);
    if (orientEnd > preLen) {
      bands.add((from: preLen, to: orientEnd, kind: K2HeadBand.orientWait));
    }
    if (chartIr.length > orientEnd) {
      bands.add((
        from: orientEnd,
        to: chartIr.length,
        kind: K2HeadBand.normal,
      ));
    }

    // ── 問題點:哪裡出問題就標在哪裡 ────────────────────────────────
    // 加在 normal 之後 → 畫在它上面。位置換算與谷標點同一套(abs − base + preLen)。
    int idx(int abs) => abs - _base + preLen;

    // SQI 沒過的輪次。每輪涵蓋「上一輪結尾 → 這一輪結尾」,相鄰的合併成一塊。
    int prevAbs = _base;
    int? badFrom;
    for (final r in inWin) {
      if (!r.sqiOk) {
        badFrom ??= prevAbs < _base ? _base : prevAbs;
      } else if (badFrom != null) {
        bands.add((
          from: idx(badFrom),
          to: idx(prevAbs),
          kind: K2HeadBand.sqiBad,
        ));
        badFrom = null;
      }
      prevAbs = r.abs;
    }
    if (badFrom != null) {
      bands.add((
        from: idx(badFrom),
        to: idx(prevAbs),
        kind: K2HeadBand.sqiBad,
      ));
    }

    // RR 空洞:前一拍終谷 → 後一拍起谷。判定與 Max30102VitalsMetrics.rrGaps()
    // 完全相同(同一份 pts),所以畫出幾塊 = confidence 數到幾個。
    for (int i = 0; i + 1 < pts.length; i++) {
      if (pts[i + 1].startAbs != pts[i].endAbs) {
        bands.add((
          from: idx(pts[i].endAbs),
          to: idx(pts[i + 1].startAbs),
          kind: K2HeadBand.gap,
        ));
      }
    }

    final v = (
      pts: pts,
      ir: ir,
      red: red,
      hv: hv,
      metrics: metrics,
      chartIr: chartIr,
      chartRed: chartRed,
      chartTroughs: troughs,
      bands: bands,
      base: _base,
      filledSamples: _ir.length,
      needSamples: need,
      sealed: _ir.length >= need,
      ended: _ended,
      rebases: _rebases,
      preMissing: preLen == 0,
      sqiOkRounds: okRounds,
      rounds: inWin.length,
      spo2: inWin.isEmpty ? null : inWin.last.spo2,
      orient: inWin.isEmpty ? K2ChannelOrient.unknown : inWin.last.orient,
    );
    _memoKey = key;
    _memo = v;
    return v;
  }

  @override
  void dispose() {
    growVersion.dispose();
    super.dispose();
  }
}
