// ============================================================================
// K2BreathHold — 憋氣血氧變化記錄器(UI 層,有狀態)
// ============================================================================
// 回答的問題:**血氧掉下去的時候,兩片模組還會不會給出一樣的數字?**
//
// 為什麼需要這個實驗:血氧的校正曲線是綁定波長的(假設紅光 660nm、紅外 880nm)。
// 仿製模組若用了波長偏掉的 LED,R 值會系統性偏移,而公式照舊算 —— 血氧穩定地
// 偏掉幾個百分點,看起來完全正常、沒有任何異常徵兆。**那是安靜的錯。**
//
// 而在 99% 附近**看不出來**,因為曲線在頂端很平:
// ```
//   斜率 dSpO2/dR = -90.12 R + 30.354
//   R = 0.42(靜坐時的位置)  →  -7.5  %/單位R
//   R = 1.00(血氧 80% 附近)  →  -59.8 %/單位R
// ```
// 靈敏度差 8 倍。兩把尺在 0 刻度對齊,不代表 30 公分處也對齊 ——
// 所以要**把血氧壓下去**,才分得出兩片板子有沒有差。
//
// ── 為什麼放在 ui/ 而不是核心 ─────────────────────────────────────
//   與 [K2LfExperiment] 同一個理由:「累積一整段」是有狀態的事,核心的設計
//   原則是不存歷史、不開 Timer、記憶體有界。憋氣週期(基線→憋→恢復)動輒
//   一兩分鐘,遠超過核心的 30 秒視窗。
//
// ── 兩次錄製可以疊圖 ──────────────────────────────────────────────
//   這是移植時特地加的。實驗的目的就是**比對兩片板子**,一次只看一條線
//   等於還要自己記上一次的數字。停止時把該次移到「上一次」,下一次錄的
//   會疊在同一張圖上 —— 同一個人、同一段時間軸,差異就只剩硬體。
//
// ⚠️ 本專案開了 resetOnFingerOff:錄製中手指離開 → 核心連絕對索引一起歸零。
//    那會讓時間軸接不起來,所以偵測到就**中止**並說明原因,不默默續接。
// ============================================================================

import 'package:flutter/foundation.dart';

import '../k2_config.dart';

/// 一個取樣點:經過秒數 + 原始血氧 + 平滑後血氧。
typedef BreathHoldPoint = ({double t, double raw, double smooth});

/// 一次完整的錄製。
class BreathHoldRun {
  final List<BreathHoldPoint> points;

  /// 「恢復呼吸」標記的經過秒數;null = 沒標。
  final double? resumeT;

  /// 這次錄製時的通道方向,用來在圖上區分是哪一片板子量的。
  final String orientLabel;

  const BreathHoldRun({
    required this.points,
    required this.resumeT,
    required this.orientLabel,
  });
}

/// 憋氣記錄器。由 `K2SerialAdapter` 持有,每次核心算出新結果就 [feed] 一次。
class K2BreathHold extends ChangeNotifier {
  static const int _maxPoints = 1800; // 上限保險(約 30 分鐘 @1Hz)

  bool _active = false;
  int _startTotal = 0;
  int _lastTotal = 0;
  double? _ema;
  final List<BreathHoldPoint> _points = [];
  double? _resumeT;
  String _orientLabel = '';

  /// 上一次錄製 —— 疊在圖上當對照(換一片板子再錄一次就能直接比)。
  BreathHoldRun? _previous;

  /// 中止原因(手指離開造成核心歸零)。null = 沒中止。
  String? _abortReason;

  /// **重繪用的版本號 —— 每次有變化就 +1。**
  ///
  /// ⚠️ 圖表的 `shouldRepaint` **不可以拿 `points.length` 當判準**:
  ///    [points] 回傳的是同一個 list 物件,painter 裡的 `old.points` 與
  ///    `points` 指向同一份資料 → 長度永遠相等 → 判定「沒變化」→ 畫面凍住。
  ///    (`k2_serial_adapter` 的 sampleVersionNotifier 是同一個理由。)
  int _version = 0;
  int get version => _version;

  void _bump() {
    _version++;
    notifyListeners();
  }

  bool get active => _active;
  List<BreathHoldPoint> get points => _points;
  double? get resumeT => _resumeT;
  BreathHoldRun? get previous => _previous;
  String? get abortReason => _abortReason;
  String get orientLabel => _orientLabel;

  /// **錄了多久(秒)—— 跟著真實時間走,不是跟著點數走。**
  ///
  /// 兩者會不一樣:血氧算不出來的時候(方向還在判定、SQI 掉了、手指沒壓好)
  /// 不會記點,但時間照樣在過。若拿最後一點的 t 當經過時間,畫面會**看起來凍住**
  /// —— 而使用者正在等它動,那種凍住分不出是「沒訊號」還是「程式壞了」。
  double get elapsedSec => _elapsed;
  double _elapsed = 0;

  /// 開始錄製。[orientLabel] 建議帶通道方向,之後圖上分得出哪條線是哪片板。
  ///
  /// 上一次的資料在**這裡**才搬進對照組,不是在 [stop] ——
  /// 在 stop 搬的話,剛錄完那一刻「目前」與「上一次」是同一份資料,
  /// 圖上會有兩條完全重疊的線,還多一個看不懂的「上一次」圖例。
  void start(int totalSamples, {String orientLabel = ''}) {
    if (_points.isNotEmpty) {
      _previous = BreathHoldRun(
        points: List<BreathHoldPoint>.of(_points),
        resumeT: _resumeT,
        orientLabel: _orientLabel,
      );
    }
    _active = true;
    _points.clear();
    _resumeT = null;
    _ema = null;
    _abortReason = null;
    _startTotal = totalSamples;
    _lastTotal = totalSamples;
    _elapsed = 0;
    _orientLabel = orientLabel;
    _bump();
  }

  /// 標記「開始恢復呼吸」的時刻。**不停止錄製** —— 恢復過程本身也要記,
  /// 因為「掉多深」和「多久回得來」是兩個獨立的觀察值。
  void markResume(int totalSamples) {
    if (!_active || _resumeT != null) return;
    _resumeT = (totalSamples - _startTotal) / Max30102Config.samplingRateHz;
    _bump();
  }

  /// 停止錄製。**資料留著** —— 剛錄完就是要看它。
  /// 搬進對照組是下一次 [start] 的事。
  void stop() {
    _active = false;
    _bump();
  }

  /// 清掉全部(含對照組)。
  void clear() {
    _active = false;
    _points.clear();
    _previous = null;
    _resumeT = null;
    _abortReason = null;
    _ema = null;
    _elapsed = 0;
    _bump();
  }

  /// 餵一次計算結果。[spo2] 為 null(方向未定 / 算不出)時**跳過不記**,
  /// 不要補 0 或沿用舊值 —— 那會在曲線上造一段假的平台。
  void feed(double? spo2, bool fingerPresent, int totalSamples) {
    if (!_active) return;

    // ⚠️ 免洗歸零:核心把絕對索引清成 0 了 → 時間軸接不起來。
    //    續接會得到一條橫跨兩次量測的曲線,而且不會報錯。
    if (totalSamples < _lastTotal) {
      _abortReason = 'reset';
      _active = false;
      _bump();
      return;
    }
    _lastTotal = totalSamples;

    // 時間**先推進**,再決定要不要記點 —— 這樣血氧算不出來的那幾秒,
    // 畫面上的時間軸照樣在走,使用者看得出「程式活著,只是沒訊號」。
    final t = (totalSamples - _startTotal) / Max30102Config.samplingRateHz;
    final moved = t > _elapsed;
    _elapsed = t;

    if (!fingerPresent || spo2 == null || spo2 <= 0) {
      if (moved) _bump();
      return;
    }

    // EMA 平滑 —— 核心一律吐原始值,平滑是呈現層的事(見 k2_config 的說明)。
    // 兩條線都畫:粗線看趨勢,細線看即時真值,不要只留一條。
    final k = Max30102Config().spo2SmoothFactor;
    _ema = _ema == null ? spo2 : (k * _ema! + (1 - k) * spo2);

    // ⚠️ 滿了就**停止追加,不裁掉開頭**。
    //    開頭那幾點是基線(圖上的「降幅」就是拿前 5 點的平均當基準),
    //    從前面裁掉會讓基線悄悄變成「憋氣中的某個值」→ 降幅算出來偏小,
    //    而且不會有任何錯誤訊息。1800 點 @1Hz 是 30 分鐘,實務上到不了。
    if (_points.length >= _maxPoints) return;

    _points.add((t: t, raw: spo2, smooth: _ema!));
    _bump();
  }
}
