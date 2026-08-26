// ============================================================================
// Max30102SettingLimits — 設定值的「監督者」
// ============================================================================
// 【由 Dart 版 k2_setting_limits.dart 轉譯,行為完全一致】
//
// 只做一件事:**看住 Max30102Config 裡那些開放調整的參數,不讓它壞掉。**
//
// 兩個入口(用途不同,不要搞混):
//   ① enforce(c) — **會改值**。把超出範圍的夾回合法區間,回報改了什麼。
//                  核心自己會呼叫(建構時 + 每輪計算前),軟體不必管。
//   ② check(c)   — **不改值**。只回報「你現在這組設定有什麼問題」,給設定畫面顯示用。
//
// ConfigIssue = { field, severity, message, applied }
//   applied:enforce→'已夾為 X';check→'未修改;核心執行時將夾為 X';info→''(空字串)
//   ⚠️ applied 為空(info)時呈現層請**不要**印「未修改」之類的字。
// ============================================================================

const { Max30102Config } = require('./k2_config');

/// 問題嚴重度。
const ConfigSeverity = {
  error: 'error', // 不處理的話核心完全不會輸出,或直接崩潰。
  warn: 'warn', // 能跑,但行為八成不是設定的人想要的。
  info: 'info', // 只是提醒一個容易被忽略的事實,設定本身沒問題。
};

/// 設定值的合法範圍 + 夾值 + 檢查。
class Max30102SettingLimits {
  // ══════════════════════════════════════════════════════════════════
  // 合法範圍(改這裡就等於改規格)
  // ══════════════════════════════════════════════════════════════════

  static fingerThresholdMin = 0;
  static fingerThresholdMax = 262143; // IR 是 18-bit
  static fingerThresholdSaneLo = 10000; // 「合理」範圍(超出只警告不夾)
  static fingerThresholdSaneHi = 200000;

  static hrLo = 20; // 心率上下限(bpm)。20~300 已涵蓋所有人類極端值。
  static hrHi = 300;
  static hrGapMin = 10; // hrMax 至少要比 hrMin 大這麼多

  static promRatioMin = 0.05; // 谷顯著度倍率。≤0 → 門檻歸零。
  static promRatioMax = 2.0;

  static ledCurrentMin = 0; // LED 電流是 8-bit 暫存器值。
  static ledCurrentMax = 255;

  static fingerDeadMsMin = 0; // 空轉期(ms)
  static fingerDeadMsMax = 2000;

  static dataHistoryMsMin = 15000; // 核心保留時間(ms)。低於此 HRV 永遠 null。
  static dataHistoryMsMax = 300000;

  static fingerOffBatchesMin = 1; // 手指離開去彈跳批數。<1 等於沒有去彈跳。
  static fingerOffBatchesMax = 100;

  static smoothFactorMin = 0.0; // EMA 平滑係數(核心不用)
  static smoothFactorMax = 1.0;

  // ══════════════════════════════════════════════════════════════════
  // ① enforce — 會改值
  // ══════════════════════════════════════════════════════════════════

  /// 把 c 裡超出範圍的值**夾回合法區間**,回傳「改了哪些」(ConfigIssue[])。
  /// 回傳空陣列 = 這組設定原本就合法,一個字都沒動。
  static enforce(c) {
    const issues = [];
    const S = Max30102SettingLimits;

    function fixInt(field, now, lo, hi, set, sev, why) {
      if (now >= lo && now <= hi) return;
      const v = now < lo ? lo : hi;
      set(v);
      issues.push({
        field, severity: sev,
        message: `${field}(${now}) 超出合法範圍 [${lo}, ${hi}]。${why}`,
        applied: `已夾為 ${v}`,
      });
    }

    function fixDouble(field, now, lo, hi, set, sev, why) {
      if (now >= lo && now <= hi) return;
      const v = now < lo ? lo : hi;
      set(v);
      issues.push({
        field, severity: sev,
        message: `${field}(${now}) 超出合法範圍 [${lo}, ${hi}]。${why}`,
        applied: `已夾為 ${v}`,
      });
    }

    // ── 會崩潰 / 完全沒輸出的 ──
    fixInt('hrMin', c.hrMin, S.hrLo, S.hrHi - S.hrGapMin, (v) => { c.hrMin = v; },
      ConfigSeverity.error,
      'hrMin=0 會讓 bandLowHz=0 → (fs/0).round() 丟例外,整個 app 崩潰。');

    fixInt('hrMax', c.hrMax, S.hrLo, S.hrHi, (v) => { c.hrMax = v; },
      ConfigSeverity.error,
      'hrMax=0 會讓 minDist 的除法變 Infinity → 丟例外。');

    // hrMax 必須大於 hrMin
    if (c.hrMax < c.hrMin + S.hrGapMin) {
      const old = c.hrMax;
      c.hrMax = c.hrMin + S.hrGapMin;
      issues.push({
        field: 'hrMax', severity: ConfigSeverity.error,
        message: `hrMax(${old}) 必須大於 hrMin(${c.hrMin})。寫反時 RR 上限會小於下限 → ` +
          '每一拍同時「太長」又「太短」→ 全數被生理閘門剔除,心率永遠空白且不報錯。',
        applied: `已夾為 ${c.hrMax}`,
      });
    }

    fixInt('fingerThreshold', c.fingerThreshold, S.fingerThresholdMin,
      S.fingerThresholdMax, (v) => { c.fingerThreshold = v; }, ConfigSeverity.error,
      'IR 是 18-bit(最大 262143),門檻超過就永遠偵測不到手指,畫面一片空白。');

    fixInt('dataHistoryMs', c.dataHistoryMs, S.dataHistoryMsMin, S.dataHistoryMsMax,
      (v) => { c.dataHistoryMs = v; }, ConfigSeverity.error,
      '太小會讓 RR 池湊不到 HRV 暖機需要的 9 拍 → HRV 永遠是 null。');

    // ── 行為變質但不會停 ──
    fixDouble('promRatio', c.promRatio, S.promRatioMin, S.promRatioMax,
      (v) => { c.promRatio = v; }, ConfigSeverity.warn,
      '≤0 時顯著度門檻歸零,雜訊全被當成谷 → 心率暴衝。');

    fixInt('ledCurrentRed', c.ledCurrentRed, S.ledCurrentMin, S.ledCurrentMax,
      (v) => { c.ledCurrentRed = v; }, ConfigSeverity.warn,
      '是 8-bit 暫存器值,超出會讓封包位元組與 checksum 錯亂。');

    fixInt('ledCurrentIr', c.ledCurrentIr, S.ledCurrentMin, S.ledCurrentMax,
      (v) => { c.ledCurrentIr = v; }, ConfigSeverity.warn,
      '是 8-bit 暫存器值,超出會讓封包位元組與 checksum 錯亂。');

    fixInt('fingerDeadMs', c.fingerDeadMs, S.fingerDeadMsMin, S.fingerDeadMsMax,
      (v) => { c.fingerDeadMs = v; }, ConfigSeverity.warn,
      '負數等於沒有空轉期(手指壓下去的斜坡會進緩衝);超過 2 秒等於白等。');

    fixInt('fingerOffBatches', c.fingerOffBatches, S.fingerOffBatchesMin,
      S.fingerOffBatchesMax, (v) => { c.fingerOffBatches = v; }, ConfigSeverity.warn,
      '<1 等於沒有去彈跳,IR 在門檻上下抖一下就整組清空重數 3.5 秒。');

    fixDouble('spo2SmoothFactor', c.spo2SmoothFactor, S.smoothFactorMin,
      S.smoothFactorMax, (v) => { c.spo2SmoothFactor = v; }, ConfigSeverity.warn,
      'EMA 係數超出 0~1 會發散(核心不用它,壞的是照抄的軟體)。');

    fixDouble('hrSmoothFactor', c.hrSmoothFactor, S.smoothFactorMin,
      S.smoothFactorMax, (v) => { c.hrSmoothFactor = v; }, ConfigSeverity.warn,
      'EMA 係數超出 0~1 會發散(核心不用它,壞的是照抄的軟體)。');

    // computeEvery 的 setter 本身就會夾 [10, computeWindow];這裡再走一次 setter。
    const beforeEvery = c.computeEvery;
    c.computeEvery = beforeEvery;
    if (c.computeEvery !== beforeEvery) {
      issues.push({
        field: 'computeEvery', severity: ConfigSeverity.warn,
        message: `computeEvery(${beforeEvery}) 超出 [${Max30102Config.minComputeEvery}, ` +
          `${Max30102Config.computeWindow}]。大於演算視窗時,兩次計算之間滑過的樣本` +
          '不會被任何視窗分析到 → 那幾拍直接消失,而且沒有任何徵兆。',
        applied: `已夾為 ${c.computeEvery}`,
      });
    }

    return issues;
  }

  // ══════════════════════════════════════════════════════════════════
  // ② check — 不改值,只回報
  // ══════════════════════════════════════════════════════════════════

  /// 檢查 c 但**不修改任何值**,回傳問題清單(ConfigIssue[],給設定畫面顯示用)。
  static check(c) {
    const issues = [];
    const S = Max30102SettingLimits;

    // 先用一份複製品跑 enforce,看看會被改到什麼 —— 原本那份不動。
    const copy = new Max30102Config({
      fingerThreshold: c.fingerThreshold,
      hrMin: c.hrMin,
      hrMax: c.hrMax,
      promRatio: c.promRatio,
      computeEvery: c.computeEvery,
      ledCurrentRed: c.ledCurrentRed,
      ledCurrentIr: c.ledCurrentIr,
      fingerDeadMs: c.fingerDeadMs,
      dataHistoryMs: c.dataHistoryMs,
      fingerOffBatches: c.fingerOffBatches,
      searchBackEnabled: c.searchBackEnabled,
      cleanEnabled: c.cleanEnabled,
      spo2SmoothFactor: c.spo2SmoothFactor,
      hrSmoothFactor: c.hrSmoothFactor,
    });
    for (const e of S.enforce(copy)) {
      issues.push({
        field: e.field,
        severity: e.severity,
        message: e.message,
        // enforce 是「已夾為」(真的改了);check 只是預告 → 明講「未修改」。
        applied: e.applied.replace('已夾為', '未修改;核心執行時將夾為'),
      });
    }

    // ── 合法但可疑(夾不了,只能提醒)──
    if (c.fingerThreshold < S.fingerThresholdSaneLo ||
      c.fingerThreshold > S.fingerThresholdSaneHi) {
      issues.push({
        field: 'fingerThreshold', severity: ConfigSeverity.warn,
        message: `fingerThreshold(${c.fingerThreshold}) 落在常見範圍 ` +
          `[${S.fingerThresholdSaneLo}, ${S.fingerThresholdSaneHi}] 之外。` +
          '請先看 HrSpo2Result.irDc 的實際讀數再決定 —— 兩者單位相同。',
        applied: '',
      });
    }

    // hrMin 的三重身分:這是**說明不是問題** → applied 留空。
    // 數字取自 copy(已夾過)—— 那才是核心實際會用的值。
    issues.push({
      field: 'hrMin', severity: ConfigSeverity.info,
      message: `hrMin(${copy.hrMin}) 同時決定三件事:生理閘門 RR 上限 ` +
        `${Math.round(60000 / copy.hrMin)}ms、baseline 移動平均視窗寬 ` +
        `${copy.settleSamples} 筆、以及沉澱期長度(同樣 ${copy.settleSamples} 筆)。` +
        '調高 hrMin 會讓 baseline 視窗與沉澱期一起變短。',
      applied: '',
    });

    if (c.searchBackEnabled) {
      issues.push({
        field: 'searchBackEnabled', severity: ConfigSeverity.info,
        message: '補漏拍已開啟。它會在間隔明顯過大時用放寬的門檻回頭找谷 —— ' +
          '找不到就不補(不造假),但補回來的拍畢竟是推論出來的。預設是關的。',
        applied: '',
      });
    }

    if (!c.cleanEnabled) {
      issues.push({
        field: 'cleanEnabled', severity: ConfigSeverity.info,
        message: '全域 MAD 離群濾已關閉 → 離群拍會直接進 HRV,' +
          'SDNN / RMSSD 容易被單一異常拍拉走。',
        applied: '',
      });
    }

    return issues;
  }

  /// 把問題清單排成可讀文字(丟 log 或顯示用)。空清單回空字串。
  static format(issues) {
    if (issues.length === 0) return '';
    const mark = {
      [ConfigSeverity.error]: '🔴',
      [ConfigSeverity.warn]: '🟠',
      [ConfigSeverity.info]: 'ℹ️',
    };
    // applied 為空(info)→ 不加尾巴,免得看起來像「有狀況但沒處理」
    return issues.map((e) =>
      `${mark[e.severity]} [${e.field}] ${e.message}` +
      `${e.applied === '' ? '' : ` → ${e.applied}`}`
    ).join('\n');
  }
}

module.exports = { ConfigSeverity, Max30102SettingLimits };
