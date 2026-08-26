// ============================================================================
// Max30102Config (K2 交接版) — 精簡後的可調參數
// ============================================================================
// 【由 Dart 版 k2_config.dart 轉譯,行為完全一致】
//
// 與原版差異(交接考量):
//   · 只留「真的需要外部調」的項目,其餘固定成常數 → 降低誤用風險。
//   · 移除「輪詢間隔」:K2 不自己收串口,計時由軟體那邊決定。
//   · 移除「更新間隔(ms)」:改成「累積筆數 computeEvery」(見 k2_core)。
//   · 截尾視窗 / SpO2 上下限 / 血氧公式 → 固定不開放。
//
// ★ 重點①:HR(bpm) 與 濾波(Hz) 是「同一件事的兩種單位」(Hz = bpm / 60)。
//    存 hrMin/hrMax(bpm),bandLowHz/bandHighHz 自動換算;用哪一邊設定都會連動。
//
// ★ 重點②:平滑係數(spo2SmoothFactor / hrSmoothFactor)**K2 核心不套用**,
//    只是提供給「呈現層(UI / 軟體)」參考 —— 核心一律吐原始值,平滑是 UI 的事。
// ============================================================================

class Max30102Config {
  // ── 固定項(不開放調整)────────────────────────────────────────────
  /// 取樣率(Hz)。韌體設定;改它要同步檢視演算法。
  static samplingRateHz = 100;

  /// 截尾視窗(筆):去突波用,固定。
  static trimWindow = 9;

  /// SpO2 合理範圍(固定)。
  static spo2Min = 70;
  static spo2Max = 100;

  /// 血氧公式:false = 二次多項式(Maxim);固定。
  static spo2Linear = false;

  /// **演算視窗(筆)** = 每次計算取「最新 N 筆」。500 = 5 秒 @100Hz。**固定不開放調。**
  /// 視窗變長不會更準(谷是局部極小、R 逐拍算);變短則直接壞(不足 1 秒保護永遠成立)。
  /// 500 對 30~240bpm 全區間都夠(約 6~7 拍)。
  static computeWindow = 500;

  /// NN 序列**硬上限(拍)** —— 純記憶體保險,不是主要界線。
  /// 真正的界線是 dataHistoryMs(時間)。
  static maxBeats = 300;

  /// computeEvery 下限 = 一次詢問(100ms @100Hz)的量 = 10 筆。
  static minComputeEvery = 10;

  /// @param {object} opts
  constructor({
    fingerThreshold = 50000,
    hrMin = 30,
    hrMax = 240,
    promRatio = 0.5,
    computeEvery = 100,
    ledCurrentRed = 0x24,
    ledCurrentIr = 0x24,
    fingerDeadMs = 1500,
    dataHistoryMs = 30000,
    fingerOffBatches = 3,
    searchBackEnabled = false,
    cleanEnabled = true,
    spo2SmoothFactor = 0.7,
    hrSmoothFactor = 0.8,
  } = {}) {
    // ── 開放調整 ──
    // ⚠️ 核心目前**不驗證**這些值(那是 k2_setting_limits 的事)。

    /// 手指偵測門檻(IR 平均 ≥ 此值視為有手指)。單位與 HrSpo2Result.irDc 相同。
    /// IR 是 18-bit(0~262143);設超過 262143 就永遠偵測不到手指。
    this.fingerThreshold = fingerThreshold;

    /// HR 下限(bpm)。一改連動三件事:生理閘門 RR 上限、baseline 視窗寬、沉澱期長度。
    this.hrMin = hrMin;

    /// HR 上限(bpm)。連動:生理閘門 RR 下限、找谷最小間距 minDist。必須 hrMax > hrMin。
    this.hrMax = hrMax;

    /// 谷顯著度門檻 = promRatio × 第 70 百分位。越小越容易收進較矮的谷。
    /// ⚠️ 設 0 或負數 → 門檻歸零,雜訊全被當成谷,心率暴衝。
    this.promRatio = promRatio;

    /// 目前硬體使用的 LED 驅動電流(8-bit 暫存器值)。核心**不會自動套用**,是「紀錄」不是「開關」。
    /// 預設 0x24 = 韌體 ReInit 之後晶片回到的值。
    this.ledCurrentRed = ledCurrentRed;
    this.ledCurrentIr = ledCurrentIr;

    /// 空轉期(ms):偵測到手指後先完全不收這麼久的資料(擋掉壓下去的斜坡)。
    this.fingerDeadMs = fingerDeadMs;

    /// 核心保留時間(ms):樣本緩衝與 RR 池共用這一個界線。預設 30 秒。
    this.dataHistoryMs = dataHistoryMs;

    /// 手指離開去彈跳(批):連續這麼多批低於門檻才判定「真的離開」。
    this.fingerOffBatches = fingerOffBatches;

    /// 補漏拍(search-back):預設關(寧缺勿假)。
    this.searchBackEnabled = searchBackEnabled;

    /// clean(全域 MAD 離群濾):預設開。
    this.cleanEnabled = cleanEnabled;

    /// 呈現層 EMA 平滑係數 —— **核心完全不套用**,放這裡是當「建議值」交給軟體端。
    /// 顯示值ₙ = k × 顯示值ₙ₋₁ + (1 − k) × 原始值ₙ;血氧 k=0.7、心率 k=0.8。
    /// ⚠️ 係數需落在 0~1,超出會發散(核心不用它,壞的是照抄的軟體)。
    this.spo2SmoothFactor = spo2SmoothFactor;
    this.hrSmoothFactor = hrSmoothFactor;

    // 累積幾筆才算一次:建構時只夾下限(與 Dart 一致),setter 才夾上下限。
    this._computeEvery = computeEvery < Max30102Config.minComputeEvery
      ? Max30102Config.minComputeEvery
      : computeEvery;
  }

  // ── HR(bpm) ↔ 濾波(Hz) 連動:Hz = bpm / 60 ───────────────────────

  /// 濾波下限(Hz)= HR 下限 / 60(連動)。
  /// 🛡 hrMin 若被設成 0(或負數),這裡回 1bpm 而不是 0(它是好幾處的除數)。
  get bandLowHz() { return (this.hrMin < 1 ? 1 : this.hrMin) / 60.0; }
  set bandLowHz(hz) { this.hrMin = Math.round(hz * 60); }

  /// 濾波上限(Hz)= HR 上限 / 60(連動)。同樣有除數底線保護。
  get bandHighHz() { return (this.hrMax < 1 ? 1 : this.hrMax) / 60.0; }
  set bandHighHz(hz) { this.hrMax = Math.round(hz * 60); }

  /// 累積幾筆「新樣本」才算一次(≈ computeEvery / 100 秒)。100 = 1 秒。
  /// 下限 10、上限 computeWindow(500),setter 自動夾住。
  get computeEvery() { return this._computeEvery; }
  set computeEvery(v) {
    const lo = Max30102Config.minComputeEvery;
    const hi = Max30102Config.computeWindow;
    this._computeEvery = v < lo ? lo : (v > hi ? hi : v);
  }

  /// 沉澱期(筆)= baseline 移動平均的視窗寬度 = fs / bandLowHz(預設 200 = 2 秒)。
  get settleSamples() {
    return Math.round(Max30102Config.samplingRateHz / this.bandLowHz);
  }

  /// fingerDeadMs 換算成筆數。
  get fingerDeadSamples() {
    return Math.trunc(this.fingerDeadMs * Max30102Config.samplingRateHz / 1000);
  }

  /// dataHistoryMs 換算成樣本筆數(= 樣本緩衝上限,也是 RR 池的時間界線)。
  get dataHistorySamples() {
    return Math.trunc(this.dataHistoryMs * Max30102Config.samplingRateHz / 1000);
  }
}

module.exports = { Max30102Config };
