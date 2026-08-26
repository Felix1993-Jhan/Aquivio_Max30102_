// ============================================================================
// Max30102K2 — 控制層(交接用核心)
// ============================================================================
// 【由 Dart 版 k2_core.dart 轉譯,行為完全一致】
//
// 三層架構裡的「控制層」:上接軟體(UI 層)、下叫基礎層。
//
//   UI 層 / 軟體  ──feedData(封包)──▶  【本檔 Max30102K2】 ──▶ 基礎層
//                 ◀──原始數值(getter)──                      (signal/algorithm/
//                                                             sqi/beatseries/hrv)
//
// 設計原則(交接考量):
//   ① 不碰串口、不開 Timer:資料何時收、多久算一次,由軟體決定。
//   ② 只吐原始值:不做 EMA 平滑、不做 hold/凍結、不組 log —— 那些是呈現層的事。
//   ③ 記憶體有界:樣本緩衝與 RR 池共用 config.dataHistoryMs(預設 30 秒),永不成長。
//
// 典型用法(軟體端 Node):
// ```js
// const { Max30102K2 } = require('./k2_core');
// const { Max30102Protocol } = require('./k2_protocol');
// const k2 = new Max30102K2();
// // 軟體自己的計時器,每 100ms 跟 MCU 要一次資料:
// //   送出 Max30102Protocol.buildQueryFifo()  → 收到回應 bytes 後:
// const r = k2.feedData(mcuResponseBytes);   // 原封丟進來,驗框/拆包我們做
// myChartIr.push(...r.newIr);                // 想畫圖就自己接(長度自己決定)
// if (r.computed) {                          // 約每秒一次才會非 null
//   console.log(r.computed.bpm);
//   console.log(r.computed.hrv && r.computed.hrv.rmssd);
// }
// ```
// ============================================================================

const { HrSpo2Result, Max30102Algorithm } = require('./k2_algorithm');
const { Max30102BeatSeries } = require('./k2_beatseries');
const { Max30102Config } = require('./k2_config');
const { Max30102HrvCalculator } = require('./k2_hrv_calculator');
const { Max30102Protocol } = require('./k2_protocol');
const { Max30102SettingLimits } = require('./k2_setting_limits');
const { Max30102Signal } = require('./k2_signal');

/// 一次計算的產物(全部是「原始值」,未做任何顯示平滑)。
class K2Compute {
  constructor({
    fingerPresent,
    sqiOk,
    bpm,
    spo2,
    hrv,
    rr,
    rrPoints,
    spikeMax,
    troughAbs,
    settling = false,
  }) {
    /// 是否偵測到手指(IR 平均 ≥ fingerThreshold)。
    this.fingerPresent = fingerPresent;
    /// 這一輪訊號品質是否過關(cv + spike)。false → 這輪的谷不進 NN 序列。
    this.sqiOk = sqiOk;
    /// **沉澱中** —— 手指已偵測到,但乾淨資料還沒湊滿 settleSamples(預設 200 筆)。
    /// 此時所有數值皆為 null。UI 應顯示「沉澱中…」,不要顯示 0 或舊值。
    this.settling = settling;
    /// 心率(bpm)= NN 序列最近 6 拍中位。拍數不足回 null。
    this.bpm = bpm;
    /// 血氧(%)= 逐拍 R 的中位帶公式。算不出回 null。
    this.spo2 = spo2;
    /// HRV 統計:sdnn/rmssd/pnn50/sd1/sd2/meanRr/meanHr/hrvScore…暖機 <9 拍回 null。
    this.hrv = hrv;
    /// 最新且有效的 RR 間距(ms) —— 只有數值、沒有時間位置。
    this.rr = rr;
    /// **帶索引的 RR** —— 每筆 = { rr, startAbs, endAbs }(絕對樣本位置,基準 totalSamples)。
    /// ⚠ 不要用「把 RR 累加」推算時間位置(過濾器剔拍會留洞,累加法看不見洞會越積越錯)。
    ///   切時間窗:endAbs >= totalSamples - 秒數×100;判連續:本筆.startAbs == 前筆.endAbs。
    this.rrPoints = rrPoints;
    /// 這一輪的振幅突波比(給軟體判「是否體動」;越大越可能在動)。
    this.spikeMax = spikeMax;
    /// **真正算進 HRV 的波谷「絕對樣本位置」**(遞增)。是 rr 的端點。
    /// 軟體要在波形上標「哪幾拍真的被採用」直接用這個,不要自己再偵測一次。
    /// 波形陣列索引 = abs - (totalSamples - 波形陣列長度)。
    this.troughAbs = troughAbs;
  }

  /// 沒手指:所有數值 null,緩衝已被清空。
  static noFinger() {
    return new K2Compute({
      fingerPresent: false, sqiOk: false, settling: false,
      bpm: null, spo2: null, hrv: null, rr: [], rrPoints: [],
      spikeMax: 0, troughAbs: [],
    });
  }

  /// 手指已上、乾淨資料累積中(尚未湊滿 settleSamples)。
  static settlingResult() {
    return new K2Compute({
      fingerPresent: true, sqiOk: false, settling: true,
      bpm: null, spo2: null, hrv: null, rr: [], rrPoints: [],
      spikeMax: 0, troughAbs: [],
    });
  }
}

/// feedData() 的回傳。
class K2FeedResult {
  constructor({
    firstAbs,
    newIr,
    newRed,
    newIrTrim,
    newRedTrim,
    computed,
    didReset = false,
  }) {
    /// **這批第一筆樣本的絕對位置** —— newIr[0]/newRed[0] 就在這位置,第 i 筆 = firstAbs + i。
    /// ⚠ 不要用 totalSamples - newIr.length 反推(只在剛呼叫完那一瞬間成立)。
    this.firstAbs = firstAbs;
    /// 這一批新拆出的原始樣本(給軟體自行累積畫圖;K2 不囤長歷史)。
    this.newIr = newIr;
    this.newRed = newRed;
    /// 這一批新樣本「截尾平滑後」的值(要畫乾淨線就用這個)。
    this.newIrTrim = newIrTrim;
    this.newRedTrim = newRedTrim;
    /// 湊滿 config.computeEvery 筆才會有;**null = 這次只是累積,還沒算**。
    this.computed = computed;
    /// **核心在這次呼叫前自行清空了**(絕對索引到頂)。收到 true → 軟體端一併丟掉自己存的波形。
    /// 100Hz 下約 497 天才會發生,實務上不會遇到。
    this.didReset = didReset;
  }

  /// 這次有沒有算出新結果(等同 computed != null)。
  get hasComputed() { return this.computed != null; }
}

K2FeedResult.empty = new K2FeedResult({
  firstAbs: 0, newIr: [], newRed: [], newIrTrim: [], newRedTrim: [], computed: null,
});

/** clamp:對應 Dart num.clamp(lo, hi)。 */
function clamp(x, lo, hi) { return x < lo ? lo : (x > hi ? hi : x); }

class Max30102K2 {
  /// 絕對索引上限。到頂 → 下次 feed 時整組清空重來(回傳 didReset: true)。
  /// 定 32-bit 無號:100Hz 下約 497 天。**移植規格:絕對索引至少要 32-bit。**
  static maxAbsIndex = 0xFFFFFFFF;

  /// 谷去重容差(樣本):120ms @100Hz。
  static _dedupTol = 12;

  /// @param {{config?: Max30102Config}} [o]
  constructor({ config } = {}) {
    /// 可調參數(見 k2_config)。運行中可改、即時生效。
    this.config = config || new Max30102Config();
    // 軟體給的設定先過一次監督:超出範圍的直接夾回合法區間。
    Max30102SettingLimits.enforce(this.config);
    this._beats = new Max30102BeatSeries({
      config: this.config,
      irAt: (absPos) => this._irAt(absPos),
      maxBeats: Max30102Config.maxBeats,
    });

    // ── 滾動緩衝(有界,永不成長)──
    this._ir = [];
    this._red = [];
    this._totalSamples = 0; // 累計收到的樣本數(絕對位置基準)
    this._newSinceCompute = 0; // 距上次計算累積了幾筆新樣本
    this._lastFedAbs = -1; // 上次餵進 NN 序列的谷絕對位置(去重用)
    this._settled = false; // 沉澱期是否已過
    this._sinceFingerOn = 0; // 偵測到手指後累計了幾筆(含空轉期)
    this._noFingerBatches = 0; // 連續幾批低於手指門檻(去彈跳用)
    this._last = null;
  }

  // ══════════════════════════════════════════════════════════════════
  // 進料窗口
  // ══════════════════════════════════════════════════════════════════

  /// **進資料窗口 B** —— 餵「MCU 原始封包」(含 0x40 0x71 0x30/0x31 表頭與 CS)。
  /// 軟體把 MCU 回應「原封」丟進來即可:本函式會驗 checksum、拆出 RED/IR,再轉呼叫 feedSamples。
  /// 封包壞掉 / 不是資料回應 → 回 K2FeedResult.empty。
  feedData(packet) {
    const pkt = packet instanceof Uint8Array ? packet : Uint8Array.from(packet);
    if (!Max30102Protocol.verifyCs(pkt)) return K2FeedResult.empty;

    const samples = Max30102Protocol.decodeFifoResponse(pkt);
    if (samples.length === 0) return K2FeedResult.empty;

    return this.feedSamples(
      samples.map((s) => s.red),
      samples.map((s) => s.ir),
    );
  }

  /// **進資料窗口 A** —— 直接餵「已拆好的樣本」(RED / IR 等長,oldest→newest)。
  /// 適用:① 軟體端自己解析協定 ② 離線重放。
  /// 回傳 computed == null 代表「只累積,還沒算」。
  ///
  /// ── 手指與沉澱期(輸出時序的關鍵)──
  /// ① 沒手指 → 滾動緩衝整個清空、斷 RR 連續性、不輸出任何樣本。
  /// ①' 空轉期:偵測到手指後先丟棄 fingerDeadMs(預設 1500ms)的資料。
  /// ② 空轉期過後、緩衝 < settleSamples(預設 200 筆)→ 沉澱期:不輸出、不計算。
  /// ③ 沉澱期一滿 → 把累積的 200 筆一次全部吐出,並開始正常計算。
  ///
  /// ⚠ ②③會丟棄樣本 → 絕對位置會出現斷層:某批的 firstAbs 不一定 = 上批結尾+1。
  ///   軟體端接波形時請檢查(對不上就清空重接)。totalSamples 本身照走不漏數。
  feedSamples(red, ir) {
    const n = red.length < ir.length ? red.length : ir.length;
    if (n <= 0) return K2FeedResult.empty;

    // config 是公開可變的 → 每次進料先監督一次(必須在這裡,沉澱期判斷會讀 settleSamples)。
    Max30102SettingLimits.enforce(this.config);

    // 絕對索引到頂 → 整組清空重來(不做 rebase)。
    let didReset = false;
    if (this._totalSamples + n > Max30102K2.maxAbsIndex) {
      this.reset();
      didReset = true;
    }

    // ── ① 手指偵測:用「這批的 IR 平均」判 ──
    // 一定要在「進緩衝之前」判,否則沒手指的資料已經污染緩衝了。
    let sum = 0;
    for (let i = 0; i < n; i++) sum += ir[i];
    const fingerNow = (sum / n) >= this.config.fingerThreshold;

    // 去彈跳:單批掉到門檻以下不算離開。觀察期間樣本照收(確認離開時反正全清)。
    if (fingerNow) {
      this._noFingerBatches = 0;
    } else {
      this._noFingerBatches++;
    }

    if (!fingerNow && this._noFingerBatches >= this.config.fingerOffBatches) {
      const absNoFinger = this._totalSamples;
      this._totalSamples += n; // 絕對時間軸照走(樣本丟棄不代表時間沒過)
      if (this._ir.length > 0 || this._sinceFingerOn > 0) {
        this._ir.length = 0;
        this._red.length = 0;
        this._newSinceCompute = 0;
        this._settled = false;
        this._sinceFingerOn = 0;
        // RR 池一起清 —— 抬手指的下降斜坡會留假拍污染中位基準。
        this._beats.reset();
        this._lastFedAbs = -1;
      }
      this._last = K2Compute.noFinger();
      return new K2FeedResult({
        firstAbs: absNoFinger,
        newIr: [], newRed: [], newIrTrim: [], newRedTrim: [],
        computed: this._last, didReset,
      });
    }

    // ── 空轉期:偵測到手指後先完全不收 fingerDeadMs(預設 1.5 秒)──
    // 門檻是在手指「壓到一半」時跨過的,那段斜坡若進緩衝會污染找谷門檻與 ±40% 閘門中位。
    this._sinceFingerOn += n;
    if (this._sinceFingerOn <= this.config.fingerDeadSamples) {
      this._totalSamples += n; // 絕對時間軸照走
      this._last = K2Compute.settlingResult();
      return new K2FeedResult({
        firstAbs: this._totalSamples - n,
        newIr: [], newRed: [], newIrTrim: [], newRedTrim: [],
        computed: this._last, didReset,
      });
    }

    // ── 有手指且空轉期已過 → 進緩衝 ──
    for (let i = 0; i < n; i++) {
      this._ir.push(ir[i]);
      this._red.push(red[i]);
    }
    this._totalSamples += n;
    this._newSinceCompute += n;

    // 修剪滾動緩衝(有界)
    const over = this._ir.length - this.config.dataHistorySamples;
    if (over > 0) {
      this._ir.splice(0, over);
      this._red.splice(0, over);
    }

    // ── ② 沉澱期:baseline 還沒成形 → 不輸出、不計算 ──
    if (!this._settled && this._ir.length < this.config.settleSamples) {
      this._last = K2Compute.settlingResult();
      return new K2FeedResult({
        firstAbs: this._totalSamples - n,
        newIr: [], newRed: [], newIrTrim: [], newRedTrim: [],
        computed: this._last, didReset,
      });
    }

    // ── ③ 決定這次要吐哪些樣本 ──
    //    剛沉澱完 → 把整個沉澱期(≈settleSamples 筆)一次吐出;之後照常每批 n 筆。
    let outIr, outRed;
    if (!this._settled) {
      this._settled = true;
      outIr = [...this._ir];
      outRed = [...this._red];
    } else {
      outIr = ir.slice(0, n);
      outRed = red.slice(0, n);
    }
    const firstAbs = this._totalSamples - outIr.length;

    // 截尾平滑:在緩衝上算(才有正確的前後文),取尾端這批新的
    const newIrTrim = this._trimTail(this._ir, outIr.length);
    const newRedTrim = this._trimTail(this._red, outRed.length);

    // 湊滿才算
    let computed = null;
    if (this._newSinceCompute >= this.config.computeEvery) {
      this._newSinceCompute = 0;
      computed = this._compute();
      this._last = computed;
    }

    return new K2FeedResult({
      firstAbs, newIr: outIr, newRed: outRed, newIrTrim, newRedTrim,
      computed, didReset,
    });
  }

  /// 清空重來（開始一段新的檢驗前呼叫）。
  reset() {
    this._ir.length = 0;
    this._red.length = 0;
    this._totalSamples = 0;
    this._newSinceCompute = 0;
    this._lastFedAbs = -1;
    this._settled = false;
    this._sinceFingerOn = 0;
    this._noFingerBatches = 0;
    this._last = null;
    this._beats.reset();
  }

  /// 手指離開 / 訊號中斷時呼叫:只斷「RR 連續性」,不清歷史。
  markDiscontinuity() { this._beats.markDiscontinuity(); }

  // ══════════════════════════════════════════════════════════════════
  // 取值窗口(全是原始值,未做顯示平滑)
  // ══════════════════════════════════════════════════════════════════

  /// 最近一次計算的完整結果(沒算過回 null)。
  get latest() { return this._last; }
  /// 心率(bpm),原始值未平滑。
  get bpm() { return this._last ? this._last.bpm : null; }
  /// 血氧(%),原始值未平滑。
  get spo2() { return this._last ? this._last.spo2 : null; }
  /// HRV 統計(sdnn/rmssd/pnn50/sd1/sd2/…)。
  get hrv() { return this._last ? this._last.hrv : null; }
  /// 最新且有效的 RR 間距(ms) —— HRV 的基石,已過完整過濾管線。
  get rrLatest() { return this._beats.rrClean(); }
  /// 目前累積的乾淨拍數(判斷資料夠不夠算 HRV;暖機需 ≥9)。
  get beatCount() { return this._beats.rrHistory.length + 1; }
  /// **累計收到的樣本數** —— troughAbs 絕對位置的基準。
  /// 軟體自存的波形陣列若長 L,則陣列索引 = abs - (totalSamples - L)。
  get totalSamples() { return this._totalSamples; }

  // ══════════════════════════════════════════════════════════════════
  // 內部
  // ══════════════════════════════════════════════════════════════════

  /// 跑一次完整計算:最新 computeWindow 筆 → 演算法 → NN 序列 → HRV。
  _compute() {
    const want = Max30102Config.computeWindow; // 固定 500,不開放調
    const take = this._ir.length < want ? this._ir.length : want;
    if (take < Max30102Config.samplingRateHz) {
      // 不足 1 秒資料 → 算不出東西
      return new K2Compute({
        fingerPresent: false, sqiOk: false, bpm: null, spo2: null, hrv: null,
        rr: [], rrPoints: [], spikeMax: 0, troughAbs: [],
      });
    }
    const ir = this._ir.slice(this._ir.length - take);
    const red = this._red.slice(this._red.length - take);

    const r = Max30102Algorithm.compute({
      red, ir,
      fs: Max30102Config.samplingRateHz,
      bandLowHz: this.config.bandLowHz,
      bandHighHz: this.config.bandHighHz,
      fingerThreshold: this.config.fingerThreshold,
      hrMin: this.config.hrMin,
      hrMax: this.config.hrMax,
      spo2Min: Max30102Config.spo2Min,
      spo2Max: Max30102Config.spo2Max,
      trimWindow: Max30102Config.trimWindow,
      promRatio: this.config.promRatio,
      spo2Linear: Max30102Config.spo2Linear,
    });

    // 谷(視窗內索引)→ 絕對位置 → 餵進唯一 NN 序列。
    //   · 丟掉最右一顆(B 右緣過濾):視窗邊緣的谷突出度未穩,延遲一拍再收。
    //   · 丟掉左緣 context 區(見下)。· 去重:容差內視為同一顆。
    const base = this._totalSamples - take;
    const troughs = r.irTroughs;

    // ── 左緣 context 區 ──
    // baseline 是置中移動平均(寬 hpWin):開頭 hpWin/2 筆取不到左半邊 → baseline 偏,
    // 去趨勢後凸出一塊,在那找到的谷不是真脈搏。那段資料仍留在緩衝當後面的 baseline context。
    // 只在「緩衝還沒長到完整視窗」時套用(take == _ir.length ⇔ 視窗左緣 = 緩衝左緣)。
    const hpWin = clamp(
      Math.round(Max30102Config.samplingRateHz / this.config.bandLowHz), 1, take);
    const outputFrom = take === this._ir.length ? Math.trunc(hpWin / 2) : 0;

    const fed = [];
    for (let i = 0; i + 1 < troughs.length; i++) {
      // i+1 < length → 天然丟掉最右一顆(B 右緣過濾)
      const t = troughs[i];
      if (t < outputFrom) continue; // 左緣 context 區,不產出
      const abs = base + t;
      if (this._lastFedAbs >= 0 && abs <= this._lastFedAbs + Max30102K2._dedupTol) continue;
      fed.push(abs);
      this._lastFedAbs = abs;
    }
    if (fed.length > 0) this._beats.feed(fed, r.sqiOk);

    // RR 池照時間裁,與樣本緩衝共用同一個 dataHistoryMs(預設 30 秒)→ 兩邊對得起來。
    this._beats.trimOlderThan(this._totalSamples - this.config.dataHistorySamples);

    // 直接用演算層算好的血氧(以前是自己重算,同一條公式 → 完全等價)。
    // ⚠️ 待決定:這裡沒有看 r.spo2Valid。要收緊就改成 r.spo2Valid ? r.spo2 : null。
    const spo2 = r.spo2 > 0 ? r.spo2 : null;

    // 乾淨 NN 序列(帶起谷/終谷絕對位置)—— rr / rrPoints / troughAbs 全部由它導出。
    const cleanPts = this._beats.rrCleanPts();
    const troughAbs = [];
    for (const p of cleanPts) {
      if (troughAbs.length === 0 || troughAbs[troughAbs.length - 1] !== p.startAbs) {
        troughAbs.push(p.startAbs);
      }
      troughAbs.push(p.endAbs);
    }

    return new K2Compute({
      fingerPresent: r.fingerPresent,
      sqiOk: r.sqiOk,
      bpm: this._beats.hrRecent(6),
      spo2,
      hrv: this._beats.hrvStats(),
      rr: cleanPts.map((p) => p.rr),
      rrPoints: cleanPts,
      spikeMax: r.sqiSpikeMax,
      troughAbs,
    });
  }

  /// 對整段緩衝做截尾平滑,取尾端 n 筆(= 這批新樣本對應的平滑值)。
  _trimTail(src, n) {
    if (src.length === 0 || n <= 0) return [];
    const d = new Array(src.length);
    for (let i = 0; i < src.length; i++) d[i] = src[i];
    const t = Max30102Signal.slidingTrimmedMean(d, Max30102Config.trimWindow);
    const from = t.length - n;
    return t.slice(from < 0 ? 0 : from);
  }

  /// 供 BeatSeries 回讀原始 IR(search-back 用);超出緩衝回 -1。
  _irAt(absPos) {
    const back = this._totalSamples - absPos;
    if (back < 1 || back > this._ir.length) return -1;
    return this._ir[this._ir.length - back];
  }
}

module.exports = { K2Compute, K2FeedResult, Max30102K2 };
