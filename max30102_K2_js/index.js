// ============================================================================
// max30102_K2 (JS 版) 統一匯出
// ============================================================================
// 由 Flutter/Dart 版 lib/main_mode/max30102_K2 的「核心層(不含 UI)」轉譯而來。
// 軟體端一行取用:
//   const { Max30102K2, Max30102Protocol } = require('./max30102_K2_js');
//
// 三層對照:
//   控制層 → Max30102K2 / K2Compute / K2FeedResult          (k2_core)
//   協定   → Max30102Protocol / Max30102RxParser / Max30102Sample (k2_protocol)
//   設定   → Max30102Config / Max30102SettingLimits / ConfigSeverity
//   基礎層 → Max30102Signal / Max30102Sqi / Max30102Algorithm / HrSpo2Result
//            Max30102BeatSeries / Max30102HrvCalculator
// ============================================================================

module.exports = {
  ...require('./k2_config'),
  ...require('./k2_signal'),
  ...require('./k2_sqi'),
  ...require('./k2_hrv_calculator'),
  ...require('./k2_protocol'),
  ...require('./k2_setting_limits'),
  ...require('./k2_algorithm'),
  ...require('./k2_beatseries'),
  ...require('./k2_core'),
};
