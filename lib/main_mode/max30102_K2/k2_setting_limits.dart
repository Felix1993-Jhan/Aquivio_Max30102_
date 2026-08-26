// ============================================================================
// Max30102SettingLimits — 設定值的「監督者」
// ============================================================================
// 這一檔只做一件事:**看住 Max30102Config 裡那些開放調整的參數,不讓它壞掉。**
//
// 為什麼要獨立一檔:
//   · k2_config 負責「有哪些參數、預設值是多少、各自什麼意思」;
//   · 本檔負責「合法範圍在哪、超出去會怎樣、超出去要怎麼處理」。
//   兩件事分開,調參數的人看 config、擔心填錯的人看這裡,不會互相干擾。
//
// 提供兩個入口(用途不同,不要搞混):
//   ① [enforce]  — **會改值**。把超出範圍的夾回合法區間,回報改了什麼。
//                  核心自己會呼叫(建構時 + 每輪計算前),軟體不必管。
//   ② [check]    — **不改值**。只回報「你現在這組設定有什麼問題」,
//                  給軟體在設定畫面上顯示用。
//
// ── 為什麼需要這一層 ────────────────────────────────────────────────
// 這些參數填錯時,核心不會報錯,而是**安靜地壞掉** —— 波形照跳、手指 OK、
// SQI OK,但心率永遠空白。接的人會先懷疑演算法,查很久才發現是自己參數寫反。
// 有些甚至會直接丟例外把 app 帶走(hrMin=0 → 除以零 → Infinity.round())。
// ============================================================================

import 'k2_config.dart';

/// 問題嚴重度。
enum ConfigSeverity {
  /// 不處理的話核心完全不會輸出,或直接崩潰。
  error,

  /// 能跑,但行為八成不是設定的人想要的。
  warn,

  /// 只是提醒一個容易被忽略的事實,設定本身沒問題。
  info,
}

/// 一則設定問題。
typedef ConfigIssue = ({
  /// 欄位名,例如 'hrMax'。
  String field,
  ConfigSeverity severity,

  /// 為什麼有問題(講後果,不要只講「超出範圍」)。
  String message,

  /// 處置說明。
  ///   · [Max30102SettingLimits.enforce] → '已夾為 X'(真的改了)
  ///   · [Max30102SettingLimits.check]   → '未修改;核心執行時將夾為 X'(預告,還沒改)
  ///   · [ConfigSeverity.info]           → **空字串**(本來就沒問題,沒有東西要處置)
  ///
  /// ⚠️ 空字串時呈現層請**不要**印出「未修改」之類的字 —— info 不是問題,
  ///    加上那種尾巴會讓人以為「有狀況但沒處理」。
  String applied,
});

/// 設定值的合法範圍 + 夾值 + 檢查。
class Max30102SettingLimits {
  Max30102SettingLimits._();

  // ══════════════════════════════════════════════════════════════════
  // 合法範圍(改這裡就等於改規格)
  // ══════════════════════════════════════════════════════════════════

  /// 手指門檻:IR 是 18-bit,值域 0~262143。設超過上限就永遠偵測不到手指。
  static const int fingerThresholdMin = 0;
  static const int fingerThresholdMax = 262143;

  /// 手指門檻的「合理」範圍(超出只警告不夾)。太低會把空氣當手指,太高會偵測不到。
  static const int fingerThresholdSaneLo = 10000;
  static const int fingerThresholdSaneHi = 200000;

  /// 心率上下限(bpm)。20~300 已涵蓋所有人類極端值。
  /// hrMin 上限留 [hrGapMin] 的空間給 hrMax,確保夾完必定 hrMin < hrMax。
  static const int hrLo = 20;
  static const int hrHi = 300;

  /// hrMax 至少要比 hrMin 大這麼多,否則生理閘門會把所有拍剔光。
  static const int hrGapMin = 10;

  /// 谷顯著度倍率。≤0 → 門檻歸零,雜訊全被當成谷。
  static const double promRatioMin = 0.05;
  static const double promRatioMax = 2.0;

  /// LED 電流是 8-bit 暫存器值。
  static const int ledCurrentMin = 0;
  static const int ledCurrentMax = 255;

  /// 空轉期(ms)。超過 2 秒還沒壓穩代表接觸有問題,不該靠等。
  static const int fingerDeadMsMin = 0;
  static const int fingerDeadMsMax = 2000;

  /// 核心保留時間(ms)。
  /// 下限 15000:慢心率(50bpm)湊滿 HRV 暖機的 9 拍要 ~11 秒,再留點餘裕;
  /// 低於這個值 HRV 會永遠是 null,而且不會有任何徵兆。
  static const int dataHistoryMsMin = 15000;
  static const int dataHistoryMsMax = 300000;

  /// 手指離開去彈跳批數。<1 等於沒有去彈跳。
  static const int fingerOffBatchesMin = 1;
  static const int fingerOffBatchesMax = 100;

  /// EMA 平滑係數(核心不用,只是別讓照抄的軟體發散)。
  static const double smoothFactorMin = 0.0;
  static const double smoothFactorMax = 1.0;

  // ══════════════════════════════════════════════════════════════════
  // ① enforce — 會改值
  // ══════════════════════════════════════════════════════════════════

  /// 把 [c] 裡超出範圍的值**夾回合法區間**,回傳「改了哪些」。
  ///
  /// 回傳空陣列 = 這組設定原本就合法,一個字都沒動。
  ///
  /// 核心會在建構時與每輪計算前自動呼叫 → 軟體端不必記得叫。
  /// 但「被夾過」這件事只有這個回傳值看得到,所以軟體若想知道自己有沒有填錯,
  /// 請在改完設定後自己叫一次 [check]。
  static List<ConfigIssue> enforce(Max30102Config c) {
    final issues = <ConfigIssue>[];

    void fixInt(String field, int now, int lo, int hi, void Function(int) set,
        ConfigSeverity sev, String why) {
      if (now >= lo && now <= hi) return;
      final v = now < lo ? lo : hi;
      set(v);
      issues.add((
        field: field,
        severity: sev,
        message: '$field($now) 超出合法範圍 [$lo, $hi]。$why',
        applied: '已夾為 $v',
      ));
    }

    void fixDouble(String field, double now, double lo, double hi,
        void Function(double) set, ConfigSeverity sev, String why) {
      if (now >= lo && now <= hi) return;
      final v = now < lo ? lo : hi;
      set(v);
      issues.add((
        field: field,
        severity: sev,
        message: '$field($now) 超出合法範圍 [$lo, $hi]。$why',
        applied: '已夾為 $v',
      ));
    }

    // ── 會崩潰 / 完全沒輸出的 ────────────────────────────────────────
    fixInt('hrMin', c.hrMin, hrLo, hrHi - hrGapMin, (v) => c.hrMin = v,
        ConfigSeverity.error,
        'hrMin=0 會讓 bandLowHz=0 → (fs/0).round() 丟例外,整個 app 崩潰。');

    fixInt('hrMax', c.hrMax, hrLo, hrHi, (v) => c.hrMax = v,
        ConfigSeverity.error,
        'hrMax=0 會讓 minDist 的除法變 Infinity → 丟例外。');

    // hrMax 必須大於 hrMin(上面各自夾完還可能寫反)
    if (c.hrMax < c.hrMin + hrGapMin) {
      final old = c.hrMax;
      c.hrMax = c.hrMin + hrGapMin;
      issues.add((
        field: 'hrMax',
        severity: ConfigSeverity.error,
        message: 'hrMax($old) 必須大於 hrMin(${c.hrMin})。寫反時 RR 上限會小於下限 → '
            '每一拍同時「太長」又「太短」→ 全數被生理閘門剔除,心率永遠空白且不報錯。',
        applied: '已夾為 ${c.hrMax}',
      ));
    }

    fixInt('fingerThreshold', c.fingerThreshold, fingerThresholdMin,
        fingerThresholdMax, (v) => c.fingerThreshold = v, ConfigSeverity.error,
        'IR 是 18-bit(最大 262143),門檻超過就永遠偵測不到手指,畫面一片空白。');

    fixInt('dataHistoryMs', c.dataHistoryMs, dataHistoryMsMin, dataHistoryMsMax,
        (v) => c.dataHistoryMs = v, ConfigSeverity.error,
        '太小會讓 RR 池湊不到 HRV 暖機需要的 9 拍 → HRV 永遠是 null。');

    // ── 行為變質但不會停 ────────────────────────────────────────────
    fixDouble('promRatio', c.promRatio, promRatioMin, promRatioMax,
        (v) => c.promRatio = v, ConfigSeverity.warn,
        '≤0 時顯著度門檻歸零,雜訊全被當成谷 → 心率暴衝。');

    fixInt('ledCurrentRed', c.ledCurrentRed, ledCurrentMin, ledCurrentMax,
        (v) => c.ledCurrentRed = v, ConfigSeverity.warn,
        '是 8-bit 暫存器值,超出會讓封包位元組與 checksum 錯亂。');

    fixInt('ledCurrentIr', c.ledCurrentIr, ledCurrentMin, ledCurrentMax,
        (v) => c.ledCurrentIr = v, ConfigSeverity.warn,
        '是 8-bit 暫存器值,超出會讓封包位元組與 checksum 錯亂。');

    fixInt('fingerDeadMs', c.fingerDeadMs, fingerDeadMsMin, fingerDeadMsMax,
        (v) => c.fingerDeadMs = v, ConfigSeverity.warn,
        '負數等於沒有空轉期(手指壓下去的斜坡會進緩衝);超過 2 秒等於白等。');

    fixInt('fingerOffBatches', c.fingerOffBatches, fingerOffBatchesMin,
        fingerOffBatchesMax, (v) => c.fingerOffBatches = v, ConfigSeverity.warn,
        '<1 等於沒有去彈跳,IR 在門檻上下抖一下就整組清空重數 3.5 秒。');

    fixDouble('spo2SmoothFactor', c.spo2SmoothFactor, smoothFactorMin,
        smoothFactorMax, (v) => c.spo2SmoothFactor = v, ConfigSeverity.warn,
        'EMA 係數超出 0~1 會發散(核心不用它,壞的是照抄的軟體)。');

    fixDouble('hrSmoothFactor', c.hrSmoothFactor, smoothFactorMin,
        smoothFactorMax, (v) => c.hrSmoothFactor = v, ConfigSeverity.warn,
        'EMA 係數超出 0~1 會發散(核心不用它,壞的是照抄的軟體)。');

    // computeEvery 的 setter 本身就會夾 [10, computeWindow];這裡再走一次
    // setter 讓它一定被正規化(例如直接改了 _computeEvery 之外的路徑)。
    final beforeEvery = c.computeEvery;
    c.computeEvery = beforeEvery;
    if (c.computeEvery != beforeEvery) {
      issues.add((
        field: 'computeEvery',
        severity: ConfigSeverity.warn,
        message: 'computeEvery($beforeEvery) 超出 [${Max30102Config.minComputeEvery}, '
            '${Max30102Config.computeWindow}]。大於演算視窗時,兩次計算之間滑過的樣本'
            '不會被任何視窗分析到 → 那幾拍直接消失,而且沒有任何徵兆。',
        applied: '已夾為 ${c.computeEvery}',
      ));
    }

    return issues;
  }

  // ══════════════════════════════════════════════════════════════════
  // ② check — 不改值,只回報
  // ══════════════════════════════════════════════════════════════════

  /// 檢查 [c] 但**不修改任何值**,回傳問題清單(給設定畫面顯示用)。
  ///
  /// 除了 [enforce] 會夾的那些,還會回報「合法但可疑」的組合 —— 那些夾不了,
  /// 因為它們沒有客觀的對錯,只有「你大概不是這個意思」。
  static List<ConfigIssue> check(Max30102Config c) {
    final issues = <ConfigIssue>[];

    // 先用一份複製品跑 enforce,看看會被改到什麼 —— 原本那份不動。
    final copy = Max30102Config(
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
    );
    for (final e in enforce(copy)) {
      issues.add((
        field: e.field,
        severity: e.severity,
        message: e.message,
        // enforce 的措辭是「已夾為」(它真的改了);check 只是預告 →
        // 明講「未修改」讓人知道現在這個值還在,再說核心之後會怎麼處理。
        applied: e.applied.replaceFirst('已夾為', '未修改;核心執行時將夾為'),
      ));
    }

    // ── 合法但可疑(夾不了,只能提醒)────────────────────────────────
    if (c.fingerThreshold < fingerThresholdSaneLo ||
        c.fingerThreshold > fingerThresholdSaneHi) {
      issues.add((
        field: 'fingerThreshold',
        severity: ConfigSeverity.warn,
        message: 'fingerThreshold(${c.fingerThreshold}) 落在常見範圍 '
            '[$fingerThresholdSaneLo, $fingerThresholdSaneHi] 之外。'
            '請先看 HrSpo2Result.irDc 的實際讀數再決定 —— 兩者單位相同。',
        applied: '',
      ));
    }

    // hrMin 的三重身分:很多人只想到「心率下限」而忽略後兩項。
    // 這是**說明不是問題** → applied 留空,呈現層不會加上「未修改」那種尾巴。
    //
    // 數字取自 copy(已夾過)—— 那才是核心實際會用的值;直接用 c 的話,
    // hrMin=0 這種待夾的值會在這裡除以零。
    issues.add((
      field: 'hrMin',
      severity: ConfigSeverity.info,
      message: 'hrMin(${copy.hrMin}) 同時決定三件事:生理閘門 RR 上限 '
          '${(60000 / copy.hrMin).round()}ms、baseline 移動平均視窗寬 '
          '${copy.settleSamples} 筆、以及沉澱期長度(同樣 ${copy.settleSamples} 筆)。'
          '調高 hrMin 會讓 baseline 視窗與沉澱期一起變短。',
      applied: '',
    ));

    if (c.searchBackEnabled) {
      issues.add((
        field: 'searchBackEnabled',
        severity: ConfigSeverity.info,
        message: '補漏拍已開啟。它會在間隔明顯過大時用放寬的門檻回頭找谷 —— '
            '找不到就不補(不造假),但補回來的拍畢竟是推論出來的。預設是關的。',
        applied: '',
      ));
    }

    if (!c.cleanEnabled) {
      issues.add((
        field: 'cleanEnabled',
        severity: ConfigSeverity.info,
        message: '全域 MAD 離群濾已關閉 → 離群拍會直接進 HRV,'
            'SDNN / RMSSD 容易被單一異常拍拉走。',
        applied: '',
      ));
    }

    return issues;
  }

  /// 把問題清單排成可讀文字(丟 log 或顯示用)。空清單回空字串。
  static String format(List<ConfigIssue> issues) {
    if (issues.isEmpty) return '';
    const mark = {
      ConfigSeverity.error: '🔴',
      ConfigSeverity.warn: '🟠',
      ConfigSeverity.info: 'ℹ️',
    };
    return [
      // applied 為空(info)→ 不加尾巴,免得看起來像「有狀況但沒處理」
      for (final e in issues)
        '${mark[e.severity]} [${e.field}] ${e.message}'
            '${e.applied.isEmpty ? "" : " → ${e.applied}"}',
    ].join('\n');
  }
}
