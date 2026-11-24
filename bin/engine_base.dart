// ============================================================================
// VitalsEngine —— 兩種計算模式(即時 / 固定 30 秒)共用的引擎骨架
// ============================================================================
// 這裡只放「與計算時機無關」的部分:波形累積、WS 推送通道、晶片休眠旗標。
// 各模式自己的核心與 JSON 輸出在 engine_realtime.dart / engine_fixed30.dart。
//
// (0.0.1-fixed30s 從原本的 K2Engine 原封抽出,行為不變。)
// ============================================================================

part of 'max30102_server.dart';

abstract class VitalsEngine {
  VitalsEngine({int waveSeconds = 30}) : _waveCap = waveSeconds * kFs;

  /// 計算模式名稱(`/health` 與 vitals 的 `calcMode` 欄位)。
  String get calcMode;

  /// 本次量測的絕對位置基準。
  int get totalSamples;

  /// 核心的可調參數(`GET /chip` 拿來比對 LED 電流)。
  Max30102Config get config;

  /// 餵一個 MCU 原始封包。回傳這次有沒有算出新結果。
  bool feedPacket(List<int> packet);

  /// `/vitals` 與 `/stream` 共用的輸出(見各模式的實作)。
  Map<String, dynamic> vitalsJson();

  /// 重置:核心 + 波形都清乾淨。切換進料來源時一定要呼叫。
  void reset();

  /// 晶片指令(`/chip/init`、`/chip/reset`、`/chip/reset-init`)成功之後呼叫。
  /// [initialized] = 這次指令包含 init(晶片重新開始採樣)。
  void afterChipCommand({required bool initialized});

  /// 波形保留上限(筆)。超過就從頭裁掉。
  final int _waveCap;

  // 原始樣本
  final List<int> _waveIr = [];
  final List<int> _waveRed = [];

  /// `_waveIr[0]` 的**絕對樣本位置**。上層靠它把波形對齊到 troughAbs / rrPoints。
  int _waveBase = 0;

  // 畫圖用的處理後 IR —— 核心算好的 K2FeedResult.newIrWave / newIrWaveTrim,原封轉送。
  //
  // ⚠️ 不再用 newIrTrim(v0.0.0.7 起)。那是每批一到就算的截尾值,批尾 4 筆的右側
  //    是截斷的,送出去就凍住;站台照著畫,每 0.1 秒左右會出現一個小缺口。
  //    newIrWave 是核心等線定下來(落後約 1.5 秒)才給的,就是核心找谷用的那條線
  //    (Max30102Signal.troughLine:截尾 → 0.7~3.5 Hz 帶通,v0.0.0.8)。server 不再自己算。
  //
  // 落後原始樣本約 1.5 秒,所以有自己的起點 [_detBase],不與 [_waveBase] 共用。
  final List<double> _det = []; // 找谷用的線:截尾 → 帶通(→ WS `wave`)
  final List<double> _detTrim = []; // 截尾、帶 DC(→ WS `raw_wave`)
  int _detBase = 0;

  /// 推給 WS 訂閱者的通道。
  final StreamController<Map<String, dynamic>> _vitals =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get vitalsStream => _vitals.stream;

  /// 晶片休眠中(`POST /chip/reset` 送出後、下一次 init 成功前)。
  ///
  /// 這段期間 [feedPacket] **丟棄所有 FIFO 資料**,`fingerPresent` 因此固定是 false。
  ///
  /// 為什麼要擋(v0.0.0.9):整合方回報 reset 關燈後,**沒放手指**的感測器也回報
  /// `fingerPresent: true`,而且一直停在 true。實際經過(2026-11-04 實測):
  ///   ① 韌體收到 RESET **不清 MCU 緩衝**,reset 後第一次 QUERY_FIFO 還會拿到
  ///      reset 前留下的樣本(實測 24 筆)。
  ///   ② 舊版在 `engine.reset()` 之後把這批舊樣本餵進核心;當時核心 reset 後的
  ///      去彈跳計數是 0,前兩批沒手指的資料被當成「有手指、空轉期」→ true
  ///      (核心已另外修正,見 `_noFingerBatches`)。
  ///   ③ 之後晶片休眠、FIFO 一直是空的 → 核心不再計算 → `/stream` 不再推送,
  ///      對方就停在那一筆 true。
  /// 關燈時本來就沒有光可以偵測手指,這段期間的資料一筆都不該進判斷。
  ///
  /// 由 [SerialSource.resetChip] 設 true、[SerialSource.initChip] 成功後設 false
  /// (含開串口時的自動 init);切換進料模式時也清掉(見 `_handleMode`)。
  /// feed 模式(0.0.1-fixed30s 起):收到 `/chip/reset` 就設 true、`/chip/init` 設 false ——
  /// server 不知道上層有沒有真的送出,一律當作送出了(見 `_handleChipCommand`)。
  bool chipAsleep = false;

  /// 立刻推一筆現況給 WS 訂閱者(不等下一次計算)。
  void pushVitals() {
    if (!_vitals.isClosed) _vitals.add(vitalsJson());
  }

  /// 把核心這次交出的樣本接進波形緩衝(原始 + 處理後兩條)。
  void _absorbWave(K2FeedResult r) {
    // 核心自行清空過(絕對索引到頂 / 免洗歸零)→ 我們存的波形與 base 全部作廢。
    if (r.didReset) _clearWave();

    if (r.newIr.isNotEmpty) {
      // ⚠️ 核心在空轉期/沉澱期會**丟棄樣本**,所以 firstAbs 不保證等於
      //    「上一批結尾 + 1」。對不上就整段重接,不要硬接 —— 硬接會讓波形
      //    索引與 troughAbs 錯開,而且錯得很安靜。
      final expected = _waveBase + _waveIr.length;
      if (_waveIr.isEmpty || r.firstAbs != expected) {
        _clearWave();
        _waveBase = r.firstAbs;
      }
      _waveIr.addAll(r.newIr);
      _waveRed.addAll(r.newRed);

      final over = _waveIr.length - _waveCap;
      if (over > 0) {
        _waveIr.removeRange(0, over);
        _waveRed.removeRange(0, over);
        _waveBase += over; // 裁掉幾筆,base 就往前推幾筆
      }
    }

    // 處理後波形:與原始樣本同樣的接法 —— 對不上就整段重接,不硬接。
    if (r.newIrWave.isNotEmpty) {
      if (_det.isEmpty || r.waveFirstAbs != _detBase + _det.length) {
        _det.clear();
        _detTrim.clear();
        _detBase = r.waveFirstAbs;
      }
      _det.addAll(r.newIrWave);
      _detTrim.addAll(r.newIrWaveTrim);
      final over = _det.length - _waveCap;
      if (over > 0) {
        _det.removeRange(0, over);
        _detTrim.removeRange(0, over);
        _detBase += over;
      }
    }
  }

  void _clearWave() {
    _waveIr.clear();
    _waveRed.clear();
    _waveBase = 0;
    _det.clear();
    _detTrim.clear();
    _detBase = 0;
  }

  /// 近一段波形。[seconds] 為 null → 給出全部保留的長度。
  ///
  /// `firstAbs` 是回傳陣列第 0 筆的絕對位置 —— 上層要把波形跟 `troughAbs`
  /// 對齊就靠它:`陣列索引 = abs - firstAbs`。
  ///
  /// 四個陣列**逐筆對應、等長**:
  ///   · `ir` / `red`         —— 感測器原始讀值
  ///   · `irTrim` / `redTrim` —— 截尾平滑後的值(還帶著 DC)
  /// 兩組都給,由呈現層自己選(與核心 K2FeedResult 的做法一致)。
  ///
  /// trim 是在**回應的當下**對整段保留的原始值重算的(與核心同一支
  /// [Max30102Signal.slidingTrimmedMean]),不是存下核心逐批給的 newIrTrim ——
  /// 那個每批尾端 4 筆的右側是截斷的。整段重算之後,只剩陣列**最後 4 筆**
  /// 還沒有右邊的資料,那是「現在」本來就沒有未來,不是錯。
  Map<String, dynamic> waveformJson({int? seconds}) {
    var from = 0;
    if (seconds != null && seconds > 0) {
      final want = seconds * kFs;
      if (_waveIr.length > want) from = _waveIr.length - want;
    }
    // 平滑值取一位小數就夠 —— IR 讀值是 ~90000 的量級,更多位數只是把
    // JSON 撐大(未修剪的 double 一筆可以長到 18 個字元)。
    List<double> trim1(List<int> v) => [
      for (final x in Max30102Signal.slidingTrimmedMean(
        [for (final s in v) s.toDouble()],
        Max30102Config.trimWindow,
      ).sublist(from))
        (x * 10).roundToDouble() / 10,
    ];
    return {
      'firstAbs': _waveBase + from,
      'fs': kFs,
      'count': _waveIr.length - from,
      'ir': _waveIr.sublist(from),
      'red': _waveRed.sublist(from),
      'irTrim': trim1(_waveIr),
      'redTrim': trim1(_waveRed),
    };
  }

  /// WS `/stream` 用的**增量**波形。回傳兩個區塊:
  ///
  ///   · `wave`     —— **核心找谷用的那條線,畫圖直接用這個**:截尾 → 0.7~3.5 Hz 帶通
  ///                   (v0.0.0.8)。= 核心的 K2FeedResult.newIrWave,原封轉送。
  ///   · `raw_wave` —— 截尾平滑後、**還帶著 DC** 的值(舊版 `wave` 的內容)。
  ///                   = 核心的 newIrWaveTrim。除錯與看灌流用。
  ///
  /// 兩者都由核心等線定下來才給(落後約 1.5 秒;帶通是 IIR,最新那段每多一筆資料就會變),
  /// 核心也只收這之前的谷 —— 與核心找谷用的是同一條線(Max30102Signal.troughLine)。
  /// server 不再自己延遲、自己算(v0.0.0.6 以前是在這裡算的,截尾那一步用了
  /// 核心逐批給的 newIrTrim,批尾 4 筆的右側是截斷的)。
  ///
  /// 為什麼要分兩個:DC 漂移是脈搏的 20~50 倍(實測漂移 5000~7100、脈搏 rms
  /// 只有 143~269)。直接畫帶 DC 的值,脈搏只佔畫面 3~10%,形狀完全看不出來 ——
  /// 那正是整合方回報「波形很醜」的成因,不是感測器的問題。
  ///
  /// 為什麼是「IR + trim」而不是四條線都送:
  ///   · **IR** —— 心跳本身就是從這一路算出來的。手指偵測看 IR DC,谷點偵測
  ///     (`irTroughs`)跑在 IR 上,RED 只在算 SpO2 的 ratio 時才用到。畫 IR
  ///     等於畫「演算法看到的那條線」,畫面上的谷就是我們數的拍。
  ///   · **trim** —— 截尾滑動平均(去突波)。核心的主計算本來就跑在 trim 上
  ///     (見 k2_algorithm「殺掉尖刺型假谷」),raw 上那些尖刺是我們**判定為
  ///     雜訊而不採信**的東西。送 trim 不是美化,是與計算一致。
  /// 想要 RED 或未平滑的原始值就走 `GET /waveform`,那邊四條線照舊全給。
  ///
  /// [fromAbs] = 呼叫端**上次收到的下一筆**絕對位置;null = 沒收過。
  /// 遊標落在保留範圍外時**整段重送**,不硬接 —— 有兩種情況會這樣:
  ///   · 免洗歸零(下一位使用者)→ base 掉回 0,遊標比 nextAbs 還大
  ///   · 訂閱者太久沒收 / 剛接上 → 要的樣本已經被 `_waveCap` 裁掉了
  /// 兩種都是「接不上」,硬接會讓波形與 `troughAbs` 錯開,而且錯得很安靜。
  ({Map<String, dynamic> wave, Map<String, dynamic> rawWave}) waveSinceJson(
      int? fromAbs) {
    // 核心給的就已經是「前後文完整」的那段,不必再壓著。
    final nextAbs = _detBase + _det.length;
    final from = (fromAbs == null || fromAbs < _detBase || fromAbs > nextAbs)
        ? _detBase
        : fromAbs;
    final lo = from - _detBase;
    final hi = nextAbs - _detBase;

    // 一位小數就夠 —— IR 讀值是 ~90000 的量級(與 waveformJson 同樣的理由)。
    double r1(double x) => (x * 10).roundToDouble() / 10;

    if (hi <= lo) {
      final empty = {
        'firstAbs': from,
        'fs': kFs,
        'count': 0,
        'irTrim': const <double>[],
      };
      return (wave: Map.of(empty), rawWave: Map.of(empty));
    }

    final det = [for (int i = lo; i < hi; i++) r1(_det[i])];
    final raw = [for (int i = lo; i < hi; i++) r1(_detTrim[i])];
    return (
      wave: {
        'firstAbs': from,
        'fs': kFs,
        'count': det.length,
        'irTrim': det,
      },
      rawWave: {
        'firstAbs': from,
        'fs': kFs,
        'count': raw.length,
        'irTrim': raw,
      },
    );
  }

  /// HRV 區塊(兩種模式同一份格式)。
  static Map<String, dynamic>? _hrvJson(HrvStats? hv) => hv == null
      ? null
      : {
          'sdnn': hv.sdnn,
          'rmssd': hv.rmssd,
          'pnn50': hv.pnn50,
          'sd1': hv.sd1,
          'sd2': hv.sd2,
          'meanRr': hv.meanRr,
          'meanHr': hv.meanHr,
          'hrvScore': hv.hrvScore,
          'beats': hv.beats,
        };

  Future<void> dispose() async {
    await _vitals.close();
  }
}
