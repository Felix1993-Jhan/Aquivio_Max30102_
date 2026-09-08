// ============================================================================
// Max30102K2 — 控制層(交接用核心)
// ============================================================================
// 三層架構裡的「控制層」:上接軟體(UI 層)、下叫基礎層。
//
//   UI 層 / 軟體  ──feedData(封包)──▶  【本檔 Max30102K2】 ──▶ 基礎層
//                 ◀──原始數值(getter)──                      (signal/algorithm/
//                                                             sqi/beatseries/hrv)
//
// 設計原則(交接考量):
//   ① **不碰串口、不開 Timer**:資料何時收、多久算一次,由軟體決定。
//      軟體每次收到 MCU 回應就丟進 feedData();本檔自己累積,湊滿才算。
//   ② **只吐原始值**:不做 EMA 平滑、不做 hold/凍結、不組 log —— 那些是呈現層的事。
//   ③ **記憶體有界**:樣本緩衝與 RR 池共用 config.dataHistoryMs(預設 30 秒),永不成長。
//      要畫更長的波形 / 存更長的 RR → 軟體自己累積 feedData 回傳的東西。
//
// 典型用法(軟體端):
// ```dart
// final k2 = Max30102K2();
// // 軟體自己的計時器，每 100ms 跟 MCU 要一次資料：
// final r = k2.feedData(mcuResponseBytes);   // 原封丟進來，驗框/拆包我們做
// myChartIr.addAll(r.newIr);                 // 想畫圖就自己接（長度自己決定）
// if (r.computed != null) {                  // 約每秒一次才會非 null
//   print(r.computed!.bpm);
//   print(r.computed!.hrv?.rmssd);
// }
// ```
// ============================================================================

import 'dart:typed_data';

import 'k2_algorithm.dart';
import 'k2_beatseries.dart';
import 'k2_config.dart';
import 'k2_hrv_calculator.dart';
import 'k2_protocol.dart';
import 'k2_setting_limits.dart';
import 'k2_signal.dart';

/// 一次計算的產物(全部是「原始值」,未做任何顯示平滑)。
/// FIFO 兩個資料槽與實際光源的對應關係。
///
/// datasheet 規定:`0x0C` = LED1 = **紅光**、FIFO 每組 6 bytes 是 RED 在前 IR 在後。
/// 我們的解碼完全照規格 —— 但市面上有模組**把兩顆 LED 晶粒裝反**,那種板子送出來
/// 的兩路就是對調的(專案文件「已知硬體問題」有完整的查證過程與目視檢驗法)。
///
/// 所以核心不預設相信標籤,而是每次量測**自己判定一次**(見
/// [Max30102Config.orientRatioNormal])。判定完成前不輸出樣本 —— 理由與沉澱期
/// 相同:寧可晚兩秒,也不要送出貼錯標籤的資料。
enum K2ChannelOrient {
  /// 還在判定中。此時**不輸出樣本、不給血氧**(心率照給)。
  unknown,

  /// 符合 datasheet:第 1 槽 = 紅光、第 2 槽 = 紅外。
  normal,

  /// 與 datasheet 相反:第 1 槽 = 紅外、第 2 槽 = 紅光。模組把晶粒裝反了。
  swapped,
}

class K2Compute {
  /// 是否偵測到手指(IR 平均 ≥ fingerThreshold)。
  final bool fingerPresent;

  /// 這次量測判定出來的通道方向。
  ///
  /// [K2ChannelOrient.swapped] 代表手上這片模組把兩顆 LED 裝反了 ——
  /// 核心**已經在輸出裡把它轉正**(`newIr` / `newRed` 都是實際的光源),
  /// 這個欄位只是讓上層知道發生過什麼、可以記錄或警示。
  final K2ChannelOrient orient;

  /// 這一輪訊號品質是否過關(cv + spike)。false → 這輪的谷不進 NN 序列。
  final bool sqiOk;

  /// **沉澱中** —— 手指已偵測到,但乾淨資料還沒湊滿 `config.settleSamples`
  /// (預設 200 筆 = 2 秒 = baseline 視窗寬)。此時所有數值皆為 null。
  /// UI 應顯示「沉澱中…」,**不要**顯示 0 或上一次的舊值。
  final bool settling;

  /// 心率(bpm)= NN 序列最近 6 拍中位。拍數不足回 null。
  final double? bpm;

  /// 血氧(%)= 逐拍 R 的中位帶公式。算不出回 null。
  final double? spo2;

  /// HRV 統計:sdnn / rmssd / pnn50 / sd1 / sd2 / meanRr / meanHr / hrvScore…
  /// 乾淨拍不足(暖機 < 9 拍)回 null。
  final HrvStats? hrv;

  /// **最新且有效的 RR 間距(ms)** —— 所有 HRV 的基石,已過完整過濾管線。
  /// 只有數值、沒有時間位置;要知道「這拍發生在什麼時候」請用 [rrPoints]。
  final List<double> rr;

  /// **帶索引的 RR** —— 每筆 = `(rr, startAbs, endAbs)`,兩個 abs 是該拍起谷/終谷的
  /// 絕對樣本位置(基準 = [Max30102K2.totalSamples])。與 [rr] 同一批、同順序。
  ///
  /// ⚠ **不要用「把 RR 累加起來」去推算時間位置。** 過濾器剔掉一拍時有兩種行為:
  ///   · 短側剔(偽谷)→ 基準不推進 → 下一筆 RR 直接涵蓋整段,累加剛好對得上;
  ///   · 長側剔 / SQI 差 → 基準推進 → 序列上留下一個**洞**,那段時間沒有任何 RR。
  ///   累加法看不見洞 → 一遇到洞,推算出來的時間位置就整段往後偏,越積越錯。
  ///
  /// 有了 startAbs/endAbs 才能正確做兩件事:
  ///   ① **切時間窗**:`endAbs >= totalSamples - 秒數×100` 才是真的「最近 N 秒」;
  ///   ② **判連續**:`本筆.startAbs == 前筆.endAbs` 才是時間相鄰的一對 ——
  ///      RMSSD / pNN50 / SD1 只能用相鄰對,跨洞對必須跳過(核心內部就是這樣算的)。
  final List<HrvRrPoint> rrPoints;

  /// 這一輪的振幅突波比(給軟體判「是否體動」用;越大越可能在動)。
  final double spikeMax;

  /// **真正算進 HRV 的波谷「絕對樣本位置」**(遞增;過完整個過濾管線後留下的那批)。
  ///
  /// 這是 [rr] 的端點:相鄰兩顆的間距就是一筆 RR。被生理閘門/誤拍/SQI/clean 剔掉的谷
  /// **不在**這裡面 → 軟體要在波形上標「哪幾拍真的被採用」,直接用這個,
  /// **不要自己再偵測一次**(自己抓的是另一套結果,會與這裡的數字對不起來)。
  ///
  /// 絕對位置的基準是 [Max30102K2.totalSamples](累計收到的樣本數):
  /// 波形陣列索引 = `abs - (totalSamples - 波形陣列長度)`。
  final List<int> troughAbs;

  const K2Compute({
    required this.fingerPresent,
    required this.sqiOk,
    required this.bpm,
    required this.spo2,
    required this.hrv,
    required this.rr,
    required this.rrPoints,
    required this.spikeMax,
    required this.troughAbs,
    this.settling = false,
    this.orient = K2ChannelOrient.unknown,
  });

  /// 沒手指:所有數值 null,緩衝已被清空(見 [Max30102K2.feedSamples])。
  const K2Compute.noFinger()
      : fingerPresent = false,
        sqiOk = false,
        settling = false,
        orient = K2ChannelOrient.unknown,
        bpm = null,
        spo2 = null,
        hrv = null,
        rr = const [],
        rrPoints = const [],
        spikeMax = 0,
        troughAbs = const [];

  /// 手指已上、乾淨資料累積中(尚未湊滿 settleSamples)。
  const K2Compute.settling()
      : fingerPresent = true,
        sqiOk = false,
        settling = true,
        orient = K2ChannelOrient.unknown,
        bpm = null,
        spo2 = null,
        hrv = null,
        rr = const [],
        rrPoints = const [],
        spikeMax = 0,
        troughAbs = const [];
}

/// feedData() 的回傳。
class K2FeedResult {
  /// **這批第一筆樣本的絕對位置** —— `newIr[0]` / `newRed[0]` 就在這個位置上,
  /// 第 i 筆 = `firstAbs + i`(樣本連續,不必逐筆存索引)。
  ///
  /// 這批資料自己說明自己在哪,存多久都有效。
  /// ⚠ 不要用 `totalSamples - newIr.length` 反推 —— 那條式子只在「剛呼叫完、
  ///   還沒餵下一批」那一瞬間成立,把樣本存起來稍後才換算就會錯,而且錯得很安靜。
  final int firstAbs;

  /// 這一批新拆出的原始樣本(給軟體自行累積畫圖;K2 不囤長歷史)。
  final List<int> newIr;
  final List<int> newRed;

  /// 這一批新樣本「截尾平滑後」的值(要畫乾淨線就用這個)。
  final List<double> newIrTrim;
  final List<double> newRedTrim;

  /// 湊滿 config.computeEvery 筆才會有;**null = 這次只是累積,還沒算**。
  final K2Compute? computed;

  /// **核心在這次呼叫前自行清空了**(絕對索引到頂,見 [Max30102K2.maxAbsIndex])。
  /// 收到 true → 軟體端請一併丟掉自己存的波形與 base,從這批重新開始。
  /// 100Hz 下約 497 天才會發生,實務上不會遇到;擺著是為了不留下無聲的錯。
  final bool didReset;

  const K2FeedResult({
    required this.firstAbs,
    required this.newIr,
    required this.newRed,
    required this.newIrTrim,
    required this.newRedTrim,
    required this.computed,
    this.didReset = false,
  });

  /// 這次有沒有算出新結果(等同 computed != null)。
  bool get hasComputed => computed != null;

  static const K2FeedResult empty = K2FeedResult(
    firstAbs: 0,
    newIr: [],
    newRed: [],
    newIrTrim: [],
    newRedTrim: [],
    computed: null,
  );
}

class Max30102K2 {
  /// 絕對索引上限。到頂 → 下次 feed 時整組清空重來(回傳 `didReset: true`)。
  ///
  /// 定 32-bit 無號:100Hz 下約 **497 天**,實務量測(10~30 秒一段)碰不到。
  /// **移植規格:絕對索引至少要 32-bit。** 16-bit(65535)只撐 655 秒 ≈ 11 分鐘,
  /// 量測途中就會翻掉,已存的 300 拍會變成「大數 vs 小數」相減出負值 —— 不可使用。
  static const int maxAbsIndex = 0xFFFFFFFF;

  /// 可調參數(見 k2_config.dart)。運行中可改、即時生效。
  final Max30102Config config;

  Max30102K2({Max30102Config? config})
      : config = config ?? Max30102Config() {
    // 軟體給的設定先過一次監督(見 k2_setting_limits):超出範圍的直接夾回合法區間。
    // 不夾的話有些值會讓核心安靜地完全沒有輸出,甚至除以零丟例外。
    Max30102SettingLimits.enforce(this.config);
    _beats = Max30102BeatSeries(
      config: this.config,
      irAt: _irAt,
      maxBeats: Max30102Config.maxBeats,
    );
  }

  late final Max30102BeatSeries _beats;

  // ── 滾動緩衝(有界,永不成長)──
  final List<int> _ir = [];
  final List<int> _red = [];

  /// 累計收到的樣本數(給「絕對位置」用;谷位置以此為基準)。
  int _totalSamples = 0;

  /// 距上次計算累積了幾筆新樣本(湊滿 computeEvery 就算一次)。
  int _newSinceCompute = 0;

  /// 上次餵進 NN 序列的谷絕對位置(去重用,避免同一顆谷被重複餵)。
  int _lastFedAbs = -1;

  /// 沉澱期是否已過(手指按上去後湊滿 settleSamples)。手指離開 → 回 false。
  bool _settled = false;

  /// 偵測到手指後累計了幾筆(含空轉期)。手指離開 → 歸零。
  int _sinceFingerOn = 0;

  /// 連續幾批低於手指門檻(去彈跳用)。有手指的一批 → 歸零。
  int _noFingerBatches = 0;

  // ── 通道方向判定(見 [K2ChannelOrient])──────────────────────────────
  //
  // ⚠️ 這三個是**這一次量測**的狀態,不是設備常數。手指離開就全部清掉,
  //    下一位重新判定 —— 這樣換板子、換模組都自動處理,不必人工設定。
  //    (免洗模式下與 `_totalSamples = 0` 在同一個區塊清。)

  /// 目前判定出來的方向。[K2ChannelOrient.unknown] = 還在判,**此時不輸出樣本**。
  K2ChannelOrient _orient = K2ChannelOrient.unknown;

  /// 最近一輪投給哪個方向(連續票用)。null = 上一輪落在模糊帶,沒投。
  K2ChannelOrient? _orientVote;

  /// 目前這個方向已經連續拿到幾票。湊滿 `orientVotesToLatch` 就鎖定。
  int _orientVotes = 0;

  /// 方向是**投票投出來的**(true),還是逾時退回預設(false)。
  ///
  /// 逾時那條路只是為了讓波形出得來,方向其實沒被驗證過 —— 所以
  /// **血氧只在 true 時才輸出**。用獨立旗標而不是「票數是不是 0」來記,
  /// 是因為後者要靠讀者自己推論,改到一半很容易失去意義。
  bool _orientByVote = false;

  /// 沉澱完成時的絕對位置 —— 逾時保護的起算點。-1 = 還沒沉澱完。
  int _settledAtAbs = -1;

  /// 判定期間累積、還沒吐出去的樣本數。鎖定的那一刻一次全部吐出
  /// (與沉澱期「200 筆一次吐」是同一個做法)。
  int _pendingOut = 0;

  /// 這次量測判定出來的通道方向(唯讀)。
  K2ChannelOrient get channelOrient => _orient;

  /// 谷去重容差(樣本):120ms @100Hz。視窗滑動時同一顆谷可能位移 1~2 樣本。
  static const int _dedupTol = 12;

  K2Compute? _last;

  // ══════════════════════════════════════════════════════════════════
  // 進料窗口
  // ══════════════════════════════════════════════════════════════════

  /// **進資料窗口 B** —— 餵「MCU 原始封包」(含 0x40 0x71 0x30 表頭與 CS)。
  ///
  /// 軟體把 MCU 回應「原封」丟進來即可:本函式會驗 checksum、拆出 RED/IR,
  /// 再轉呼叫 [feedSamples]。封包壞掉 / 不是資料回應 → 回 [K2FeedResult.empty]。
  ///
  /// 若軟體端已自行解析好樣本,請改用 [feedSamples]。
  K2FeedResult feedData(List<int> packet) {
    final pkt = packet is Uint8List ? packet : Uint8List.fromList(packet);
    if (!Max30102Protocol.verifyCs(pkt)) return K2FeedResult.empty;

    final samples = Max30102Protocol.decodeFifoResponse(pkt);
    if (samples.isEmpty) return K2FeedResult.empty;

    return feedSamples(
      [for (final s in samples) s.red],
      [for (final s in samples) s.ir],
    );
  }

  /// **進資料窗口 A** —— 直接餵「已拆好的樣本」(RED / IR 等長,oldest→newest)。
  ///
  /// 適用:① 軟體端自己解析協定 ② 離線重放(把錄下的波形餵進來對拍驗證)。
  ///
  /// 流程:判手指 → 進滾動緩衝 → 沉澱期擋住 → 累積達
  /// [Max30102Config.computeEvery] 筆才跑一次計算。
  /// 回傳 `computed == null` 代表「只累積,還沒算」。
  ///
  /// ── 手指與沉澱期(**輸出時序的關鍵**)──────────────────────────────
  /// ① **沒手指** → 滾動緩衝**整個清空**、斷 RR 連續性、**不輸出任何樣本**。
  ///    緩衝保持乾淨的用意:手指壓上去那一階跳(0 → ~90000)不會留在裡面。
  /// ①' **空轉期**:偵測到手指後先丟棄 `fingerDeadMs`(預設 1500ms)的資料 ——
  ///    門檻是壓到一半就跨過的,後面那段爬升不能收。
  /// ② **空轉期過後、緩衝 < settleSamples**(預設 200 筆 = 2 秒)
  ///    → 沉澱期:一樣不輸出樣本、不計算,`computed.settling == true`。
  /// ③ **沉澱期一滿** → **把累積的 200 筆一次全部吐出**(首批較大,之後恢復每批 10 筆),
  ///    並開始正常計算。此時視窗內每一筆都是手指按上去之後的乾淨資料,
  ///    baseline 一成形就是對的,不會有假暫態。
  ///
  /// ⚠ 因為②③會丟棄樣本,**絕對位置會出現斷層**:某批的 [K2FeedResult.firstAbs]
  ///   不一定等於「上一批結尾 + 1」。軟體端接波形時請檢查這件事(對不上就清空重接),
  ///   不要假設樣本是無縫連續的。[totalSamples] 本身照走不漏數,時間軸永遠正確。
  K2FeedResult feedSamples(List<int> red, List<int> ir) {
    final n = red.length < ir.length ? red.length : ir.length;
    if (n <= 0) return K2FeedResult.empty;

    // config 是公開可變的,軟體隨時可能改壞 → 每次進料先監督一次(見 k2_setting_limits)。
    // 位置很關鍵:必須在**這裡**而不是 _compute() 裡 —— 下面沉澱期判斷就會讀
    // config.settleSamples(= fs / bandLowHz),等到 _compute() 才夾已經來不及。
    // 成本只是十幾個比較。
    Max30102SettingLimits.enforce(config);

    // 絕對索引到頂 → 整組清空重來(不做 rebase:rebase 要跟軟體端同步平移
    // 已存的座標,多一組跨模組協定,為了一個 497 天才會發生的情況不值得)。
    bool didReset = false;
    if (_totalSamples + n > maxAbsIndex) {
      reset();
      didReset = true;
    }

    // ── ① 手指偵測:用「這批的 IR 平均」判,不需要長歷史 ──────────────
    // 一定要在「進緩衝之前」判,否則沒手指的資料已經污染緩衝了。
    double sum = 0;
    for (int i = 0; i < n; i++) {
      sum += ir[i];
    }
    final fingerNow = (sum / n) >= config.fingerThreshold;

    // 去彈跳:單批掉到門檻以下不算離開(接觸微抖就重來的話,10 秒量測做不完)。
    // 觀察期間樣本**照收**,不然 _ir 中間會出現時間斷層;確認離開時反正全清。
    if (fingerNow) {
      _noFingerBatches = 0;
    } else {
      _noFingerBatches++;
    }

    if (!fingerNow && _noFingerBatches >= config.fingerOffBatches) {
      // ── 免洗模式:已經歸零、正在等下一次量測 ─────────────────────────
      // 這段「沒人的空檔」不計入時間軸 —— 它不屬於任何一次量測。
      // 少了這個判斷,歸零之後只要還沒有人放手指,索引就會繼續往上加,
      // 等越久下一位的起始索引越大,就不叫「完全從零開始」了。
      final alreadyClean = _ir.isEmpty && _sinceFingerOn == 0;
      if (config.resetOnFingerOff && alreadyClean) {
        _last = const K2Compute.noFinger();
        return K2FeedResult(
          firstAbs: 0,
          newIr: const [],
          newRed: const [],
          newIrTrim: const [],
          newRedTrim: const [],
          computed: _last,
          didReset: didReset,
        );
      }

      var absNoFinger = _totalSamples;
      _totalSamples += n; // 絕對時間軸照走(樣本丟棄不代表時間沒過)
      if (_ir.isNotEmpty || _sinceFingerOn > 0) {
        _ir.clear();
        _red.clear();
        _newSinceCompute = 0;
        _settled = false;
        _sinceFingerOn = 0;
        _clearOrient(); // 方向是「這一次量測」的狀態,下一位重新判定
        // RR 池一起清 —— 不是只 markDiscontinuity。
        // 理由:抬手指的「下降斜坡」在跨過門檻之前就已經進緩衝並被算過了,
        // 那批假拍會留在池裡當 ±40% 誤拍閘門的中位基準。下次手指回來時,
        // 空轉期擋得住新的污染,卻擋不住這些舊殘留 → 真拍反被判「太短」剔除,
        // 序列鎖死在半速。樣本緩衝都清了,從它算出來的拍沒有理由留著。
        _beats.reset();
        _lastFedAbs = -1;

        // ── 免洗模式:連絕對索引一起歸零,下一次量測完全從零開始 ──────────
        //
        // ⚠️ 這裡**刻意不呼叫 reset()** —— reset() 裡有 `_noFingerBatches = 0`,
        //    而手指離開後通常會持續沒有手指。把去彈跳計數歸零的話,會變成
        //    「每隔 fingerOffBatches 批就重新觸發一次歸零」,didReset 被反覆回報。
        //    這裡只補該補的兩件事,其餘狀態上面幾行已經清乾淨了。
        //
        // 不會重複觸發:外層的 `_ir.isNotEmpty || _sinceFingerOn > 0` 守衛在第一次
        // 清完後就不成立了,後續的無手指批次進不到這裡。
        if (config.resetOnFingerOff) {
          _totalSamples = 0; // 覆蓋掉上面的 += n
          didReset = true; // 沿用既有旗標通知軟體端:你存的座標全失效了
          // 已經歸零,回舊時間軸上的位置只會誤導軟體端(這批 newIr 本來就是空的)
          absNoFinger = 0;
        }
      }
      _last = const K2Compute.noFinger();
      return K2FeedResult(
        firstAbs: absNoFinger,
        newIr: const [],
        newRed: const [],
        newIrTrim: const [],
        newRedTrim: const [],
        computed: _last,
        didReset: didReset,
      );
    }

    // ── 空轉期:偵測到手指後先完全不收 fingerDeadMs(預設 1.5 秒)────────
    // 門檻是在手指「壓到一半」時跨過的,IR 還會繼續往上爬。這段斜坡若進了緩衝,
    // 找谷門檻會被墊高、只抓到斜坡自己,生出的假 RR 會把 ±40% 閘門的中位污染成
    // 2 倍,之後真拍反而被判「太短」剔除 → 序列鎖死在半速爬不出來。
    // 所以這裡直接丟棄,不是「收進來再過濾」—— 過濾器擋不掉自己被污染的中位。
    _sinceFingerOn += n;
    if (_sinceFingerOn <= config.fingerDeadSamples) {
      _totalSamples += n; // 絕對時間軸照走
      _last = const K2Compute.settling();
      return K2FeedResult(
        firstAbs: _totalSamples - n,
        newIr: const [],
        newRed: const [],
        newIrTrim: const [],
        newRedTrim: const [],
        computed: _last,
        didReset: didReset,
      );
    }

    // ── 有手指且空轉期已過 → 進緩衝 ──────────────────────────────────
    for (int i = 0; i < n; i++) {
      _ir.add(ir[i]);
      _red.add(red[i]);
    }
    _totalSamples += n;
    _newSinceCompute += n;

    // 修剪滾動緩衝(有界)
    final over = _ir.length - config.dataHistorySamples;
    if (over > 0) {
      _ir.removeRange(0, over);
      _red.removeRange(0, over);
    }

    // ── ② 沉澱期:baseline 還沒成形 → 不輸出、不計算 ──────────────────
    if (!_settled && _ir.length < config.settleSamples) {
      _last = const K2Compute.settling();
      return K2FeedResult(
        firstAbs: _totalSamples - n,
        newIr: const [],
        newRed: const [],
        newIrTrim: const [],
        newRedTrim: const [],
        computed: _last,
        didReset: didReset,
      );
    }

    if (!_settled) {
      _settled = true;
      _settledAtAbs = _totalSamples; // 逾時保護的起算點
    }
    _pendingOut += n;

    // 湊滿才算。⚠️ 必須在決定輸出**之前** —— 這一輪的計算可能讓方向鎖定,
    //    鎖定的話這一輪就要把累積的樣本一次吐出去,晚一輪就多壓一秒。
    K2Compute? computed;
    if (_newSinceCompute >= config.computeEvery) {
      _newSinceCompute = 0;
      computed = _compute();
      _last = computed;
    }

    // ── ③ 方向未定 → 不輸出樣本 ──────────────────────────────────────
    //    理由與沉澱期完全相同:手上有樣本,但還不知道該叫它 IR 還是 RED。
    //    貼錯標籤送出去,跟送出沉澱期的爬升資料是同一類錯誤 ——
    //    **寧可晚兩秒,也不要送出會誤導的資料。**
    //    (逾時保護在 _voteOrient() 裡,超過就退回預設方向放行。)
    if (_orient == K2ChannelOrient.unknown) {
      return K2FeedResult(
        firstAbs: _totalSamples - n,
        newIr: const [],
        newRed: const [],
        newIrTrim: const [],
        newRedTrim: const [],
        computed: computed,
        didReset: didReset,
      );
    }

    // ── ④ 決定這次要吐哪些樣本 ────────────────────────────────────────
    //    方向剛鎖定 → 把壓著的那段(沉澱期 + 判定期)一次吐出;之後照常每批 n 筆。
    //    `_pendingOut` 可能超過緩衝長度(緩衝有上限),取小的那個。
    final int outN = _pendingOut > _ir.length ? _ir.length : _pendingOut;
    _pendingOut = 0;
    final outRed = _red.sublist(_red.length - outN); // 前 3 bytes 那一槽
    final outIr = _ir.sublist(_ir.length - outN); // 後 3 bytes 那一槽
    final firstAbs = _totalSamples - outN;

    // 截尾平滑:在緩衝上算(才有正確的前後文),取尾端這批新的
    final trimRed = _trimTail(_red, outN);
    final trimIr = _trimTail(_ir, outN);

    // ⚠️ **方向只在這裡套用到輸出** —— 緩衝永遠存線上收到的原始槽位,不做交換。
    //    這樣下游(波形圖、快照、/waveform、WS /stream 的 wave)全部自動拿到
    //    實際的光源,不必逐一分流,也不會有「某處交換了、某處忘了」的漂移。
    final swapped = _orient == K2ChannelOrient.swapped;
    return K2FeedResult(
      firstAbs: firstAbs,
      newIr: swapped ? outRed : outIr,
      newRed: swapped ? outIr : outRed,
      newIrTrim: swapped ? trimRed : trimIr,
      newRedTrim: swapped ? trimIr : trimRed,
      computed: computed,
      didReset: didReset,
    );
  }

  /// 依這一輪的 R 值投票,湊滿票數就鎖定方向;逾時則退回 datasheet 預設。
  ///
  /// [ratio] = 演算層算出來的 R(`(AC/DC)red ÷ (AC/DC)ir`)。0 = 這輪算不出。
  ///
  /// 投票要**相對於當下假設**解讀:目前假設「正常」而 R 偏大 → 投「對調」;
  /// 目前已經是「對調」而 R 偏大 → 表示又反了 → 投回「正常」。
  void _voteOrient(double ratio) {
    if (_orient != K2ChannelOrient.unknown) return; // 鎖定後不再改
    final assumed = _orientVote ?? K2ChannelOrient.normal;

    if (ratio > 0) {
      K2ChannelOrient? v;
      if (ratio < Max30102Config.orientRatioNormal) {
        v = assumed; // 目前假設是對的
      } else if (ratio > Max30102Config.orientRatioSwapped) {
        v = assumed == K2ChannelOrient.normal
            ? K2ChannelOrient.swapped
            : K2ChannelOrient.normal;
      }
      // v == null → 落在模糊帶(R 接近 1,分不出「真缺氧」與「接反」)→ 不投票
      if (v != null) {
        _orientVotes = (v == _orientVote) ? _orientVotes + 1 : 1;
        _orientVote = v;
        if (_orientVotes >= Max30102Config.orientVotesToLatch) {
          _orient = v;
          _orientByVote = true;
          return;
        }
      }
    }

    // 逾時逃生口:訊號差到湊不出 3 顆谷、或 R 一直落在模糊帶時,
    // 不能讓波形永遠出不來。退回 datasheet 預設方向放行樣本,
    // 但血氧仍然不給(見 _compute:方向不是判定出來的就不輸出血氧)。
    if (_settledAtAbs >= 0 &&
        _totalSamples - _settledAtAbs >= Max30102Config.orientTimeoutSamples) {
      _orient = K2ChannelOrient.normal;
      _orientByVote = false;
    }
  }

  /// 清空重來(開始一段新的檢驗前呼叫)。
  void reset() {
    _ir.clear();
    _red.clear();
    _totalSamples = 0;
    _newSinceCompute = 0;
    _lastFedAbs = -1;
    _settled = false;
    _sinceFingerOn = 0;
    _noFingerBatches = 0;
    _last = null;
    _clearOrient();
    _beats.reset();
  }

  /// 把通道方向的判定狀態全部歸零 —— 下一次量測從頭判。
  ///
  /// ⚠️ 每個清除點都要呼叫它,漏掉一個就會發生「上一位的判定結果套用到
  ///    下一位」。方向本來就是**這一次量測**的屬性,不是設備常數 ——
  ///    中途換模組、或同一台機器接不同板子,都靠這裡歸零才會自動處理。
  void _clearOrient() {
    _orient = K2ChannelOrient.unknown;
    _orientVote = null;
    _orientVotes = 0;
    _orientByVote = false;
    _settledAtAbs = -1;
    _pendingOut = 0;
  }

  /// 手指離開 / 訊號中斷時呼叫:只斷「RR 連續性」,不清歷史。
  void markDiscontinuity() => _beats.markDiscontinuity();

  // ══════════════════════════════════════════════════════════════════
  // 取值窗口(全是原始值,未做顯示平滑)
  // ══════════════════════════════════════════════════════════════════

  /// 最近一次計算的完整結果(沒算過回 null)。
  K2Compute? get latest => _last;

  /// 心率(bpm),原始值未平滑。
  double? get bpm => _last?.bpm;

  /// 血氧(%),原始值未平滑。
  double? get spo2 => _last?.spo2;

  /// HRV 統計(sdnn/rmssd/pnn50/sd1/sd2/…)。
  HrvStats? get hrv => _last?.hrv;

  /// **最新且有效的 RR 間距(ms)** —— HRV 的基石,已過完整過濾管線。
  List<double> get rrLatest => _beats.rrClean();

  /// 目前累積的乾淨拍數(判斷資料夠不夠算 HRV;暖機需 ≥9)。
  int get beatCount => _beats.rrHistory.length + 1;

  /// **累計收到的樣本數** —— [K2Compute.troughAbs] 絕對位置的基準。
  /// 軟體自存的波形陣列若長 L,則陣列索引 = `abs - (totalSamples - L)`。
  int get totalSamples => _totalSamples;

  // ══════════════════════════════════════════════════════════════════
  // 內部
  // ══════════════════════════════════════════════════════════════════

  /// 跑一次完整計算:最新 computeWindow 筆 → 演算法 → NN 序列 → HRV。
  K2Compute _compute() {
    const want = Max30102Config.computeWindow; // 固定 500,不開放調
    final take = _ir.length < want ? _ir.length : want;
    if (take < Max30102Config.samplingRateHz) {
      // 不足 1 秒資料 → 算不出東西
      return const K2Compute(
        fingerPresent: false,
        sqiOk: false,
        bpm: null,
        spo2: null,
        hrv: null,
        rr: [],
        rrPoints: [],
        spikeMax: 0,
        troughAbs: [],
      );
    }
    // 兩個緩衝存的是**線上收到的原始槽位**,不是「已知的 IR / RED」:
    //   _red = FIFO 每組的前 3 bytes(datasheet 說那是紅光)
    //   _ir  = 後 3 bytes(datasheet 說那是紅外)
    // 名字沿用歷史,但**方向未經判定之前那只是 datasheet 的宣稱**,不是事實。
    final bufRed = _red.sublist(_red.length - take);
    final bufIr = _ir.sublist(_ir.length - take);

    // ⚠️ **方向只在這裡套用到計算** —— 判定期間先照 datasheet 假設跑一次,
    //    看算出來的 R 再修正(見 _voteOrient)。第一次猜錯不影響心率:
    //    兩路的脈搏是同一個(實測相關 0.995),谷照樣找得到。
    final assumed = _orient != K2ChannelOrient.unknown
        ? _orient
        : (_orientVote ?? K2ChannelOrient.normal);
    final swapped = assumed == K2ChannelOrient.swapped;
    final ir = swapped ? bufRed : bufIr;
    final red = swapped ? bufIr : bufRed;

    final r = Max30102Algorithm.compute(
      red: red,
      ir: ir,
      fs: Max30102Config.samplingRateHz,
      bandLowHz: config.bandLowHz,
      bandHighHz: config.bandHighHz,
      fingerThreshold: config.fingerThreshold,
      hrMin: config.hrMin.toDouble(),
      hrMax: config.hrMax.toDouble(),
      spo2Min: Max30102Config.spo2Min.toDouble(),
      spo2Max: Max30102Config.spo2Max.toDouble(),
      trimWindow: Max30102Config.trimWindow,
      promRatio: config.promRatio,
      spo2Linear: Max30102Config.spo2Linear,
    );

    // 拿這一輪的 R 去投票。位置要在算 spo2 **之前** —— 這一輪若剛好湊滿票數,
    // 血氧就能立刻輸出,不用再等下一輪。
    _voteOrient(r.spo2Ratio);

    // 谷(視窗內索引)→ 絕對位置 → 餵進唯一 NN 序列。
    //   · 丟掉最右一顆(B 右緣過濾):視窗邊緣的谷突出度未穩,延遲一拍再收。
    //   · 丟掉左緣 context 區(見下)。
    //   · 去重:視窗滑動時同一顆谷可能位移 1~2 樣本 → 容差內視為同一顆。
    final base = _totalSamples - take;
    final troughs = r.irTroughs;

    // ── 左緣 context 區 ───────────────────────────────────────────────
    // baseline 是**置中**移動平均(寬 hpWin):算第 i 筆時要取 i±hpWin/2。
    // 陣列開頭那 hpWin/2 筆取不到左半邊,只能單邊平均 → baseline 是偏的,
    // 去趨勢後會凸出一塊,在那裡找到的谷不是真的脈搏。
    // 那段資料仍**留在緩衝裡**當後面樣本的 baseline context —— 不是丟棄,是只當基準用。
    //
    // ⚠ 只在「緩衝還沒長到完整視窗」時套用。理由是時序:
    //   · 起步階段 base 固定不動(沒東西被裁),左緣永遠是最舊那批,
    //     不會再滑進可信區 → 必須永久排除。
    //   · 緩衝滿了之後視窗開始前滑,谷是先從**右緣**進來、在中段被餵過,
    //     之後才移到左緣。這時再擋沒有意義,而且 computeEvery 較大時
    //     (一輪滑掉 > hpWin/2)可能讓某顆谷「還沒進可信區就滑過頭」→ 整拍漏掉。
    //   · 起步排除掉的那些谷,等視窗滑動後窗內索引會降到 outputFrom 以下,
    //     但它們的 abs 早於 _lastFedAbs → 被去重擋住,不會事後補餵。
    //
    // 判斷條件用 `take == _ir.length`(視窗吃掉整個緩衝 ⇔ 視窗左緣 = 緩衝左緣),
    // 不用「take < computeWindow」—— 後者是靠參數大小關係碰巧成立的,
    // 一旦 computeWindow 比緩衝上限大就永遠不會關閉。這個條件自我描述、與參數無關。
    final hpWin = (Max30102Config.samplingRateHz / config.bandLowHz)
        .round()
        .clamp(1, take)
        .toInt();
    final outputFrom = take == _ir.length ? hpWin ~/ 2 : 0;

    final fed = <int>[];
    for (int i = 0; i + 1 < troughs.length; i++) {
      // i+1 < length → 天然丟掉最右一顆(B 右緣過濾)
      final t = troughs[i];
      if (t < outputFrom) continue; // 左緣 context 區,不產出
      final abs = base + t;
      if (_lastFedAbs >= 0 && abs <= _lastFedAbs + _dedupTol) continue;
      fed.add(abs);
      _lastFedAbs = abs;
    }
    if (fed.isNotEmpty) _beats.feed(fed, r.sqiOk);

    // RR 池照時間裁,與樣本緩衝共用同一個 dataHistoryMs(預設 30 秒)→ 兩邊對得起來:
    // 波形上看得到的那段,RR 池裡就有對應的拍;反之亦然。
    // 要更長的歷史由軟體端自行累積 —— 核心只算,不囤長歷史。
    _beats.trimOlderThan(_totalSamples - config.dataHistorySamples);

    // 直接用演算層算好的血氧,不再自己重算一次(以前是 spo2FromR(ratioNew),
    // 與 r.spo2 是同一條公式、同一個 R → 完全等價,只是少一份重複的程式)。
    //
    // ⚠️ 待決定:這裡**沒有**看 `r.spo2Valid`(拍可信 + 值落在 70~100)。
    //    也就是拍不可信、或值超出生理範圍時照樣輸出。要收緊就改成
    //    `r.spo2Valid ? r.spo2 : null` —— 但那會讓血氧變成更常 null,先不動。
    // ⚠️ 血氧多一道閘門:**方向必須是投票判定出來的**。
    //    理由:R 本身就是「紅光脈動 ÷ 紅外脈動」,兩路標反了它就是倒數,
    //    算出來的血氧會是生理上不可能的值(實測對調板 R=2.35 → 血氧 −83%)。
    //    方向沒確定就沒有可信的血氧,寧可不給。心率不受影響,照常輸出。
    final spo2 =
        (r.spo2 > 0 && _orientByVote) ? r.spo2 : null;

    // 乾淨 NN 序列(帶起谷/終谷絕對位置)—— rr / rrPoints / troughAbs 全部由它導出,
    // 保證是同一批:標點、數值、HRV 三者永遠一致。
    final cleanPts = _beats.rrCleanPts();
    final troughAbs = <int>[];
    for (final p in cleanPts) {
      if (troughAbs.isEmpty || troughAbs.last != p.startAbs) {
        troughAbs.add(p.startAbs);
      }
      troughAbs.add(p.endAbs);
    }

    return K2Compute(
      fingerPresent: r.fingerPresent,
      sqiOk: r.sqiOk,
      orient: _orient,
      bpm: _beats.hrRecent(6),
      spo2: spo2,
      hrv: _beats.hrvStats(),
      rr: [for (final p in cleanPts) p.rr],
      rrPoints: cleanPts,
      spikeMax: r.sqiSpikeMax,
      troughAbs: troughAbs,
    );
  }

  /// 對整段緩衝做截尾平滑,取尾端 n 筆(= 這批新樣本對應的平滑值)。
  List<double> _trimTail(List<int> src, int n) {
    if (src.isEmpty || n <= 0) return const [];
    final d = List<double>.generate(src.length, (i) => src[i].toDouble());
    final t = Max30102Signal.slidingTrimmedMean(d, Max30102Config.trimWindow);
    final from = t.length - n;
    return t.sublist(from < 0 ? 0 : from);
  }

  /// 供 BeatSeries 回讀原始 IR(search-back 用);超出緩衝回 -1。
  int _irAt(int absPos) {
    final back = _totalSamples - absPos;
    if (back < 1 || back > _ir.length) return -1;
    return _ir[_ir.length - back];
  }
}
