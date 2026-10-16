// ============================================================================
// LocalizationService - 多語言管理服務（自動清洗測試版）
// ============================================================================
// 功能：管理應用程式的多語言字串
// - 語言狀態使用全域共用的 globalLanguageNotifier
// - 涵蓋共用 UI、串口面板、自動清洗流程
// ============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_firmware_tester_unified/shared/language_state.dart';

// 重新匯出 AppLanguage 讓現有 import 不需要改
export 'package:flutter_firmware_tester_unified/shared/language_state.dart';

// ── K2 說明視窗:Lomb-Scargle 的數學細節 ─────────────────────────────
// lf_ms2 與 hf_ms2 是同一條頻譜、同一個 k,只差加總的頻帶,所以兩個視窗
// 共用同一段文字(定義一次,兩個 key 指過來,改的時候不會只改到一邊)。
const _k2LombMathZh = '''為什麼不用 FFT
  FFT 要求等時間間隔取樣，但 RR 是「每一拍一個點」：心跳快時點比較密、慢時比較疏。Lomb-Scargle 可以直接吃不等間隔的點。

P(f) 是什麼
  對每一個候選頻率 f，用最小平方法把一條該頻率的正弦波「貼」到 RR 點上。P(f) = 這條正弦波能解釋多少 RR 的起伏。RR 裡若有以 f 重複的起伏，P(f) 就大。

符號
  tᵢ = 第 i 個 RR 結束的時刻（秒，以第一筆為 0）
  xᵢ = RRᵢ − mean(RR)（去掉平均，只留起伏）
  ω  = 2πf

每一個 f 都做一次
  1. 時間位移 τ：tan(2ωτ) = Σ sin(2ωtᵢ) ÷ Σ cos(2ωtᵢ)
     （讓下面 cos、sin 兩項互不干擾，才能分開擬合）
  2. 投影　　：A = Σ xᵢ·cos ω(tᵢ − τ)　　B = Σ xᵢ·sin ω(tᵢ − τ)
  3. 基底能量：C = Σ cos² ω(tᵢ − τ)　　D = Σ sin² ω(tᵢ − τ)
  4. P(f) = ½ · ( A² ÷ C + B² ÷ D )

掃描
  f 從 0.003 Hz 掃到 0.40 Hz，每 Δf = 0.002 Hz 一格，約 200 格，每一格算一個 P(f)。

VLF / LF / HF 怎麼切出來
  把落在範圍內的格子加起來：
  VLF 極低頻　0.003 ≤ f < 0.04 Hz　週期 25~333 秒
  LF  低頻　　0.04  ≤ f < 0.15 Hz　週期 7~25 秒
  HF  高頻　　0.15  ≤ f < 0.40 Hz　週期 2.5~7 秒
  每個頻帶 = k · Σ P(f)·Δf（只加該範圍內的格子）
  VLF 的週期比 30 秒窗還長，根本量不到；算它只是為了讓三個頻帶的總和完整。

k 是什麼
  Lomb-Scargle 的 P(f) 本身沒有固定單位，大小會隨點數改變，不同窗長之間無法比較。所以把整條頻譜的總和縮放成 RR 的變異數：
  k = RR 變異數 ÷ Σ P(f)·Δf（全部約 200 格）
  RR 變異數 = Σ xᵢ² ÷ (N − 1) = SDNN²
  縮放之後單位變成 ms²，而且 VLF + LF + HF = SDNN²。

附註那筆帳
  「VLF + LF + HF = 總和 ≈ SDNN²」對得上不是巧合，是 k 刻意讓它對上的。可以直接拿上面 sdnn 那一列的值平方來對；對不上就代表頻譜和 SDNN 用的不是同一批 RR。''';

const _k2LombMathEn = '''Why not FFT
  FFT needs evenly spaced samples, but RR gives one point per beat: denser when the heart is fast, sparser when slow. Lomb-Scargle works directly on unevenly spaced points.

What P(f) is
  For each candidate frequency f, a sine wave of that frequency is fitted to the RR points by least squares. P(f) = how much of the RR variation that sine wave explains. If RR swings repeat at f, P(f) is large.

Symbols
  tᵢ = time at which the i-th RR ends (s, first one at 0)
  xᵢ = RRᵢ − mean(RR) (mean removed, only the swings remain)
  ω  = 2πf

For every f
  1. Time shift τ: tan(2ωτ) = Σ sin(2ωtᵢ) ÷ Σ cos(2ωtᵢ)
     (makes the cos and sin terms below independent so each can be fitted separately)
  2. Projections:   A = Σ xᵢ·cos ω(tᵢ − τ)   B = Σ xᵢ·sin ω(tᵢ − τ)
  3. Basis energy:  C = Σ cos² ω(tᵢ − τ)   D = Σ sin² ω(tᵢ − τ)
  4. P(f) = ½ · ( A² ÷ C + B² ÷ D )

Scan
  f runs from 0.003 Hz to 0.40 Hz in steps of Δf = 0.002 Hz, about 200 points, one P(f) each.

How VLF / LF / HF are carved out
  Sum the points falling inside each range:
  VLF very low   0.003 ≤ f < 0.04 Hz   periods 25–333 s
  LF  low        0.04  ≤ f < 0.15 Hz   periods 7–25 s
  HF  high       0.15  ≤ f < 0.40 Hz   periods 2.5–7 s
  Each band = k · Σ P(f)·Δf (only the points in that range)
  VLF periods are longer than a 30 s window, so it cannot really be measured; it is computed only so the three bands add up to the whole.

What k is
  Lomb-Scargle P(f) has no fixed unit and its size changes with the number of points, so windows of different length cannot be compared. The whole spectrum is therefore scaled to the RR variance:
  k = RR variance ÷ Σ P(f)·Δf (all ~200 points)
  RR variance = Σ xᵢ² ÷ (N − 1) = SDNN²
  After scaling the unit is ms², and VLF + LF + HF = SDNN².

The bookkeeping note
  "VLF + LF + HF = total ≈ SDNN²" matching is not a coincidence — k makes it match on purpose. Square the value in the sdnn row above to check; a mismatch means the spectrum and SDNN were computed from different RR.''';

/// 多語言管理服務（單例模式）
class LocalizationService {
  static final LocalizationService _instance = LocalizationService._internal();
  factory LocalizationService() => _instance;
  LocalizationService._internal();

  /// 當前語言通知器（指向全域共用狀態）
  ValueNotifier<AppLanguage> get currentLanguageNotifier => globalLanguageNotifier;

  /// 取得當前語言
  AppLanguage get currentLanguage => globalLanguageNotifier.value;

  /// 設定語言
  void setLanguage(AppLanguage language) {
    globalLanguageNotifier.value = language;
  }

  /// 取得翻譯字串
  String tr(String key) {
    final translations = _translations[currentLanguage];
    return translations?[key] ?? key;
  }

  /// 取得帶參數的翻譯字串（使用 {param} 格式佔位符）
  String trParams(String key, Map<String, dynamic> params) {
    String result = tr(key);
    params.forEach((paramKey, value) {
      result = result.replaceAll('{$paramKey}', value.toString());
    });
    return result;
  }

  /// 翻譯字串對照表
  static final Map<AppLanguage, Map<String, String>> _translations = {
    // ==================== 繁體中文 ====================
    AppLanguage.zhTW: {
      // ---------- App 與頁面標題 ----------
      'app_title': 'MAX30102 交接測試',
      'page_k2': 'MAX30102 K2（交接版）',
      'page_command_control': '命令控制',
      'page_settings': '設定',
      'drawer_title': 'MAX30102 K2 交接版',
      'drawer_subtitle': 'STM32 串口驗證',
      'connection_status': '連接狀態',

      // ---------- 連接相關 ----------
      'connected': '已連接',
      'disconnected': '未連接',
      'not_connected': '未連接',
      'connect': '連接',
      'disconnect': '斷開',
      'select_com_port': '選擇 COM 埠',
      'connecting': '連接中',
      'verifying_device': '驗證裝置...',

      // ---------- Arduino ----------
      'arduino_control': 'Arduino 控制',
      'arduino_connected': 'Arduino 已連接',
      'arduino_disconnected': 'Arduino 已斷開',
      'arduino_connect_failed': 'Arduino 連接失敗，請稍後再試',
      'arduino_port_in_use': '此串口已被 STM32 使用',
      'select_arduino_port': '請先選擇 Arduino 串口',
      'connect_arduino_first': '請先連接 Arduino',
      'arduino_usb_removed': 'Arduino USB 已拔除，連接已自動關閉',
      'arduino_connection_error': 'Arduino 連接可能已斷開\n或連接錯誤',
      'arduino_verifying': 'Arduino 連接中，驗證裝置...',
      'arduino_connecting': 'Arduino 連接中... ({current}/{max})',
      'arduino_port_error': '無法開啟 Arduino 串口',

      // ---------- STM32 ----------
      'stm32_control': 'STM32 控制',
      'stm32_connected': 'STM32 已連接',
      'stm32_disconnected': 'STM32 已斷開',
      'stm32_connect_failed': 'STM32 連接失敗，請稍後再試',
      'stm32_port_in_use': '此串口已被 Arduino 使用',
      'select_stm32_port': '請先選擇 STM32 串口',
      'connect_stm32_first': '請先連接 STM32',
      'stm32_usb_removed': 'STM32 USB 已拔除，連接已自動關閉',
      'stm32_wrong_port': '連接的 COM 埠不是 STM32\n請選擇正確的 COM 埠',
      'stm32_connection_error': 'STM32 連接可能已斷開\n或連接錯誤',
      'stm32_verifying': 'STM32 連接中，驗證裝置...',
      'stm32_connecting': 'STM32 連接中... ({current}/{max})',
      'stm32_firmware_version': 'STM32 韌體版本: {version}',
      'firmware_version': '韌體版本',

      // ---------- COM 埠 ----------
      'no_com_port': '未偵測到任何 COM 埠，請檢查 USB 連接',
      'com_port_detected': '偵測到 {count} 個 COM 埠',
      'new_com_port_detected': '偵測到新 COM 埠: {ports}',

      // ---------- 通用硬體訊息 ----------
      'stop': '停止',
      'all_outputs_toggled': '已{action}全部輸出',
      'output_opened': '開啟',
      'output_closed': '關閉',

      // ---------- Arduino 面板（命令分組）----------
      'cmd_clean_relay': '清洗閥 (cleanrelay)',
      'cmd_container_relay': '容器閥 (containerrelay)',

      // ---------- STM32 面板 ----------
      'command_mode': '命令模式:',
      'mode_start': '啟動 (0x01)',
      'mode_stop': '停止 (0x02)',
      'mode_read': '讀取 (0x03)',
      'id_select_single': 'ID 選擇 (單選):',
      'id_select_multi': 'ID 選擇 (可多選):',
      'select_all': '全選',
      'select_id_to_preview': '請選擇 ID 以預覽命令',
      'command_preview': '命令預覽 (含 Header + CS):',
      'send_start_cmd': '發送啟動命令',
      'send_stop_cmd': '發送停止命令',
      'send_read_cmd': '發送讀取命令',
      'clear_flow': '清Flow',
      'custom_payload': '自訂 Payload',
      'hex_example': '16進制，例: 01 00 04 00 00',
      'sent_arduino_command': '已發送 Arduino 指令: {command}',
      'sent_stm32_read_command': '已發送 STM32 讀取指令: ID {id}',
      'enter_payload': '請輸入 payload (不含 header 和 CS)',
      'hex_length_error': '16進制字串長度必須為偶數',
      'parse_error': '解析錯誤: {error}',

      // ---------- 心跳 / Log 區 ----------
      'continuous_connection': '持續連接中',
      'connection_lost': '連線中斷',
      'command_buttons': '指令按鈕:',
      'receive_log': '接收日誌:',
      'verbose_rx_log': '詳細 RX',

      // ---------- Operation Page ----------
      'operation_auto_connect': '一鍵連線',
      'operation_connected': '連線完成',
      'operation_connect_failed': '連線失敗',
      'operation_stm32_not_connected': 'STM32 未連線',
      'operation_warm_water': '常溫注水',
      'operation_warm_water_desc': '同時啟動水泵 + 常溫水閥',
      'operation_warm_water_sent': '已送出常溫注水指令',
      'operation_stop': '全部停止',
      'operation_stop_desc': '關閉所有 STM32 輸出',
      'operation_stop_sent': '已送出停止指令',

      // ---------- 設定頁 ----------
      'settings': '設定',
      'language': '語言',
      'language_setting': '語言設定',
      'select_language': '選擇語言',

      // ---------- 通用 ----------
      'send': '發送',
      'refresh': '刷新',
      'cancel': '取消',
      'confirm': '確認',
      'error': '錯誤',
      'warning': '警告',
      'success': '成功',
      'loading': '載入中...',
      'clear': '清除',
      'reset': '重置',
      'save': '儲存',
      'apply': '套用',

      // ============================================================
      // 自動清洗流程
      // ============================================================
      'cleaning_workflow_title': '自動清洗測試流程',
      'cleaning_workflow_subtitle': '4 步驟自動清洗 — 可暫停 / 緊急停止',
      'cleaning_stm_workflow_title': '自動清洗測試流程（STM 單獨）',
      'cleaning_stm_workflow_subtitle': '不需 Arduino 連線；relay 改由 STM32 ID16 / ID13 操作',

      // 步驟名稱
      'cleaning_step_1_name': '步驟 1：注水至容器',
      'cleaning_step_2_name': '步驟 2：吸取清潔液',
      'cleaning_step_3_name': '步驟 3：清洗循環',
      'cleaning_step_4_name': '步驟 4：排空',

      // 步驟描述（hover/說明）
      'cleaning_step_1_desc': '開啟 cleanrelay + containerrelay；STM32 注水至容器（水泵 + 常溫水閥）',
      'cleaning_step_2_desc': '保持 containerrelay 導通；STM32 啟動 ID0~9 從容器吸取清潔液',
      'cleaning_step_3_desc': '⚠ 危險步驟。containerrelay 切換為治具方向；STM32 啟動 ID0~9 + 水泵 + 水閥',
      'cleaning_step_4_desc': 'STM32 啟動 ID0~9 進行排空動作',

      // 步驟狀態
      'step_status_idle': '未開始',
      'step_status_running': '執行中',
      'step_status_paused': '已暫停',
      'step_status_completed': '已完成',
      'step_status_emergency': '緊急停止',
      'step_status_awaiting_ack': '等待硬體確認',

      // 控制按鈕
      'workflow_start': '開始流程',
      'workflow_pause': '暫停',
      'workflow_resume': '繼續',
      'workflow_emergency_stop': '緊急停止',
      'workflow_reset': '重置',

      // 步驟卡片內容
      'step_duration_seconds': '時間（秒）',
      'step_stm32_targets': 'STM32 元件',
      'step_arduino_relays': 'Arduino 閥門',
      'step_restore_defaults': '恢復此步驟預設',
      'step_remaining_time': '剩餘 {time}',
      'step_total_time': '總時 {time}',

      // 步驟 3 暫停中按鈕
      'step3_manual_on_all': '一次性開啟 ID0~9',
      'step3_manual_off_all': '一次性關閉 ID0~9',
      'step3_pause_hint': '在暫停期間可手動操作 ID0~9',

      // 確認對話框
      'confirm_proceed_title': '步驟 {step} 已完成',
      'confirm_proceed_message': '下一步驟將執行：\n{actions}\n\n確認進入步驟 {next}？',
      'confirm_proceed_yes': '進入下一步驟',
      'confirm_proceed_no': '取消（停止流程）',
      'confirm_emergency_reset_title': '確認重置',
      'confirm_emergency_reset_message': '請確認所有硬體已恢復安全狀態，可以重新啟動流程嗎？',
      'confirm_emergency_reset_yes': '已確認，解除鎖定',
      'workflow_aborted_by_user': '使用者中止流程',

      // 緊急停止橫幅
      'emergency_banner_title': '緊急停止已觸發',
      'emergency_banner_subtitle': 'STM32 全關 + Arduino 兩 relay 已關閉。請確認硬體狀態，按「重置」解除鎖定。',

      // Workflow log 訊息
      'log_workflow_started': '流程開始',
      'log_workflow_finalizing': '流程結束清理中：關閉 Arduino cleanrelay / containerrelay',
      'log_workflow_completed': '流程全部完成，所有零件已關閉',
      'log_step_started': '步驟 {step} 開始',
      'log_step_finished': '步驟 {step} 倒數結束',
      'log_step_user_aborted': '步驟 {step} 使用者中止',
      'log_paused': '暫停：STM32 全關，Arduino 保持',
      'log_resumed': '繼續：STM32 恢復 [{ids}]',
      'log_emergency_triggered': '緊急停止觸發：STM32 全關 + Arduino cleanrelay/containerrelay 關閉',
      'log_emergency_reset': '已解除緊急停止鎖定',
      'log_step3_manual_on': '步驟 3 手動開啟 ID0~9',
      'log_step3_manual_off': '步驟 3 手動關閉 ID0~9',
      'log_send_stm32_on': '送出 STM32 開啟：[{ids}]（hex: {hex}）',
      'log_send_stm32_off': '送出 STM32 關閉：[{ids}]（hex: {hex}）',
      'log_send_stm32_off_all': '送出 STM32 全關（hex: {hex}）',
      'log_send_arduino': '送出 Arduino：{cmd}',
      'log_countdown_tick': '剩餘 {time}',
      'log_step_idle_outputs': '步驟 {step}：本步驟未啟用任何 STM32 元件',
      'log_step_hw_ready': '步驟 {step}：硬體確認完成，開始倒數',
      // ACK 相關
      'log_ack_wait_arduino': '等待 Arduino ack：{cmd}',
      'log_ack_ok_arduino': 'Arduino ack ✓ {cmd}',
      'log_ack_retry_arduino': '重試 ({n}/3)：Arduino {cmd}',
      'log_ack_retried_arduino_ok': 'Arduino ack ✓ {cmd}（曾重試 {n} 次）',
      'log_ack_failed_arduino': '✗ Arduino {cmd} 未確認，已用盡 3 次重試 — 觸發緊急停止',
      'log_ack_wait_stm32': '等待 STM32 ack：cmd=0x{cmd} mask={mask}',
      'log_ack_ok_stm32': 'STM32 ack ✓ cmd=0x{cmd} mask={mask}',
      'log_ack_retry_stm32': '重試 ({n}/3)：STM32 cmd=0x{cmd}',
      'log_ack_retried_stm32_ok': 'STM32 ack ✓ cmd=0x{cmd}（曾重試 {n} 次）',
      'log_ack_failed_stm32': '✗ STM32 cmd=0x{cmd} 未確認，已用盡 3 次重試 — 觸發緊急停止',
      'log_emergency_warn_stm32': '⚠ STM32 全關 ack 未確認，仍維持鎖定',
      'log_emergency_warn_arduino': '⚠ Arduino {cmd} ack 未確認，仍維持鎖定',
      'log_emergency_finished': '緊急停止流程完成',
      'ack_failed_snackbar': '硬體未確認，請檢查連線後重試',

      // STM32 ID 名稱（顯示在 checkbox 旁）
      'id_label_s0': 's0 (slot 1)',
      'id_label_s1': 's1 (slot 2)',
      'id_label_s2': 's2 (slot 3)',
      'id_label_s3': 's3 (slot 4)',
      'id_label_s4': 's4 (slot 5)',
      'id_label_s5': 's5 (slot 6)',
      'id_label_s6': 's6 (slot 7)',
      'id_label_s7': 's7 (slot 8)',
      'id_label_s8': 's8 (slot 9)',
      'id_label_s9': 's9 (slot 10)',
      'id_label_water': 'water (水泵)',
      'id_label_u0': 'u0 (出水 UVC)',
      'id_label_u1': 'u1 (混合 UVC)',
      'id_label_u2': 'u2 (主 UVC)',
      'id_label_arl': 'arl (常溫水閥)',
      'id_label_crl': 'crl (冷水閥)',
      'id_label_srl': 'srl (氣泡水閥)',
      'id_label_o3': 'o3 (臭氧)',

      // Arduino relay 標籤
      'relay_clean': 'cleanrelay (清洗模式)',
      'relay_container': 'containerrelay (通向容器)',
      'relay_clean_stm': 'cleanrelay (STM32 ID16)',
      'relay_container_stm': 'containerrelay (STM32 ID13)',
      'log_fire_forget_arduino': '送出 Arduino（不等 ack，以防萬一）：{cmd}',
      // 步驟切換 / 單獨測試 / relay 差分相關
      'confirm_each_step_toggle': '每次切換步驟時詢問',
      'step_test_only': '單獨測試此步驟',
      'log_test_single_step': '單獨測試模式：執行步驟 {step}',
      'log_step_transition_auto': '自動進入下一步驟（已關閉詢問）',
      'log_step_partial_off': '步驟 {step} 結束：關閉非 relay GPIO（保留 relay 狀態）',
      'log_relay_activation_delay': 'Relay 啟動延遲 200ms 中...',
      'log_relay_no_change': 'Relay 狀態無變動，跳過切換',
      // 自動跳轉 SnackBar
      'snackbar_auto_proceed': '自動進入步驟 {step}',
      // ---------- Bootloader OTA 分頁 ----------
      'page_bootloader_ota': 'Bootloader OTA',
      'bootloader_section_connect': '連線',
      'bootloader_connect_raw': '連線 (Raw)',
      'bootloader_load_hex': '選擇 .hex',
      'bootloader_no_firmware_loaded': '尚未載入韌體檔',
      'bootloader_section_manual': '手動命令',
      'bootloader_cmd_info': 'INFO',
      'bootloader_cmd_begin': 'BEGIN',
      'bootloader_cmd_start': 'ERASE',
      'bootloader_cmd_end': 'END FLASH',
      'bootloader_cmd_commit': 'MCU RESET',
      'bootloader_cmd_data': 'DATA',
      'bootloader_start_size_hint': 'Size (bytes)',
      'bootloader_manual_hex_hint': '輸入 HEX',
      'bootloader_section_auto_ota': '全自動 OTA',
      'bootloader_start_ota': '開始 OTA',
      'bootloader_abort_ota': '中止',
      'bootloader_reset_failure': '重置錯誤狀態',
      'bootloader_phase_idle': '尚未連線',
      'bootloader_phase_connecting': '連線中…',
      'bootloader_phase_connected': '已連線',
      'bootloader_phase_detecting_role': '偵測角色…',
      'bootloader_phase_triggering': '觸發 Bootloader…',
      'bootloader_phase_waiting_b': "等 'B' marker…",
      'bootloader_phase_verifying_bootloader': '確認 Bootloader 接管…',
      'bootloader_phase_erasing': '擦除 Flash…',
      'bootloader_phase_sending_data': '傳送資料…',
      'bootloader_phase_verifying_magic': '驗證 magic…',
      'bootloader_phase_committing': '提交…',
      'bootloader_phase_verifying_new': '驗證新版本…',
      'bootloader_phase_completed': '✓ 完成',
      'bootloader_phase_failed': '✗ 失敗',
      'bootloader_save_log': '另存',
      'bootloader_cmd_bl_update': 'BL_UPDATE',
      'bootloader_bl_update_confirm_title': '確認觸發 BL V2 更新？',
      'bootloader_bl_update_confirm_message':
          '⚠️ 此命令將讓板子 reset 並進入「BL V2 更新模式」。\n\n'
              '若沒接著立即傳送 BL V2 binary（START 20KB → DATA → END → COMMIT），\n'
              '板子會在 30 秒後 timeout 自動回 App。\n\n'
              '確認要送出 sub-cmd 0x10 嗎？',
      'bootloader_bl_update_confirm_ok': '確認觸發',
      // ---------- Error Report 分頁 ----------
      'page_error_report': '異常偵測',
      'error_report_phase_idle': 'PING 未啟動',
      'error_report_phase_verifying': '驗證階段 (5s/次)',
      'error_report_phase_steady': '穩定 (30s/次)',
      'error_report_ota_busy': 'OTA 進行中',
      'error_report_ping_section': 'PING 控制',
      'error_report_start_ping': '啟動 PING',
      'error_report_stop_ping': '停止 PING',
      'error_report_id_panel': '26 ID 即時面板',
      'error_report_query_all': 'QUERY 全部',
      'error_report_clear_all': 'CLEAR 全部',
      'error_report_read_all': 'READ 全部',
      'error_report_read_all_stop': '中止 READ',
      'error_report_read_offsets': '讀取 OFFSET',
      'error_report_read_adc': 'READ ADC',
      'error_report_read_adc_all': 'READ ADC 全部',
      'error_report_read_adc_all_stop': '中止 ADC',
      'error_report_adc_snapshot_all': 'ADC 快照全部',
      'error_report_query': 'QUERY',
      'error_report_read': 'READ',
      'error_report_set': 'SET',
      'error_report_clear': 'CLEAR',
      'error_report_set_section': 'SET 參數編輯',
      'error_report_no_read_yet': '尚未 READ — 按 [READ] 載入目前值',
      'error_report_device_control': '裝置控制 (ID 0~17 + 25)',
      'error_report_all_on': '全開',
      'error_report_all_off': '全關',
      'error_report_all_on_confirm_title': '確認全開 19 個裝置？',
      'error_report_all_on_confirm_message':
          '⚠️ 此動作會同時啟動 19 個裝置（10 個營養液泵 + 水泵 + 3 個 UVC + 3 個 Relay + Clean + Container）。\n\n'
              '確認硬體連接正確、且測試環境安全嗎？',
      'error_report_all_on_confirm_ok': '確認全開',
      // 設定全部（預設值）— 把「出廠測試預設值」一次寫入 26 個 ID
      'error_report_apply_preset': '設定全部（預設值）',
      'error_report_apply_preset_stop': '中止 SET',
      'error_report_apply_preset_confirm_title': '確認寫入 26 個 ID 的預設檢測設定？',
      'error_report_apply_preset_confirm_message':
          '此操作會逐 ID 送 SET 命令覆蓋韌體目前設定，將「出廠測試預設值」一次寫入 26 個 ID（Group A 全開、B/C/D 依表、E/17/25 保持 DISABLED）。過程中若中斷連線或按中止會停止。',
      'error_report_apply_preset_confirm_ok': '確認寫入',
      // Group 分類進階設定面板（放在接收日誌下方）
      'error_report_group_panel_toggle': '進階：Group 分類設定',
      'error_report_group_panel_expand': '（點擊展開）',
      'error_report_group_panel_collapse': '（點擊收合）',
      'group_apply': '套用此 Group',
      'group_apply_success': '已送出 SET 命令',
      'group_never_read': '尚未讀取',
      'group_last_read': '上次讀取',
      'group_offset_not_read': '尚未讀取（按頁面上方 [讀取 OFFSET] 載入）',
      // Group A：裝置（藍）
      'group_a_title': '裝置',
      'group_a_subtitle': 'ID 0~17（Pump/水泵/UVC/Relay/Clean）+ 25（Container）',
      'group_a_debounce_label': '啟動遮罩',
      'group_a_debounce_hint': '開啟後等 N ms 才開始檢查（跳過 inrush 突波）',
      'group_a_offset_hint': '開機自動校準的基線值；勾了才會 latch OFFSET bit',
      'group_a_thr_off_hint': 'OFF 狀態下 ADC 高於此值視為異常（漏電/短路）',
      'group_a_thr_low_hint': 'ON 狀態下 ADC 低於此值視為異常（斷線/無負載）',
      'group_a_thr_high_hint': 'ON 狀態下 ADC 高於此值視為異常（堵塞/過流）',
      // Group B：流量（綠）
      'group_b_title': '流量',
      'group_b_subtitle': 'ID 18（Flow）— 只在運轉中偵測',
      'group_b_debounce_label': '比對視窗',
      'group_b_debounce_hint': '每 N ms 比一次流量增量（200 的倍數）',
      'group_b_thr_low_hint': '視窗內流量增量 ≤ 此值就報異常',
      // Group C：壓力（橘）
      'group_c_title': '壓力',
      'group_c_subtitle': 'ID 19（CO2 壓力）、20（水壓）',
      'group_c_debounce_label': '連續',
      'group_c_debounce_suffix': '次',
      'group_c_debounce_hint': '連續 N 次符合才報（1 次 = 200ms）',
      'group_c_thr_off_hint': '待機狀態壓力上限',
      'group_c_thr_low_hint': '運轉狀態壓力下限',
      'group_c_baseline_hint': '開機自動校準的壓力基線',
      // Group D：溫度（紅）
      'group_d_title': '溫度',
      'group_d_subtitle': 'ID 21~23（溫度感測器 × 3）',
      'group_d_debounce_label': '連續讀取',
      'group_d_debounce_suffix': '次',
      'group_d_debounce_hint': '連續 N 次都異常才報（每次讀約 1 秒，單位=次數）',
      'group_d_sensor_label': 'SENSOR 檢驗',
      'group_d_sensor_hint': '讀到 85 整數視為感測器斷線',
      'group_d_thr_low_hint': '溫度低於此值視為異常（可為負）',
      'group_d_thr_high_hint': '溫度高於此值視為異常',
      // Group E：漏水（紫）
      'group_e_title': '漏水',
      'group_e_subtitle': 'ID 24（漏水感測器）',
      'group_e_firmware_debounce': '除彈跳: 100ms（韌體固定）',
      'group_e_leak_label': '檢查漏水',
      'group_e_leak_hint': '偵測到漏水訊號就報',
      // 步驟 2 多模式（連續 / 末段靜置 / 脈衝循環）
      'step_run_mode_continuous': '連續',
      'step_run_mode_continuous_rest': '連續 + 末段靜置',
      'step_run_mode_pulsed': '脈衝循環',
      // 連續模式
      'step_continuous_duration': '連續時間（秒）',
      // 連續 + 末段靜置
      'step_cr_run_seconds': '運轉時間（秒）',
      'step_cr_rest_seconds': '末段靜置時間（秒）',
      // 脈衝循環
      'step_pulsed_total_seconds': '總運轉時間（秒）',
      'step_pulsed_run_seconds': '每次運轉秒數',
      'step_pulsed_rest_seconds': '每次靜置秒數',
      'step_pulsed_first_extra': '首次運轉額外秒數',
      'step_pulse_est_cycles': '估計循環次數',
      'step_phase_running': '運轉中',
      'step_phase_resting': '靜置中',
      'step_pulse_cycle': 'Cycle {n}',
      'log_phase_enter_rest': '步驟 {step} 進入靜置（Cycle {cycle}）：關閉 STM32 非 relay GPIO，relay 維持',
      'log_phase_enter_run': '步驟 {step} 進入運轉（Cycle {cycle}）：STM32 ON，本段剩餘 {time}',
      'log_pulse_cycle_done': 'Cycle {cycle} 完成（已累計運轉 {acc} / {total}）',
      'log_resumed_rest': '繼續（Cycle {cycle} 靜置中）：Relay 已復原，等待靜置倒數結束',
      // 緊急停止觸發來源
      'log_emergency_triggered_with_source': '緊急停止已觸發（來源：{source}）',
      'log_emergency_reentry': '重入緊急停止呼叫（已在 emergency 中，來源：{source}）',
      'emergency_trigger_manual': '使用者手動按下緊急停止按鈕',
      'emergency_trigger_user_abort': '使用者在步驟轉場確認對話框選「取消」',
      'emergency_trigger_enter_relay': '進入步驟時 Relay 確認失敗（連續 3 次無 ack）',
      'emergency_trigger_enter_stm32': '進入步驟時 STM32 GPIO 確認失敗（連續 3 次無 ack）',
      'emergency_trigger_pause_stm32': '暫停時 STM32 全關確認失敗（連續 3 次無 ack）',
      'emergency_trigger_resume_relay': '繼續時 Relay 確認失敗（連續 3 次無 ack）',
      'emergency_trigger_resume_stm32': '繼續時 STM32 GPIO 確認失敗（連續 3 次無 ack）',
      'emergency_trigger_finish_stm32': '流程結束清理時 STM32 全關確認失敗',
      'emergency_trigger_finish_clean': '流程結束清理時 Arduino cleanrelay_off 確認失敗',
      'emergency_trigger_finish_container': '流程結束清理時 Arduino containerrelay_off 確認失敗',
      'emergency_trigger_midstep_stm32': '中段步驟結束關閉非 relay GPIO 確認失敗',
      'emergency_banner_source_prefix': '觸發來源',
      // ---------- MAX30102 心跳/血氧分頁 ----------
      'page_max30102': 'MAX30102 心跳/血氧',
      'max30102_measuring': '量測中',
      'max30102_idle': '未量測',
      'max30102_stream_stalled': '資料停滯',
      'conn_inherited': '繼承自動清洗',
      'max30102_start_measure': '開始量測',
      'max30102_stop_measure': '停止量測',
      'max30102_heart_rate': '心率',
      'max30102_spo2': '血氧',
      'max30102_place_finger': '請放手指',
      'max30102_waveform': '波形圖',
      'max30102_window': '視窗',
      'max30102_clear_waveform': '清空波形',
      'max30102_ir_label': '紅外 IR',
      'max30102_red_label': '紅光 RED',
      'max30102_acdc_title': 'AC / DC 即時值',
      'max30102_trim_window': '截尾視窗(筆)',
      'max30102_prom_ratio': '谷顯著度×p70',
      // 各參數欄位聚焦時的說明
      'max30102_help_prom':
          '新版找谷的「顯著度(prominence)」門檻 = 此比例 × p70(谷振幅參考)。量的是「這個谷相對左右最近峰的局部落差」而非離 0 線多遠。調高→只留很突出的真谷、抗重搏切跡/呼吸雙抓(但太高會漏拍)；調低→較敏感。預設 0.5。',
      'max30102_help_led_red':
          '紅光 LED 驅動電流（寫晶片 reg 0x0C）。值越大越亮、訊號越強；太亮會飽和削平波形，太暗訊號弱抓不到脈搏。改值即時送晶片、免重燒。',
      'max30102_help_led_ir':
          '紅外 LED 驅動電流（reg 0x0D）。HR 主要看 IR；太亮飽和、太暗抓不到脈搏。改值即時生效。',
      'max30102_help_finger':
          '判定「有沒有放手指」的 IR 平均門檻。IR DC 高於此值才開始算 HR/SpO2。調高→較不易誤判、輕觸不算；調低→輕觸也算。建議用「不放 vs 貼滿」兩個 IR 值取中間。',
      'max30102_help_poll':
          '每隔多久送一次 QUERY_FIFO 取資料（ms）。建議 ≤200，太長會掉樣本。改後會重啟量測計時器。',
      'max30102_help_algo_window':
          'DC/AC 與 HR/SpO2 計算用的視窗筆數（100Hz，300=3秒）。也是圖上 DC 線的平均筆數，固定不隨 5/10/20s 顯示視窗變。調小→反應快、AC 更敏感；調大→較穩但較慢。',
      'max30102_help_algo_update':
          '每隔多久重算一次 HR/SpO2（ms，滑動視窗）。預設 1000；調小→更新快但較跳。改後重啟計時器。',
      'max30102_help_trim':
          '截尾滑動平均（金黃線）的視窗筆數：視窗內去最高/最低再平均。調大→更平滑、去更多尖刺；調小→貼近原始、只去單一突波。',
      'max30102_help_band_low':
          'HR 帶通濾波下限（Hz）。濾掉低於此頻率的基線漂移；0.5Hz≈30bpm。太高會把慢心跳濾掉。',
      'max30102_help_band_high':
          'HR 帶通濾波上限（Hz）。濾掉高於此頻率的雜訊；4Hz≈240bpm。太低會抹掉快心跳細節。',
      'max30102_help_hr_range':
          '心率合理範圍（bpm）。算出的 HR 超出此範圍視為無效、不顯示（預設 30~240）。',
      'max30102_help_spo2_range':
          '血氧合理範圍（%）。算出的 SpO2 超出此範圍視為無效、不顯示（預設 70~100）。',
      'max30102_waveform_hint':
          '每張圖 4 條線：原始(通道色)、原始DC(通道色長虛線)、截尾滑動平均(金黃)、截尾DC(藍短虛線)　·　左側心率/血氧、DC/AC 皆原始 vs 截尾對照',
      'max30102_params': '可調參數',
      'max30102_params_hint': '⚠️ 手指門檻 / 飽和閾值為暫定值，待實機調整；LED 電流改值即送晶片 reg（免重燒）。',
      'max30102_led_red': '紅光 LED(0x0C)',
      'max30102_led_ir': '紅外 LED(0x0D)',
      'max30102_finger_threshold': '手指 IR 門檻',
      'max30102_poll_ms': '輪詢間隔(ms)',
      'max30102_algo_window': 'DC平均/演算視窗(筆)',
      'max30102_algo_update_ms': '更新間隔(ms)',
      'max30102_band_low': '濾波下限(Hz)',
      'max30102_band_high': '濾波上限(Hz)',
      'max30102_hr_min': 'HR 下限',
      'max30102_hr_max': 'HR 上限',
      'max30102_spo2_min': 'SpO2 下限',
      'max30102_spo2_max': 'SpO2 上限',
      'max30102_verbose_log': '顯示完整 RX hex',
      'max30102_init': 'INIT 初始化',
      'max30102_verify_chip': '驗晶片在線',
      'max30102_query_once': 'QUERY 一次',
      'max30102_read_reg': 'READ_REG',
      'max30102_write_reg': 'WRITE_REG',
      'max30102_reset': 'RESET',
      'max30102_reg_addr': '暫存器位址',
      'max30102_reg_value': '寫入值',
      'max30102_reset_confirm': '確認軟體復位晶片？復位後晶片會進入 POR 休眠（不可用），需再按 [INIT 初始化] 才能恢復運作。一般情況請直接用 INIT。',
      'max30102_log_caps': '(顯示 5000 / 保留 50000)',

      // ---------- MAX30102 K2（交接版驗證頁）----------
      // 頁面標題與區塊
      'k2_title': 'MAX30102 K2(交接版驗證)',
      'k2_sec1': '① 即時數值 + HRV(滾動最近 {sec} 秒)',
      'k2_sec2': '② 快照檢視(存檔重畫)',
      'k2_sec3': '③ 晶片控制',

      // 連線列
      'k2_connected': '● 已連線 {port}',
      'k2_not_connected': '○ 未連線',
      'k2_rescan': '重新掃描',
      'k2_connect': '連線',
      'k2_connecting': '連線中…',
      'k2_disconnect': '斷線',
      'k2_start_measure': '開始量測',
      'k2_stop_measure': '停止量測',
      'k2_clear': '清空',
      'k2_snack_connected': '✅ 已連線 {port}',
      'k2_snack_connect_failed': '❌ 連線失敗 {port}{detail}',
      'k2_port_busy': '（埠可能被其他頁面佔用）',

      // 即時數值區
      'k2_window': '視窗',
      // ── 定長量測(只算這次量測的前 N 秒)──────────────────────────
      'k2_window_range': '10~{max}',
      'k2_fixed_mode': '定長',
      'k2_hide_dead': '隱藏空轉段',
      'k2_hide_dead_tip': '把開頭空轉期那 1.5 秒從圖上拿掉(只是顯示,那段本來就沒進計算)。'
          '先按開始、手指才壓上去時,IR 會從 5 萬爬到 9 萬,縱軸會被那根大波吃掉,'
          '後面真正的脈搏被壓成一條直線。確認過核心在做什麼之後就可以收起來。',
      'k2_snap_full': '完整',
      'k2_snap_full_tip': '完整存檔:快照額外寫入「核心丟掉的開頭段(空轉 + 沉澱)、'
          '定長窗狀態、軟體端衍生的全部數值、HRV 全欄位」。'
          '關閉(預設)時產出的檔案與以往完全相同。'
          '⚠ 這是桌面上的快照檔,與 server 送出去的 JSON 無關。',
      'k2_fixed_hint': '只算這次量測的前 {sec} 秒,之後的不列入。'
          '計時起點 = 核心吐出第一筆乾淨樣本(手指偵測後約 3.5 秒:'
          '空轉 1.5s + 沉澱 2.0s),所以剛開啟時進度不是從 0.0 開始。',
      'k2_fixed_collecting': '收集中 {got} / {sec} s',
      'k2_fixed_frozen': '已凍結 · 本次前 {sec} s',
      'k2_fixed_ended': '量測已結束(手指離開)',
      'k2_fixed_short': '資料不足:只收到 {got} s',
      'k2_fixed_rebased': '波形曾斷層,已重新起算 {n} 次',
      'k2_fixed_sqi_rounds': 'SQI {ok}/{n} 輪',
      'k2_fixed_pre_missing': '開頭未還原',
      'k2_fixed_waiting': '等待本次量測的資料',
      'k2_hrv_fixed': 'HRV 心率變異(本次前 {sec}s)',
      'k2_sec1_fixed': '① 即時數值 + 定長:本次前 {sec} 秒',
      'k2_band_dead': '空轉(丟棄) {sec}s',
      'k2_band_settle': '沉澱(不輸出) {sec}s',
      'k2_band_orient': '判定+累積 {sec}s',
      'k2_band_normal': '計入',
      // 事件標記(垂直線)
      'k2_ev_settled': '沉澱完成 · 開始判定與累積  t={sec}s',
      'k2_ev_release': '方向鎖定 · 壓著的一次釋放  t={sec}s',
      'k2_ev_baseline_ok': 'baseline 可信起點  t={sec}s',
      'k2_actual_span': '實際 {sec}s({beats} 拍)',
      'k2_save_snapshot': '存快照',
      'k2_feed_stats': '進料 #{ver} · RX {rx} · 波形 {wave}',
      'k2_finger_off_hold': '手指已離開 · 保留上次數值\n放回手指後會重新更新',
      'k2_hr_new': '心率(新)',
      'k2_spo2_new': '血氧(新逐拍)',
      'k2_finger': '手指',
      'k2_settling': '沉澱中… 等 baseline 成形\n空轉 {dead}s + 累積 {settle}s',
      // 通道方向(RED/IR 誰是誰)—— 有模組把兩顆 LED 裝反,核心會自己判定
      'k2_orient': '通道',
      'k2_orient_unknown': '判定中',
      'k2_orient_normal': '正常',
      'k2_orient_swapped': '已轉正',
      // 憋氣血氧曲線(驗證波長用:血氧壓低才分得出兩片板子的差)
      'k2_bh_title': '憋氣血氧曲線',
      'k2_bh_start': '開始憋氣',
      'k2_bh_resume': '恢復呼吸',
      'k2_bh_stop': '結束',
      'k2_bh_clear': '清除',
      'k2_bh_waiting': '記錄中… 等待血氧資料',
      'k2_bh_press_start': '按「開始憋氣」開始記錄',
      'k2_bh_min': '最低',
      'k2_bh_drop': '降幅',
      'k2_bh_recover': '恢復',
      'k2_bh_recovering': '恢復中',
      'k2_bh_previous': '上一次(對照)',
      'k2_bh_abort': '⚠ 手指離開,核心已歸零 → 時間軸接不起來,錄製中止。',
      'k2_bh_hint': '手指放好、等「通道」判定完成再按開始。錄完按結束,'
          '換一片板子再錄一次就會疊在同一張圖上比對。',

      // HRV 面板
      'k2_hrv_short': 'HRV 心率變異(最近 {sec}s)',
      'k2_hrv_insufficient': '— 拍數不足({beats} 拍;暖機需 ≥9)',
      'k2_hrv_score': 'HRV 分數',
      'k2_mean_rr': '平均 RR',
      'k2_mean_hr': '平均 HR',
      'k2_beats_total': '累積拍數',
      'k2_valid_pairs': '有效對數',
      'k2_skipped': ' (跳{n})',

      // 快照檢視
      'k2_snap_hint': '把存過的快照點開,用同一套圖表重畫波形、谷、RR 趨勢',
      'k2_scanning': '掃描中…',
      'k2_refresh': '重新整理',
      'k2_snap_empty': '還沒有快照 —— 上面按「存快照」後,按這裡的「重新整理」',
      'k2_snap_saved': '已存快照:{name}',
      'k2_snap_save_failed': '快照存檔失敗',
      'k2_snap_saved_at': '存於 {time}',
      'k2_snap_summary': '波形 {wave} 筆 · 谷 {trough} · RR {rr} 拍',
      'k2_delete': '刪除',
      'k2_window_sec': '{sec} 秒視窗',
      'k2_hr': '心率',
      'k2_spo2': '血氧',

      // 晶片控制
      'k2_btn_init': 'INIT 初始化',
      'k2_btn_query': 'QUERY 一次',
      'k2_btn_read_reg': 'READ_REG(IR LED)',
      'k2_btn_apply_led': '套用 LED 電流',
      'k2_btn_reset': 'RESET',
      'k2_params_title': '可調參數(K2 精簡版)',
      'k2_btn_check': '檢查設定',
      'k2_log_title': '接收日誌',
      'k2_clear_log': '清除',

      // 可調參數欄位
      'k2_f_finger_threshold': '手指門檻',
      'k2_f_finger_threshold_hint': '對照 irDc',
      'k2_f_hr_min': 'HR 下限(bpm)',
      'k2_f_hr_max': 'HR 上限(bpm)',
      'k2_f_filter_hint': '濾波 {hz}Hz',
      'k2_f_prom_ratio': '谷顯著度',
      'k2_f_compute_window': '計算窗(筆)',
      'k2_f_fixed': '固定',
      'k2_f_compute_every': '累積筆數',
      'k2_f_finger_dead': '空轉期(ms)',
      'k2_f_settle_samples': '沉澱期(筆)',
      'k2_f_settle_hint': '由 HR 下限決定',
      'k2_f_data_history': '保留時間(ms)',
      'k2_f_data_history_hint': '樣本+RR 共用',
      'k2_f_finger_off_batches': '離開去彈跳(批)',
      'k2_f_led_red': 'LED 紅',
      'k2_f_led_ir': 'LED 紅外',
      'k2_f_poll_interval': '輪詢間隔(ms)',
      'k2_f_poll_hint': 'UI 層,非核心',
      'k2_sw_searchback': '補漏拍 search-back',
      'k2_sw_clean': '離群濾 clean',

      // 圖表
      'k2_chart_rr_trend': 'RR 趨勢 (ms)',
      'k2_chart_waiting': '等待資料…',
      'k2_chart_waiting_beats': '等待資料…（需數拍以上）',
      'k2_chart_mean': '平均 {v}',
      'k2_chart_now': '現 {v}ms  ({beats}拍)',
      'k2_chart_poincare_axis': 'X=上拍  Y=這拍 (ms)',
      'k2_chart_prev_beat': '上拍→',
      'k2_chart_this_beat': '這拍',
      'k2_chart_big_jump': '● 紅=大跳',
      'k2_chart_no_channel': '請開啟 HR(紅外) 或 SpO2(紅光)',
      'k2_chart_fixed_amp': '固定 ±{v}',
      'k2_chart_baseline': 'baseline(中線)',
      'k2_chart_peak': '峰 {v}',
      'k2_chart_trough': '谷 {v}',
      'k2_chart_p2p': 'p2p {v} · 建議固定 ±{amp}',

      // 設定檢查日誌
      'k2_chk_all_ok': '✅ 設定檢查:全部合法',
      'k2_chk_all_ok_notes': '✅ 設定檢查:全部合法({notes} 則提醒)',
      'k2_chk_problems': '── 設定檢查:{problems} 則需處理{notes} ──',
      'k2_chk_notes_tail': ' + {notes} 則提醒',
      'k2_chk_ui_ref': '   ↳ UI:{where}',
      'k2_chk_field_ref': '「{label}」欄位',
      'k2_chk_switch_ref': '「{label}」開關',
      'k2_chk_ui_smooth': '(UI 平滑係數,核心不使用)',
      'k2_sw_log': '⚙ {label} → {state}',
      'k2_state_on': '開',
      'k2_state_off': '關',

      // 量測日誌（adapter）
      'k2_log_parse_error': '⚠ 解析錯誤:{reason}',
      'k2_log_start': '🟢 開始量測(探測板子中:0x31 優先,逾時退 0x30)',
      // 推薦飲品預覽（離線推演，不連外）
      'glass_setting': '玻璃質感',
      'glass_setting_hint': '所有頁面改用半透明 + 背景模糊的樣式。'
          '⚠️ 每一層模糊都會讓畫面每一幀多做一次重算 —— '
          '如果量測中發現波形圖變頓，先把這個關掉。',
      'k2_drink_vote_head': '為什麼命中這一條（★ = 對方提示詞寫死的門檻，其餘為本地自訂）',
      'k2_drink_vote_sym': '交感 +1',
      'k2_drink_vote_para': '副交感 +1',
      'k2_drink_vote_override': '否決權觸發',
      'k2_drink_vote_not_triggered': '未觸發否決權',
      'k2_drink_vote_none': '不投票',
      'k2_drink_vote_unused': '規則未引用',
      'k2_drink_tally': '交感 {s} 票 · 副交感 {p} 票',
      'k2_drink_tally_override': '心率偏高 → 否決權生效，其餘訊號一律不計',
      'k2_drink_eff_hr': '偏高是否決權：只給補水、非氣泡、非刺激（electrolytes），蓋掉其他所有訊號；也是 caffeine / cascara 的迴避條件',
      'k2_drink_eff_lfhf': '唯一的硬數字。> 1.5 投交感票，也是 caffeine 的迴避條件；≤ 1.5 只是不投交感，不會投副交感',
      'k2_drink_eff_stress': '高 → 交感票，排除 caffeine / cascara / bcaa / whey / lCarnitine，偏向 lutein；低 → 副交感票。門檻參考 Garmin 壓力分段（> 75 高、≤ 50 低）',
      'k2_drink_eff_pns': '由 RMSSD 換算，門檻也由 RMSSD 20 / 50 ms 換算而來。低 → 交感票，是 caffeine / cascara 的迴避條件；高 → 副交感票，解鎖能量與表現類',
      'k2_drink_eff_rmssd': 'HRV 之一（規則寫 high HRV — SDNN/RMSSD）。高 → 副交感票；低 → 交感票。雜訊會把它推高',
      'k2_drink_eff_sdnn': 'HRV 之一（規則寫 high HRV — SDNN/RMSSD）。高 → 副交感票；低 → 交感票。雜訊同樣會把它推高',
      'k2_drink_eff_ans': '由 LF/HF 換算（> 64.6 ⇔ LF/HF > 1.5），規則只用 LF/HF 的寫法，再投一次就是同一票算兩次。低 = 偏副交感，但模型可能誤讀成「分數不足」',
      'k2_drink_eff_conf': '規則與程式都沒有引用，不影響命中哪一條',
      'k2_fx_title': '公式帶入（送給 LLM 的欄位與它們的來源）',
      'k2_fx_note_power': 'P(f) = Lomb-Scargle 週期圖；k 讓三個頻帶加起來等於 RR 的變異數：VLF {vlf} + LF {lf} + HF {hf} = {total} ≈ SDNN² = {s2}',
      'k2_fx_note_hf_cyc': 'HF 下緣（0.15 Hz）在這段裡有 {cyc} 個週期',
      'k2_fx_note_not_sent': '我們自己的單位（ms²），不送給 LLM，只是 lf_hf 的分子分母。送出的 {api} 換成對方單位，見下方',
      'k2_fx_note_aquivio': 'JSON 送出的值（對方單位，與左側欄 LF 同一個數），不在 LLM 提示詞裡。× 1e-6：ms² → s²（對方的 RR 用秒）；× 1024：對方的 Welch 頻譜直接加總各格、沒乘格寬 Δf = 4 / 4096 Hz，等於多乘 1/Δf = 1024',
      'k2_fx_note_aquivio_hf': 'JSON 送出的值（對方單位，與左側欄 HF 同一個數），換算同上',
      'k2_fx_rolling': '滾動模式：最近 {sec} 秒，每秒重算',
      'k2_fx_fixed': '定長模式：與左側同一段，收滿後停在量測結束那一刻',
      'k2_fx_round': '畫面四捨五入顯示，實際送出的是完整浮點數',
      'k2_fx_legend': '深色 = LLM 提示詞裡的 8 個欄位；淡色 = 算它們用的中間量',
      'k2_fx_col_field': '欄位',
      'k2_fx_col_inputs': '帶入',
      'k2_fx_col_formula': '公式',
      'k2_fx_col_sub': '代入數值',
      'k2_fx_col_result': '結果',
      'k2_fx_note_sdnn': 'N = RR 間隔數（拍數 − 1）；樣本標準差，分母 N − 1',
      'k2_fx_note_rmssd': 'P = 時間上相鄰（中間沒有漏拍）的相鄰對，目前 {pairs} / {total} 對',
      'k2_fx_note_lfhf': 'Lomb-Scargle 頻譜。本段涵蓋 {span} 秒，LF 下緣（0.04 Hz）只有 {cyc} 個週期',
      'k2_fx_note_clamp': '算出 {raw}，超出 0 ~ 100 → 夾到 {v}',
      'k2_fx_note_snr': 'P_signal = 基頻 f₀（= 心率 / 60）與 2f₀ 各 ±{hw} Hz 內的功率；P_noise = {lo} ~ {hi} Hz 內其餘的功率。兩個功率在核心內部，未導出',
      'k2_fx_note_conf': '只看 snr_db，與拍數無關（看拍數的是 confidence_by_beats，不送給 LLM）',
      'k2_fx_na_beats': '拍數不足 {min}（目前 {n}）',
      'k2_fx_na_spec': 'RR 間隔不足 8 個，算不出頻譜',
      'k2_fx_na_snr': '波形不足 5 秒，或還沒有心率',
      'k2_fx_na_dep': '依賴的 {dep} 還沒有數值',
      'k2_fx_na_pairs': '沒有任何連續相鄰對，RMSSD = 0，對數無定義',
      // ---------- 公式帶入面板的「?」說明視窗 ----------
      'k2_help_tag_llm': 'LLM 提示詞裡的欄位',
      'k2_help_tag_mid': '中間量（不在 LLM 提示詞裡）',
      'k2_help_sec_what': '這是什麼',
      'k2_help_sec_how': '怎麼算',
      'k2_help_sec_use': '在推薦裡的角色',
      'k2_help_sec_note': '要注意的地方',
      'k2_help_sec_ref': '參考值',
      'k2_help_sec_math': '數學細節',
      'k2_help_box_formula': '公式',
      'k2_help_box_sub': '代入',
      'k2_help_box_result': '結果',
      'k2_help_box_inputs': '帶入參數',
      'k2_help_lf_ms2_math': _k2LombMathZh,
      'k2_help_hf_ms2_math': _k2LombMathZh,

      'k2_help_mean_hr_what': '平均心率：這一段裡所有 RR 間隔（兩拍之間的時間）取平均，換算成每分鐘幾下。',
      'k2_help_mean_hr_how': '1. 從 IR 波形找出每一拍的谷底\n2. 相鄰兩個谷底的時間差 = 一個 RR 間隔，也就是兩拍之間的間距（ms）\n3. 濾掉漏拍、切拍造成的離群值\n4. mean(RR) = 平均間距：這一段所有 RR 間隔加總 ÷ 個數\n5. 心率 = 60000 ÷ mean(RR)\n\n60000 從哪來：兩邊的單位不同。間距的單位是「毫秒」，心率的單位是「每分鐘幾下」。1 分鐘 = 60 秒 = 60000 毫秒，所以 60000 ÷ 平均間距，就是「1 分鐘裡裝得下幾個間距」= 每分鐘幾拍。\n例：平均間距 885.8 ms → 60000 ÷ 885.8 = 67.7 bpm；間距越短，1 分鐘裝得越多，心率越快。',
      'k2_help_mean_hr_use': '提示詞的「Heart rate: X bpm」。對方規則「Elevated heart rate」是否決權：心率偏高時不管其他訊號，只給補水、非氣泡、非刺激性的飲品，也是 caffeine / cascara 的迴避條件。對方沒寫多少算偏高，由 LLM 自己判斷；我們 ② 的推演用 100 bpm。',
      'k2_help_mean_hr_note': '它量的是「當下」，不是靜息心率：量測前剛走動、說話、緊張，都會讓它偏高，進而觸發否決權。是由平均 RR 換算的，與畫面上逐拍的即時心率可能差 1~2 bpm。',
      'k2_help_mean_hr_ref': '成人靜息 60~100 bpm；> 100 bpm 為心搏過速（臨床定義）。',

      'k2_help_sdnn_what': 'RR 間隔的標準差：整段心跳快慢起伏的「總量」，同時包含呼吸造成的快速起伏，以及更慢的變化。',
      'k2_help_sdnn_how': '1. 取這一段的 N 個 RR 間隔\n2. 算平均\n3. 每個 RR 減平均、平方、全部加總\n4. 除以 N − 1（樣本標準差），再開根號',
      'k2_help_sdnn_use': '提示詞的「HRV SDNN: X ms」。對方規則把它和 RMSSD 並列為 HRV：high HRV — SDNN/RMSSD → 副交感／恢復良好；low HRV → 交感／壓力。',
      'k2_help_sdnn_note': '短窗下最不可靠的 HRV 指標：SDNN 含有慢變化，窗越短量到的越少。文獻建議至少 30 秒，PPG 研究要 240 秒才穩定，我們的窗是 12~30 秒。漏拍或雜訊也會把它推高。',
      'k2_help_sdnn_ref': 'Nunan 2010 短時（5 分鐘）常模：平均 50 ± 16 ms（範圍 32~93）。隨年齡下降。',

      'k2_help_rmssd_what': '相鄰兩拍差值的均方根：只看「這一拍到下一拍」的快速變化，主要反映迷走神經（副交感）的活性。',
      'k2_help_rmssd_how': '1. 只取時間上相鄰（中間沒有漏拍）的兩拍\n2. 後一拍 − 前一拍，平方，全部加總\n3. 除以相鄰對數 P，再開根號',
      'k2_help_rmssd_use': '提示詞的「RMSSD: X ms」。它也是 pns 的唯一來源，又透過 pns 決定 stress 的 60%——一個 RMSSD 會同時影響提示詞裡的三行。',
      'k2_help_rmssd_note': '對雜訊非常敏感：一個誤判的谷底會造成兩個很大的相鄰差，平方後把 RMSSD 大幅推高 → 被讀成「恢復良好」→ 推向刺激類飲品。刻意深呼吸、慢呼吸也會讓它暴增（呼吸性竇性心律不整）。',
      'k2_help_rmssd_ref': 'Nunan 2010：平均 42 ± 15 ms（範圍 19~75）。10~30 秒的超短時 RMSSD 有文獻驗證（Munoz 2015，與 5 分鐘相關 r = 0.94）。隨年齡下降。',

      'k2_help_lf_ms2_what': '低頻（0.04~0.15 Hz，週期約 7~25 秒）的心率變化功率，單位 ms²。主要來自血壓調節（壓力反射），交感與副交感都有參與。',
      'k2_help_lf_ms2_how': '1. 把 RR 依發生的時間排成序列（不等間隔，所以不能直接 FFT）\n2. 用 Lomb-Scargle 週期圖估計每個頻率的功率 P(f)\n3. 0.04~0.15 Hz 內的 P(f)·Δf 加總\n4. 乘上 k，讓 VLF + LF + HF 剛好等於 RR 的變異數（SDNN²）',
      'k2_help_lf_ms2_use': '不送給 LLM。它只是 lf_hf 的分子；換成對方單位後以 lf 欄位送進 JSON。',
      'k2_help_lf_ms2_note': '0.04 Hz 一個週期就要 25 秒，12~30 秒的窗連一個完整的慢波都裝不下，所以這個值在我們的窗長下很不可靠。短時 HRV 的標準量測長度是 5 分鐘，原因就在這裡。',

      'k2_help_hf_ms2_what': '高頻（0.15~0.40 Hz，週期 2.5~6.7 秒）的心率變化功率，單位 ms²。對應每分鐘 9~24 次的呼吸，也就是呼吸性竇性心律不整，主要反映迷走神經。',
      'k2_help_hf_ms2_how': '與 lf_ms2 相同，只是頻帶換成 0.15~0.40 Hz。',
      'k2_help_hf_ms2_use': '不送給 LLM。它只是 lf_hf 的分母；換成對方單位後以 hf 欄位送進 JSON。',
      'k2_help_hf_ms2_note': '呼吸頻率決定它落在哪裡：呼吸慢於每分鐘 9 次（例如刻意深呼吸）時，呼吸造成的變化會掉進 LF 頻帶 → LF/HF 變大 → 被誤讀成「交感」。30 秒窗約有 4.5 個 HF 週期，比 LF 可靠。',

      'k2_help_lf_what': 'lf_ms2 換成對方（攝影機端 aquivio-vitals）的單位，是 JSON 裡 lf 欄位實際送出的值，與左側欄「LF (lf)」同一個數。',
      'k2_help_lf_how': 'lf_ms2 × 1e-6 × 1024\n· × 1e-6：ms² → s²（對方的 RR 用秒）\n· × 1024：對方用 Welch 頻譜（fs = 4 Hz、nfft = 4096）時直接把各格加總、沒有乘上格寬 Δf = 4 / 4096 Hz，等於多乘了 1/Δf = 1024',
      'k2_help_lf_use': '送進軟體端的 JSON，但不在 LLM 提示詞裡。換單位的目的是讓同名欄位在攝影機機台和我們這邊的數量級一致，下游比較時才不會差一千倍。',
      'k2_help_lf_note': '1024 綁定對方 nfft = 4096、fs = 4 的設定，對方改了設定，這個係數也要跟著改。兩邊估計頻譜的方法不同（Welch 對 Lomb-Scargle），只保證數量級一致，不保證相等。',

      'k2_help_hf_what': 'hf_ms2 換成對方的單位，是 JSON 裡 hf 欄位實際送出的值，與左側欄「HF (hf)」同一個數。',
      'k2_help_hf_how': 'hf_ms2 × 1e-6 × 1024，換算方式與 lf 相同。',
      'k2_help_hf_use': '送進軟體端的 JSON，但不在 LLM 提示詞裡。',
      'k2_help_hf_note': '與 lf 相同：係數綁定對方的頻譜設定，只保證數量級一致。',

      'k2_help_lf_hf_what': 'LF 功率 ÷ HF 功率。傳統上被當成「交感／副交感平衡」的指標：大於 1 偏交感、小於 1 偏副交感。',
      'k2_help_lf_hf_how': 'lf_ms2 ÷ hf_ms2。單位在比值裡約掉，所以用 lf ÷ hf 算出來也一樣。',
      'k2_help_lf_hf_use': '提示詞的「ANS balance (LF/HF X)」。這是對方規則裡唯一寫死的數字：LF/HF > 1.5 → 交感主導，也是 caffeine 的迴避條件。它也是 ans 的唯一來源。',
      'k2_help_lf_hf_note': '三個問題疊在一起：\n① 窗長：LF 在 12~30 秒的窗裡量不準（見 lf_ms2）\n② 生理意義有爭議：Billman 2013 指出 LF/HF 不能準確代表交感／副交感平衡\n③ 門檻：健康人靜息平均約 2.8，用 1.5 當門檻，大多數健康、放鬆的人都會被判成交感主導\n我們有送 lf_reliable 旗標說明可信度，但對方沒有讀它。',
      'k2_help_lf_hf_ref': 'Nunan 2010 短時（5 分鐘）常模：平均 2.8 ± 2.6（範圍 1.1~11.6）。',

      'k2_help_pns_what': '對方的「副交感／恢復」分數（0~100，對方畫面上叫 Recovery）。它就是 RMSSD 換成對數尺度，沒有加入任何新資訊。',
      'k2_help_pns_how': '(log₁₀ RMSSD − 1) ÷ (log₁₀ 80 − 1)，夾在 0~1 之間，再 × 100。\nRMSSD 10 ms → 0 分、80 ms → 100 分，超出兩端就夾住。',
      'k2_help_pns_use': '提示詞的「PNS / recovery: X/100」。對方規則：low PNS → 交感；high PNS → 副交感。它也占 stress 的 60%。',
      'k2_help_pns_note': 'RMSSD ≥ 80 ms 一律 100 分（撞頂），分不出「真的很好」和「被雜訊推高」。公式來自 aquivio-vitals，原始註解自稱 heuristic、not clinical。與左側欄的「副交感 z」（Kubios 式 z-score）是不同的東西，尺度不能互相比較。',
      'k2_help_pns_ref': '常模平均 RMSSD 42 ms 換算約 69 分。',

      'k2_help_ans_what': '對方的「自律神經平衡」分數（0~100）。它就是 LF/HF 取對數後縮放，分數越高越偏交感。',
      'k2_help_ans_how': '0.5 + log₂(LF/HF) ÷ 4，夾在 0~1 之間，再 × 100。\nLF/HF 0.25 → 0 分、1 → 50 分、4 → 100 分。',
      'k2_help_ans_use': '提示詞的「ANS score X/100」，與 LF/HF 印在同一行。對方規則沒有直接點名它，但它占 stress 的 40%。',
      'k2_help_ans_note': '方向容易誤讀：低分代表偏副交感（放鬆），不是「分數不足」。LF/HF 的所有問題它全部繼承。LF/HF > 1.5 等於 ans > 64.6。',

      'k2_help_stress_what': '對方的「壓力」分數（0~100）。由 pns 和 ans 加權混合而成，不是獨立的量測。',
      'k2_help_stress_how': '0.6 × (100 − PNS) + 0.4 × ANS，夾在 0~100。',
      'k2_help_stress_use': '提示詞的「Stress: X/100」。對方規則：high stress → 交感，排除 caffeine、cascara、bcaa、whey、lCarnitine；low stress → 副交感。',
      'k2_help_stress_note': '展開來就是 60% RMSSD + 40% LF/HF，所以它和 rmssd、pns 不是三個獨立的證據。RMSSD ≥ 80 ms 時 PNS = 100，stress 最高只剩 40，一定被讀成低壓力。左側欄另有一個 Baevsky 壓力指數（stress_baevsky），那是不同的東西，也不送給 LLM。',
      'k2_help_stress_ref': '對方的量表沒有文獻依據。可參考 Garmin 的 0~100 壓力分段：0~25 休息、26~50 低、51~75 中、76~100 高（② 的推演門檻即採用此分段）。',

      'k2_help_snr_db_what': '波形的訊噪比（dB）：脈搏頻率上的功率，和其他頻率上的功率之比。衡量波形「乾不乾淨」。',
      'k2_help_snr_db_how': '1. IR 原始波形減平均、乘 Hann 窗\n2. FFT（補零到 2 的冪次）\n3. 在 0.5~4 Hz 內，f₀（= 心率 ÷ 60）與 2f₀ 各 ±0.2 Hz 的功率算「訊號」，其餘算「雜訊」\n4. 10 · log₁₀(訊號 ÷ 雜訊)',
      'k2_help_snr_db_use': '不送給 LLM，但 confidence 完全由它決定。',
      'k2_help_snr_db_note': '它其實也在量「心率穩不穩」：訊號窗只有 ±0.2 Hz（約 ±12 bpm），整段心率起伏超過這個範圍，脈搏能量就會落到窗外被算成雜訊——深呼吸造成的心率擺動就會讓 SNR 下降。頻帶與門檻照抄攝影機端 aquivio-vitals，是為 rPPG 校準的，和我們的接觸式 PPG 不一定對應。',
      'k2_help_snr_db_ref': 'aquivio-vitals 原始註解：低於約 6 dB 時，RMSSD 的雜訊底線會超過典型的靜息 HRV。',

      'k2_help_confidence_what': '讀數可信度：good / rough / very rough。',
      'k2_help_confidence_how': '只看 snr_db：\n≥ 6 dB → good\n≥ 1 dB → rough\n其餘 → very rough\nsnr_db 算不出來 → null',
      'k2_help_confidence_use': '提示詞的「Reading confidence: X」。但對方的規則和程式都沒有任何一處用到它——模型看得到，卻沒有被告知該怎麼用。',
      'k2_help_confidence_note': '與拍數無關。看拍數的是另一個欄位 confidence_by_beats，不送給 LLM。所以「good」不代表樣本夠多，只代表波形的頻譜乾淨。',

      'k2_drink_btn': '推薦飲品',
      'k2_drink_title': '這組數字會換到哪一杯？',
      'k2_drink_sec_payload': '① 會送出去的欄位（逐字照對方模板）',
      'k2_drink_sec_rule': '② 會命中的規則',
      'k2_drink_sec_picks': '③ 會被偏好 / 排除的飲品',
      'k2_drink_favored': '偏好',
      'k2_drink_avoided': '排除',
      'k2_drink_close': '關閉',
      'k2_drink_apply_stock': '只看機器有的',
      'k2_drink_stock_row': '機器庫存（模擬）',
      'k2_drink_none_stocked': '⚠️ 機器裡沒有任何入圍的營養劑 —— 實際上對方會拿不到可選的 slug',
      'k2_drink_no_avoid_note': 'ℹ️ 11 款裡有 5 款（electrolytes / collagen / lutein / creatine / fiber）'
          '在對方知識庫裡**根本沒有 avoidWhen 欄位**，所以永遠不會出現在「排除」。\n'
          '「不在排除清單」不等於「被評估過而且通過」。\n'
          '另外 electrolytes 的依據有兩條來源且不一致（自己的 bestFor 只講心率偏高，\n'
          '但提示詞的交感規則又把 hydration/mineral 包進去），實際上幾乎永遠是候選。',
      'k2_drink_rule_hr': '心率偏高 → 一律補水、非氣泡、非刺激性（對方寫明這條**不管其他訊號**）',
      'k2_drink_rule_sym': '交感主導／壓力 → 恢復與鎮靜類：補水礦物、抗氧化、恢復。**禁咖啡因與任何刺激物**',
      'k2_drink_rule_para': '副交感／恢復良好 → 能量與表現類：刺激物、胺基酸、蛋白質、代謝',
      'k2_drink_rule_neutral': '中性／混合，沒有主導訊號 → 一般支持類，但仍偏向現有最強的那個訊號',
      'k2_drink_trust_head': '⚠️ 這筆數據可能不可信 —— 但對方**不會擋**',
      'k2_drink_trust_pi': '灌流指數過低，訊號不像脈搏（實測木頭桌面 0.149%、真手指 10.1%）',
      'k2_drink_trust_hr': '心率超出生理可能範圍',
      'k2_drink_trust_direction':
          '⚠️ 而且方向危險：雜訊會把 HRV 推高 → 被讀成「恢復良好」→ 推刺激類飲品',
      'k2_drink_disclaimer': '① 是精確的（照對方 k2-recommend-prompts.ts 的模板逐字排版）。\n'
          '②③ 是本地推演的近似值：對方提示詞裡**只有 LF/HF > 1.5 是硬數字**，\n'
          '其餘「高 stress / 低 PNS / 低 HRV / 心率偏高」都交給 LLM 自由心證，\n'
          '所以這裡用的門檻是我們自己訂的（見 K2DrinkThresholds），不是對方的行為。\n'
          '飲品清單是 infusion-knowledge.ts 的快照，對方改了這裡不會自動跟著動。\n'
          '本頁不連外、不發送任何資料。',
      'k2_log_stop': '⏸ 停止量測',
      'k2_log_round_late': '⏳ 送出後 {ms}ms 內沒有完整回應(通訊延遲;連續多輪才會重開串口)',
      'k2_log_cleared_core': '🧹 已清空核心 + 波形',
      'k2_log_board_main': '🔒 板子鎖定:主板 0x30(擴充板 0x31 逾時無回應)',
      'k2_log_board_expansion': '🔒 板子鎖定:擴充板 0x31',
      'k2_log_tx_failed': '❌ 送出失敗:{label}',
      'k2_log_tx': '→ TX {label}',
      // 免洗模式下每次手指離開都會印這句,所以寫中性的
      // (didReset 只有一個旗標,分不出是「手指離開歸零」還是「索引到頂」)
      'k2_log_core_reset': '♻ 核心已歸零,UI 波形同步重來',
      'k2_log_no_wave': '⚠ 沒有波形資料,無法存快照',
      'k2_log_snap_saved': '📸 已存快照:{name}',
      'k2_log_snap_failed': '❌ 快照存檔失敗(找不到桌面路徑?)',
    },

    // ==================== English ====================
    AppLanguage.en: {
      // ---------- App / Pages ----------
      'app_title': 'MAX30102 Handover Tester',
      'page_k2': 'MAX30102 K2 (Handover)',
      'page_command_control': 'Command Control',
      'page_settings': 'Settings',
      'drawer_title': 'MAX30102 K2 Handover',
      'drawer_subtitle': 'STM32 Serial Verification',
      'connection_status': 'Connection Status',

      // ---------- Connection ----------
      'connected': 'Connected',
      'disconnected': 'Disconnected',
      'not_connected': 'Not connected',
      'connect': 'Connect',
      'disconnect': 'Disconnect',
      'select_com_port': 'Select COM Port',
      'connecting': 'Connecting',
      'verifying_device': 'Verifying device...',

      // ---------- Arduino ----------
      'arduino_control': 'Arduino Control',
      'arduino_connected': 'Arduino Connected',
      'arduino_disconnected': 'Arduino Disconnected',
      'arduino_connect_failed': 'Failed to connect Arduino, please retry',
      'arduino_port_in_use': 'This port is in use by STM32',
      'select_arduino_port': 'Please select Arduino port first',
      'connect_arduino_first': 'Please connect Arduino first',
      'arduino_usb_removed': 'Arduino USB removed, connection closed',
      'arduino_connection_error': 'Arduino connection may be lost\nor in error',
      'arduino_verifying': 'Connecting Arduino, verifying device...',
      'arduino_connecting': 'Arduino connecting... ({current}/{max})',
      'arduino_port_error': 'Cannot open Arduino port',

      // ---------- STM32 ----------
      'stm32_control': 'STM32 Control',
      'stm32_connected': 'STM32 Connected',
      'stm32_disconnected': 'STM32 Disconnected',
      'stm32_connect_failed': 'Failed to connect STM32, please retry',
      'stm32_port_in_use': 'This port is in use by Arduino',
      'select_stm32_port': 'Please select STM32 port first',
      'connect_stm32_first': 'Please connect STM32 first',
      'stm32_usb_removed': 'STM32 USB removed, connection closed',
      'stm32_wrong_port': 'Selected COM port is not STM32\nPlease pick the correct port',
      'stm32_connection_error': 'STM32 connection may be lost\nor in error',
      'stm32_verifying': 'Connecting STM32, verifying device...',
      'stm32_connecting': 'STM32 connecting... ({current}/{max})',
      'stm32_firmware_version': 'STM32 firmware version: {version}',
      'firmware_version': 'Firmware version',

      // ---------- COM port ----------
      'no_com_port': 'No COM port detected. Check USB connection',
      'com_port_detected': '{count} COM port(s) detected',
      'new_com_port_detected': 'New COM port detected: {ports}',

      // ---------- Generic hardware ----------
      'stop': 'Stop',
      'all_outputs_toggled': 'All outputs {action}',
      'output_opened': 'opened',
      'output_closed': 'closed',

      // ---------- Arduino panel groups ----------
      'cmd_clean_relay': 'Clean valve (cleanrelay)',
      'cmd_container_relay': 'Container valve (containerrelay)',

      // ---------- STM32 panel ----------
      'command_mode': 'Command mode:',
      'mode_start': 'Start (0x01)',
      'mode_stop': 'Stop (0x02)',
      'mode_read': 'Read (0x03)',
      'id_select_single': 'ID select (single):',
      'id_select_multi': 'ID select (multi):',
      'select_all': 'Select all',
      'select_id_to_preview': 'Select ID(s) to preview command',
      'command_preview': 'Command preview (header + CS):',
      'send_start_cmd': 'Send start',
      'send_stop_cmd': 'Send stop',
      'send_read_cmd': 'Send read',
      'clear_flow': 'Clear Flow',
      'custom_payload': 'Custom payload',
      'hex_example': 'Hex, e.g. 01 00 04 00 00',
      'sent_arduino_command': 'Sent Arduino command: {command}',
      'sent_stm32_read_command': 'Sent STM32 read command: ID {id}',
      'enter_payload': 'Enter payload (without header & CS)',
      'hex_length_error': 'Hex string length must be even',
      'parse_error': 'Parse error: {error}',

      // ---------- Heartbeat / log ----------
      'continuous_connection': 'Continuous connection',
      'connection_lost': 'Connection lost',
      'command_buttons': 'Command buttons:',
      'receive_log': 'Receive log:',
      'verbose_rx_log': 'Verbose RX',

      // ---------- Operation page ----------
      'operation_auto_connect': 'Auto Connect',
      'operation_connected': 'Connected',
      'operation_connect_failed': 'Connect failed',
      'operation_stm32_not_connected': 'STM32 not connected',
      'operation_warm_water': 'Warm Water',
      'operation_warm_water_desc': 'Activate water pump + ambient water valve',
      'operation_warm_water_sent': 'Warm-water command sent',
      'operation_stop': 'Stop All',
      'operation_stop_desc': 'Turn off all STM32 outputs',
      'operation_stop_sent': 'Stop command sent',

      // ---------- Settings ----------
      'settings': 'Settings',
      'language': 'Language',
      'language_setting': 'Language Setting',
      'select_language': 'Select language',

      // ---------- Common ----------
      'send': 'Send',
      'refresh': 'Refresh',
      'cancel': 'Cancel',
      'confirm': 'Confirm',
      'error': 'Error',
      'warning': 'Warning',
      'success': 'Success',
      'loading': 'Loading...',
      'clear': 'Clear',
      'reset': 'Reset',
      'save': 'Save',
      'apply': 'Apply',

      // ============================================================
      // Auto-Cleaning Workflow
      // ============================================================
      'cleaning_workflow_title': 'Auto-Cleaning Workflow',
      'cleaning_workflow_subtitle': '4-step automated cleaning — pause / emergency-stop',
      'cleaning_stm_workflow_title': 'Auto-Cleaning Workflow (STM only)',
      'cleaning_stm_workflow_subtitle': 'No Arduino required; relays driven by STM32 ID16 / ID13',

      'cleaning_step_1_name': 'Step 1: Fill container',
      'cleaning_step_2_name': 'Step 2: Suction cleaning liquid',
      'cleaning_step_3_name': 'Step 3: Cleaning cycle',
      'cleaning_step_4_name': 'Step 4: Drain',

      'cleaning_step_1_desc': 'Open cleanrelay + containerrelay; STM32 fills container (water pump + ambient valve)',
      'cleaning_step_2_desc': 'Keep containerrelay on; STM32 starts ID0~9 to suction from container',
      'cleaning_step_3_desc': '⚠ Dangerous. Switch containerrelay to fixture; STM32 runs ID0~9 + pump + valve',
      'cleaning_step_4_desc': 'STM32 runs ID0~9 to drain the system',

      'step_status_idle': 'Idle',
      'step_status_running': 'Running',
      'step_status_paused': 'Paused',
      'step_status_completed': 'Completed',
      'step_status_emergency': 'Emergency Stop',
      'step_status_awaiting_ack': 'Awaiting hardware ack',

      'workflow_start': 'Start Workflow',
      'workflow_pause': 'Pause',
      'workflow_resume': 'Resume',
      'workflow_emergency_stop': 'Emergency Stop',
      'workflow_reset': 'Reset',

      'step_duration_seconds': 'Duration (s)',
      'step_stm32_targets': 'STM32 outputs',
      'step_arduino_relays': 'Arduino valves',
      'step_restore_defaults': 'Restore step defaults',
      'step_remaining_time': 'Remaining {time}',
      'step_total_time': 'Total {time}',

      'step3_manual_on_all': 'Turn ON ID0~9 (one-shot)',
      'step3_manual_off_all': 'Turn OFF ID0~9 (one-shot)',
      'step3_pause_hint': 'You can manually toggle ID0~9 while paused',

      'confirm_proceed_title': 'Step {step} completed',
      'confirm_proceed_message': 'Next step will execute:\n{actions}\n\nProceed to step {next}?',
      'confirm_proceed_yes': 'Proceed to next step',
      'confirm_proceed_no': 'Cancel (stop workflow)',
      'confirm_emergency_reset_title': 'Confirm Reset',
      'confirm_emergency_reset_message': 'Please confirm all hardware is in safe state and the workflow can be re-armed.',
      'confirm_emergency_reset_yes': 'Confirmed, unlock',
      'workflow_aborted_by_user': 'Workflow aborted by user',

      'emergency_banner_title': 'Emergency stop triggered',
      'emergency_banner_subtitle': 'STM32 fully off + both Arduino relays off. Verify hardware then press Reset to unlock.',

      'log_workflow_started': 'Workflow started',
      'log_workflow_finalizing': 'Finalizing: turning off Arduino cleanrelay / containerrelay',
      'log_workflow_completed': 'Workflow completed; all components turned off',
      'log_step_started': 'Step {step} started',
      'log_step_finished': 'Step {step} countdown ended',
      'log_step_user_aborted': 'Step {step} aborted by user',
      'log_paused': 'Paused: STM32 all-off, Arduino held',
      'log_resumed': 'Resumed: STM32 re-enabled [{ids}]',
      'log_emergency_triggered': 'Emergency stop: STM32 all-off + Arduino cleanrelay/containerrelay off',
      'log_emergency_reset': 'Emergency lock cleared',
      'log_step3_manual_on': 'Step 3 manual ON ID0~9',
      'log_step3_manual_off': 'Step 3 manual OFF ID0~9',
      'log_send_stm32_on': 'STM32 ON [{ids}] (hex: {hex})',
      'log_send_stm32_off': 'STM32 OFF [{ids}] (hex: {hex})',
      'log_send_stm32_off_all': 'STM32 ALL-OFF (hex: {hex})',
      'log_send_arduino': 'Arduino: {cmd}',
      'log_countdown_tick': 'Remaining {time}',
      'log_step_idle_outputs': 'Step {step}: no STM32 outputs enabled',
      'log_step_hw_ready': 'Step {step}: hardware ack complete, countdown starts',
      // ACK
      'log_ack_wait_arduino': 'Awaiting Arduino ack: {cmd}',
      'log_ack_ok_arduino': 'Arduino ack OK: {cmd}',
      'log_ack_retry_arduino': 'Retry ({n}/3): Arduino {cmd}',
      'log_ack_retried_arduino_ok': 'Arduino ack OK: {cmd} (after {n} retries)',
      'log_ack_failed_arduino': 'X Arduino {cmd} not acknowledged after 3 retries -- emergency stop',
      'log_ack_wait_stm32': 'Awaiting STM32 ack: cmd=0x{cmd} mask={mask}',
      'log_ack_ok_stm32': 'STM32 ack OK: cmd=0x{cmd} mask={mask}',
      'log_ack_retry_stm32': 'Retry ({n}/3): STM32 cmd=0x{cmd}',
      'log_ack_retried_stm32_ok': 'STM32 ack OK: cmd=0x{cmd} (after {n} retries)',
      'log_ack_failed_stm32': 'X STM32 cmd=0x{cmd} not acknowledged after 3 retries -- emergency stop',
      'log_emergency_warn_stm32': 'WARN: STM32 all-off ack missing; lock retained',
      'log_emergency_warn_arduino': 'WARN: Arduino {cmd} ack missing; lock retained',
      'log_emergency_finished': 'Emergency stop sequence complete',
      'ack_failed_snackbar': 'Hardware not acknowledged, please check connection and retry',

      'id_label_s0': 's0 (slot 1)',
      'id_label_s1': 's1 (slot 2)',
      'id_label_s2': 's2 (slot 3)',
      'id_label_s3': 's3 (slot 4)',
      'id_label_s4': 's4 (slot 5)',
      'id_label_s5': 's5 (slot 6)',
      'id_label_s6': 's6 (slot 7)',
      'id_label_s7': 's7 (slot 8)',
      'id_label_s8': 's8 (slot 9)',
      'id_label_s9': 's9 (slot 10)',
      'id_label_water': 'water (pump)',
      'id_label_u0': 'u0 (Spout UVC)',
      'id_label_u1': 'u1 (Mix UVC)',
      'id_label_u2': 'u2 (Main UVC)',
      'id_label_arl': 'arl (Ambient valve)',
      'id_label_crl': 'crl (Cool valve)',
      'id_label_srl': 'srl (Sparkling valve)',
      'id_label_o3': 'o3 (Ozone)',

      'relay_clean': 'cleanrelay (cleaning mode)',
      'relay_container': 'containerrelay (to container)',
      'relay_clean_stm': 'cleanrelay (STM32 ID16)',
      'relay_container_stm': 'containerrelay (STM32 ID13)',
      'log_fire_forget_arduino': 'Arduino (fire-and-forget): {cmd}',
      // Step transition / single-step / relay diff
      'confirm_each_step_toggle': 'Confirm before each step',
      'step_test_only': 'Test this step alone',
      'log_test_single_step': 'Single-step test: running step {step}',
      'log_step_transition_auto': 'Auto-proceeding to next step (confirm disabled)',
      'log_step_partial_off': 'Step {step} end: turning off non-relay GPIO (relay state retained)',
      'log_relay_activation_delay': 'Relay activation delay 200ms...',
      'log_relay_no_change': 'Relay unchanged, skipping switch',
      // Auto-proceed SnackBar
      'snackbar_auto_proceed': 'Auto-proceeding to step {step}',
      // ---------- Bootloader OTA page ----------
      'page_bootloader_ota': 'Bootloader OTA',
      'bootloader_section_connect': 'Connect',
      'bootloader_connect_raw': 'Connect (Raw)',
      'bootloader_load_hex': 'Load .hex',
      'bootloader_no_firmware_loaded': 'No firmware loaded',
      'bootloader_section_manual': 'Manual Commands',
      'bootloader_cmd_info': 'INFO',
      'bootloader_cmd_begin': 'BEGIN',
      'bootloader_cmd_start': 'ERASE',
      'bootloader_cmd_end': 'END FLASH',
      'bootloader_cmd_commit': 'MCU RESET',
      'bootloader_cmd_data': 'DATA',
      'bootloader_start_size_hint': 'Size (bytes)',
      'bootloader_manual_hex_hint': 'Enter HEX',
      'bootloader_section_auto_ota': 'Auto OTA',
      'bootloader_start_ota': 'Start OTA',
      'bootloader_abort_ota': 'Abort',
      'bootloader_reset_failure': 'Clear failure',
      'bootloader_phase_idle': 'Not connected',
      'bootloader_phase_connecting': 'Connecting…',
      'bootloader_phase_connected': 'Connected',
      'bootloader_phase_detecting_role': 'Detecting role…',
      'bootloader_phase_triggering': 'Triggering Bootloader…',
      'bootloader_phase_waiting_b': "Waiting 'B' marker…",
      'bootloader_phase_verifying_bootloader': 'Verifying Bootloader…',
      'bootloader_phase_erasing': 'Erasing Flash…',
      'bootloader_phase_sending_data': 'Sending data…',
      'bootloader_phase_verifying_magic': 'Verifying magic…',
      'bootloader_phase_committing': 'Committing…',
      'bootloader_phase_verifying_new': 'Verifying new version…',
      'bootloader_phase_completed': '✓ Completed',
      'bootloader_phase_failed': '✗ Failed',
      'bootloader_save_log': 'Save',
      'bootloader_cmd_bl_update': 'BL_UPDATE',
      'bootloader_bl_update_confirm_title': 'Confirm BL V2 update?',
      'bootloader_bl_update_confirm_message':
          '⚠️ This will reset the board into "BL V2 update mode".\n\n'
              'If you don\'t immediately follow up with BL V2 binary '
              '(START 20KB → DATA → END → COMMIT), the board will auto-recover '
              'to App after 30s timeout.\n\n'
              'Confirm sending sub-cmd 0x10?',
      'bootloader_bl_update_confirm_ok': 'Confirm',
      // ---------- Error Report page ----------
      'page_error_report': 'Error Detection',
      'error_report_phase_idle': 'PING Idle',
      'error_report_phase_verifying': 'Verifying (5s)',
      'error_report_phase_steady': 'Steady (30s)',
      'error_report_ota_busy': 'OTA Busy',
      'error_report_ping_section': 'PING Control',
      'error_report_start_ping': 'Start PING',
      'error_report_stop_ping': 'Stop PING',
      'error_report_id_panel': '26 ID Live Panel',
      'error_report_query_all': 'QUERY ALL',
      'error_report_clear_all': 'CLEAR ALL',
      'error_report_read_all': 'READ ALL',
      'error_report_read_all_stop': 'Stop READ',
      'error_report_read_offsets': 'Read OFFSET',
      'error_report_read_adc': 'READ ADC',
      'error_report_read_adc_all': 'READ ADC ALL',
      'error_report_read_adc_all_stop': 'Stop ADC',
      'error_report_adc_snapshot_all': 'ADC Snapshot ALL',
      'error_report_query': 'QUERY',
      'error_report_read': 'READ',
      'error_report_set': 'SET',
      'error_report_clear': 'CLEAR',
      'error_report_set_section': 'SET Parameters',
      'error_report_no_read_yet': 'No READ yet — press [READ] to load current values',
      'error_report_device_control': 'Device Control (ID 0~17 + 25)',
      'error_report_all_on': 'ALL ON',
      'error_report_all_off': 'ALL OFF',
      'error_report_all_on_confirm_title': 'Confirm turning ALL 19 devices ON?',
      'error_report_all_on_confirm_message':
          '⚠️ This will simultaneously activate 19 devices (10 pumps + water pump + 3 UVC + 3 relays + Clean + Container).\n\n'
              'Verify hardware is connected and test environment is safe?',
      'error_report_all_on_confirm_ok': 'Confirm ALL ON',
      // Apply factory testing preset to all 26 IDs
      'error_report_apply_preset': 'Set All (Preset)',
      'error_report_apply_preset_stop': 'Abort SET',
      'error_report_apply_preset_confirm_title':
          'Write factory testing preset to 26 IDs?',
      'error_report_apply_preset_confirm_message':
          'This will send SET commands per-ID to overwrite the current firmware settings, applying the factory testing preset to all 26 IDs (Group A fully enabled; B/C/D per table; E/17/25 remain DISABLED). Aborts on disconnect or user stop.',
      'error_report_apply_preset_confirm_ok': 'Confirm Write',
      // Group settings panel (below the receive log)
      'error_report_group_panel_toggle': 'Advanced: Group Settings',
      'error_report_group_panel_expand': '(click to expand)',
      'error_report_group_panel_collapse': '(click to collapse)',
      'group_apply': 'Apply this Group',
      'group_apply_success': 'SET command sent',
      'group_never_read': 'not read yet',
      'group_last_read': 'last read',
      'group_offset_not_read':
          'not read yet (press [Read OFFSET] at page top to load)',
      // Group A: Devices (blue)
      'group_a_title': 'Devices',
      'group_a_subtitle':
          'ID 0-17 (Pump/Water/UVC/Relay/Clean) + 25 (Container)',
      'group_a_debounce_label': 'Inrush mask',
      'group_a_debounce_hint':
          'Wait N ms after switching on before checking (skip inrush spike)',
      'group_a_offset_hint':
          'Boot-time auto-calibrated baseline; enable to latch OFFSET bit',
      'group_a_thr_off_hint':
          'ADC above this in OFF state = fault (leak / short)',
      'group_a_thr_low_hint':
          'ADC below this in ON state = fault (open / no load)',
      'group_a_thr_high_hint':
          'ADC above this in ON state = fault (blocked / overcurrent)',
      // Group B: Flow (green)
      'group_b_title': 'Flow',
      'group_b_subtitle': 'ID 18 (Flow) — only detected while running',
      'group_b_debounce_label': 'Compare window',
      'group_b_debounce_hint':
          'Compare flow delta every N ms (multiples of 200)',
      'group_b_thr_low_hint':
          'Flow delta within window <= this value = fault',
      // Group C: Pressure (orange)
      'group_c_title': 'Pressure',
      'group_c_subtitle': 'ID 19 (CO2 pressure), 20 (water pressure)',
      'group_c_debounce_label': 'Consecutive',
      'group_c_debounce_suffix': 'times',
      'group_c_debounce_hint':
          'Fires after N consecutive matches (1 = 200ms)',
      'group_c_thr_off_hint': 'Idle-state pressure upper limit',
      'group_c_thr_low_hint': 'Running-state pressure lower limit',
      'group_c_baseline_hint': 'Boot-time auto-calibrated pressure baseline',
      // Group D: Temperature (red)
      'group_d_title': 'Temperature',
      'group_d_subtitle': 'ID 21-23 (temperature sensors x 3)',
      'group_d_debounce_label': 'Consecutive reads',
      'group_d_debounce_suffix': 'times',
      'group_d_debounce_hint':
          'Fires after N consecutive faults (each read ~1s, unit=count)',
      'group_d_sensor_label': 'SENSOR check',
      'group_d_sensor_hint':
          'Reading integer 85 indicates sensor disconnected',
      'group_d_thr_low_hint':
          'Temperature below this = fault (can be negative)',
      'group_d_thr_high_hint': 'Temperature above this = fault',
      // Group E: Leak (purple)
      'group_e_title': 'Leak',
      'group_e_subtitle': 'ID 24 (leak sensor)',
      'group_e_firmware_debounce': 'Debounce: 100ms (firmware fixed)',
      'group_e_leak_label': 'Check leak',
      'group_e_leak_hint': 'Fires when a leak signal is detected',
      // Step 2 multi-mode (continuous / final-rest / pulsed)
      'step_run_mode_continuous': 'Continuous',
      'step_run_mode_continuous_rest': 'Continuous + final rest',
      'step_run_mode_pulsed': 'Pulsed cycles',
      // Continuous mode
      'step_continuous_duration': 'Continuous duration (s)',
      // Continuous + final rest
      'step_cr_run_seconds': 'Run duration (s)',
      'step_cr_rest_seconds': 'Final rest (s)',
      // Pulsed cycles
      'step_pulsed_total_seconds': 'Total run time (s)',
      'step_pulsed_run_seconds': 'Per-cycle run (s)',
      'step_pulsed_rest_seconds': 'Per-cycle rest (s)',
      'step_pulsed_first_extra': 'First-cycle extra (s)',
      'step_pulse_est_cycles': 'Estimated cycles',
      'step_phase_running': 'Running',
      'step_phase_resting': 'Resting',
      'step_pulse_cycle': 'Cycle {n}',
      'log_phase_enter_rest': 'Step {step} entering rest (cycle {cycle}): non-relay GPIO off, relay maintained',
      'log_phase_enter_run': 'Step {step} entering run (cycle {cycle}): STM32 ON, this phase remaining {time}',
      'log_pulse_cycle_done': 'Cycle {cycle} done (accumulated run {acc} / {total})',
      'log_resumed_rest': 'Resumed (cycle {cycle}, resting): relay restored, waiting for rest timer',
      // Emergency trigger source
      'log_emergency_triggered_with_source': 'Emergency stop triggered (source: {source})',
      'log_emergency_reentry': 'Re-entered emergency stop (already in emergency, source: {source})',
      'emergency_trigger_manual': 'User pressed emergency stop button',
      'emergency_trigger_user_abort': 'User selected "Cancel" in step transition dialog',
      'emergency_trigger_enter_relay': 'Relay ack failed on step entry (3 retries exhausted)',
      'emergency_trigger_enter_stm32': 'STM32 GPIO ack failed on step entry (3 retries exhausted)',
      'emergency_trigger_pause_stm32': 'STM32 all-off ack failed on pause (3 retries exhausted)',
      'emergency_trigger_resume_relay': 'Relay ack failed on resume (3 retries exhausted)',
      'emergency_trigger_resume_stm32': 'STM32 GPIO ack failed on resume (3 retries exhausted)',
      'emergency_trigger_finish_stm32': 'STM32 all-off ack failed during final cleanup',
      'emergency_trigger_finish_clean': 'Arduino cleanrelay_off ack failed during final cleanup',
      'emergency_trigger_finish_container': 'Arduino containerrelay_off ack failed during final cleanup',
      'emergency_trigger_midstep_stm32': 'Non-relay GPIO off ack failed at mid-step transition',
      'emergency_banner_source_prefix': 'Trigger source',
      // ---------- MAX30102 heart-rate / SpO2 page ----------
      'page_max30102': 'MAX30102 HR/SpO2',
      'max30102_measuring': 'Measuring',
      'max30102_idle': 'Idle',
      'max30102_stream_stalled': 'Data stalled',
      'conn_inherited': 'Inherited',
      'max30102_start_measure': 'Start',
      'max30102_stop_measure': 'Stop',
      'max30102_heart_rate': 'Heart Rate',
      'max30102_spo2': 'SpO2',
      'max30102_place_finger': 'Place finger',
      'max30102_waveform': 'Waveform',
      'max30102_window': 'Window',
      'max30102_clear_waveform': 'Clear',
      'max30102_ir_label': 'IR',
      'max30102_red_label': 'RED',
      'max30102_acdc_title': 'AC / DC live',
      'max30102_trim_window': 'Trim window',
      'max30102_prom_ratio': 'Prominence×p70',
      'max30102_help_prom':
          'New-version trough prominence threshold = ratio × p70 (amplitude ref). Measures local stand-out vs nearest peaks, not depth from 0. Higher = only strong real troughs (rejects dicrotic/breathing double-counts; too high drops beats). Default 0.5.',
      'max30102_help_led_red':
          'Red LED drive current (chip reg 0x0C). Higher = brighter/stronger; too high saturates, too low is weak. Applied instantly, no reflash.',
      'max30102_help_led_ir':
          'IR LED drive current (reg 0x0D). HR mainly uses IR. Applied instantly.',
      'max30102_help_finger':
          'IR-mean threshold for "finger present". HR/SpO2 only computed when IR DC exceeds it. Tune between no-finger and full-press IR values.',
      'max30102_help_poll':
          'QUERY_FIFO polling interval (ms). Keep <=200 to avoid dropping samples. Restarts the measure timer.',
      'max30102_help_algo_window':
          'Window (samples, 100Hz) for DC/AC & HR/SpO2 and the chart DC line. Fixed regardless of 5/10/20s view. Smaller = faster, more sensitive AC.',
      'max30102_help_algo_update':
          'How often HR/SpO2 is recomputed (ms, sliding window). Restarts the timer.',
      'max30102_help_trim':
          'Window (samples) for the trimmed sliding mean (gold line): drop max & min then average. Larger = smoother.',
      'max30102_help_band_low':
          'HR band-pass low cutoff (Hz). 0.5Hz~=30bpm.',
      'max30102_help_band_high':
          'HR band-pass high cutoff (Hz). 4Hz~=240bpm.',
      'max30102_help_hr_range':
          'Valid HR range (bpm); values outside are discarded (default 30~240).',
      'max30102_help_spo2_range':
          'Valid SpO2 range (%); values outside are discarded (default 70~100).',
      'max30102_waveform_hint':
          '4 lines per chart: raw, raw-DC (dashed), trimmed mean (orange), trimmed-DC (blue dashed)  ·  left panel shows raw vs trimmed for HR/SpO2 & DC/AC',
      'max30102_params': 'Parameters',
      'max30102_params_hint': '⚠️ Finger/saturation thresholds are tentative (tune on real hardware); LED current writes the chip reg instantly (no reflash).',
      'max30102_led_red': 'RED LED(0x0C)',
      'max30102_led_ir': 'IR LED(0x0D)',
      'max30102_finger_threshold': 'Finger IR thr.',
      'max30102_poll_ms': 'Poll (ms)',
      'max30102_algo_window': 'DC/algo window',
      'max30102_algo_update_ms': 'Update (ms)',
      'max30102_band_low': 'Band low (Hz)',
      'max30102_band_high': 'Band high (Hz)',
      'max30102_hr_min': 'HR min',
      'max30102_hr_max': 'HR max',
      'max30102_spo2_min': 'SpO2 min',
      'max30102_spo2_max': 'SpO2 max',
      'max30102_verbose_log': 'Show full RX hex',
      'max30102_init': 'INIT',
      'max30102_verify_chip': 'Verify chip',
      'max30102_query_once': 'QUERY once',
      'max30102_read_reg': 'READ_REG',
      'max30102_write_reg': 'WRITE_REG',
      'max30102_reset': 'RESET',
      'max30102_reg_addr': 'Register addr',
      'max30102_reg_value': 'Value',
      'max30102_reset_confirm': 'Soft-reset the chip? It will enter POR sleep (unusable) — press [INIT] to bring it back. Normally just use INIT.',
      'max30102_log_caps': '(show 5000 / keep 50000)',

      // ---------- MAX30102 K2 (handover verification page) ----------
      // Page title and sections
      'k2_title': 'MAX30102 K2 (Handover Verification)',
      'k2_sec1': '① Live values + HRV (rolling last {sec}s)',
      'k2_sec2': '② Snapshot viewer (replay from file)',
      'k2_sec3': '③ Chip control',

      // Connection bar
      'k2_connected': '● Connected {port}',
      'k2_not_connected': '○ Not connected',
      'k2_rescan': 'Rescan',
      'k2_connect': 'Connect',
      'k2_connecting': 'Connecting…',
      'k2_disconnect': 'Disconnect',
      'k2_start_measure': 'Start',
      'k2_stop_measure': 'Stop',
      'k2_clear': 'Clear',
      'k2_snack_connected': '✅ Connected {port}',
      'k2_snack_connect_failed': '❌ Failed to connect {port}{detail}',
      'k2_port_busy': ' (port may be in use by another page)',

      // Live values
      'k2_window': 'Window',
      // ── Fixed window (first N seconds of this measurement only) ──
      'k2_window_range': '10~{max}',
      'k2_fixed_mode': 'Fixed',
      'k2_hide_dead': 'Hide dead',
      'k2_hide_dead_tip': 'Removes the 1.5s dead period from the chart (display '
          'only; that segment never enters any calculation). When start is '
          'pressed before the finger lands, IR ramps from 50k to 90k and that '
          'swing takes over the vertical scale, flattening the real pulse.',
      'k2_snap_full': 'Full',
      'k2_snap_full_tip': 'Full snapshot: also writes the head segment the core '
          'discards (dead + settling), fixed-window state, every derived value, '
          'and all HrvStats fields. '
          'When off (default) the file is identical to before. '
          'Note: this is the desktop snapshot file, not the server JSON.',
      'k2_fixed_hint': 'Uses only the first {sec}s of this measurement; '
          'later data is excluded. The clock starts at the first clean sample '
          'the core emits (about 3.5s after the finger is detected: '
          '1.5s dead + 2.0s settling), so it does not start at 0.0.',
      'k2_fixed_collecting': 'collecting {got} / {sec} s',
      'k2_fixed_frozen': 'frozen · first {sec}s',
      'k2_fixed_ended': 'measurement ended (finger off)',
      'k2_fixed_short': 'not enough data: only {got}s',
      'k2_fixed_rebased': 'waveform gap, restarted {n} time(s)',
      'k2_fixed_sqi_rounds': 'SQI {ok}/{n} rounds',
      'k2_fixed_pre_missing': 'head not recovered',
      'k2_fixed_waiting': 'waiting for this measurement',
      'k2_hrv_fixed': 'HRV (first {sec}s)',
      'k2_sec1_fixed': '① Live values + fixed: first {sec}s',
      'k2_band_dead': 'dead (dropped) {sec}s',
      'k2_band_settle': 'settling (not emitted) {sec}s',
      'k2_band_orient': 'deciding + buffering {sec}s',
      'k2_band_normal': 'counted',
      // Event markers (vertical lines)
      'k2_ev_settled': 'settled · deciding + buffering starts  t={sec}s',
      'k2_ev_release': 'orientation locked · held samples released  t={sec}s',
      'k2_ev_baseline_ok': 'baseline trustworthy from  t={sec}s',
      'k2_actual_span': 'actual {sec}s ({beats} beats)',
      'k2_save_snapshot': 'Snapshot',
      'k2_feed_stats': 'fed #{ver} · RX {rx} · wave {wave}',
      'k2_finger_off_hold':
          'Finger removed · showing last values\nPut the finger back to resume',
      'k2_hr_new': 'Heart rate (new)',
      'k2_spo2_new': 'SpO₂ (new, per-beat)',
      'k2_finger': 'Finger',
      'k2_settling':
          'Settling… waiting for baseline\nidle {dead}s + collect {settle}s',
      // Channel orientation (which slot is RED / IR) — some modules have the two
      // LED dies fitted backwards; the core works it out on its own.
      'k2_orient': 'Channel',
      'k2_orient_unknown': 'checking',
      'k2_orient_normal': 'normal',
      'k2_orient_swapped': 'corrected',
      // Breath-hold SpO2 curve (for validating wavelength: the two modules can
      // only be told apart once SpO2 is driven down)
      'k2_bh_title': 'Breath-hold SpO₂ curve',
      'k2_bh_start': 'Start hold',
      'k2_bh_resume': 'Resume breathing',
      'k2_bh_stop': 'Stop',
      'k2_bh_clear': 'Clear',
      'k2_bh_waiting': 'Recording… waiting for SpO₂',
      'k2_bh_press_start': 'Press "Start hold" to begin',
      'k2_bh_min': 'min',
      'k2_bh_drop': 'drop',
      'k2_bh_recover': 'recovery',
      'k2_bh_recovering': 'recovering',
      'k2_bh_previous': 'previous (reference)',
      'k2_bh_abort': '⚠ Finger left; the core reset its index, so the timeline '
          'cannot be joined. Recording aborted.',
      'k2_bh_hint': 'Place the finger and wait for the channel verdict before '
          'starting. Stop when done, then record again with a different module '
          'to overlay both runs on the same chart.',

      // HRV panel
      'k2_hrv_short': 'HRV (last {sec}s)',
      'k2_hrv_insufficient': '— not enough beats ({beats}; needs ≥9)',
      'k2_hrv_score': 'HRV score',
      'k2_mean_rr': 'Mean RR',
      'k2_mean_hr': 'Mean HR',
      'k2_beats_total': 'Beats',
      'k2_valid_pairs': 'Valid pairs',
      'k2_skipped': ' (skip {n})',

      // Snapshot viewer
      'k2_snap_hint':
          'Open a saved snapshot to replay wave, troughs and RR trend with the same charts',
      'k2_scanning': 'Scanning…',
      'k2_refresh': 'Refresh',
      'k2_snap_empty':
          'No snapshots yet — press "Snapshot" above, then "Refresh" here',
      'k2_snap_saved': 'Snapshot saved: {name}',
      'k2_snap_save_failed': 'Failed to save snapshot',
      'k2_snap_saved_at': 'Saved at {time}',
      'k2_snap_summary': 'wave {wave} · troughs {trough} · RR {rr} beats',
      'k2_delete': 'Delete',
      'k2_window_sec': '{sec}s window',
      'k2_hr': 'HR',
      'k2_spo2': 'SpO₂',

      // Chip control
      'k2_btn_init': 'INIT',
      'k2_btn_query': 'QUERY once',
      'k2_btn_read_reg': 'READ_REG (IR LED)',
      'k2_btn_apply_led': 'Apply LED current',
      'k2_btn_reset': 'RESET',
      'k2_params_title': 'Tunable parameters (K2 minimal set)',
      'k2_btn_check': 'Check settings',
      'k2_log_title': 'RX log',
      'k2_clear_log': 'Clear',

      // Tunable parameter fields
      'k2_f_finger_threshold': 'Finger threshold',
      'k2_f_finger_threshold_hint': 'compare with irDc',
      'k2_f_hr_min': 'HR min (bpm)',
      'k2_f_hr_max': 'HR max (bpm)',
      'k2_f_filter_hint': 'filter {hz}Hz',
      'k2_f_prom_ratio': 'Trough prominence',
      'k2_f_compute_window': 'Compute window (samples)',
      'k2_f_fixed': 'fixed',
      'k2_f_compute_every': 'Compute every (samples)',
      'k2_f_finger_dead': 'Idle period (ms)',
      'k2_f_settle_samples': 'Settle (samples)',
      'k2_f_settle_hint': 'derived from HR min',
      'k2_f_data_history': 'History (ms)',
      'k2_f_data_history_hint': 'shared by samples + RR',
      'k2_f_finger_off_batches': 'Finger-off debounce (batches)',
      'k2_f_led_red': 'LED red',
      'k2_f_led_ir': 'LED IR',
      'k2_f_poll_interval': 'Poll interval (ms)',
      'k2_f_poll_hint': 'UI layer, not core',
      'k2_sw_searchback': 'Search-back (recover missed beats)',
      'k2_sw_clean': 'Outlier clean',

      // Charts
      'k2_chart_rr_trend': 'RR trend (ms)',
      'k2_chart_waiting': 'Waiting for data…',
      'k2_chart_waiting_beats': 'Waiting for data… (needs several beats)',
      'k2_chart_mean': 'mean {v}',
      'k2_chart_now': 'now {v}ms  ({beats} beats)',
      'k2_chart_poincare_axis': 'X=prev  Y=current (ms)',
      'k2_chart_prev_beat': 'prev→',
      'k2_chart_this_beat': 'curr',
      'k2_chart_big_jump': '● red = big jump',
      'k2_chart_no_channel': 'Enable HR (IR) or SpO₂ (red)',
      'k2_chart_fixed_amp': 'fixed ±{v}',
      'k2_chart_baseline': 'baseline (midline)',
      'k2_chart_peak': 'peak {v}',
      'k2_chart_trough': 'trough {v}',
      'k2_chart_p2p': 'p2p {v} · suggest fixed ±{amp}',

      // Settings-check log
      'k2_chk_all_ok': '✅ Settings check: all valid',
      'k2_chk_all_ok_notes': '✅ Settings check: all valid ({notes} notes)',
      'k2_chk_problems':
          '── Settings check: {problems} to fix{notes} ──',
      'k2_chk_notes_tail': ' + {notes} notes',
      'k2_chk_ui_ref': '   ↳ UI: {where}',
      'k2_chk_field_ref': '"{label}" field',
      'k2_chk_switch_ref': '"{label}" switch',
      'k2_chk_ui_smooth': '(UI smoothing factor, unused by core)',
      'k2_sw_log': '⚙ {label} → {state}',
      'k2_state_on': 'ON',
      'k2_state_off': 'OFF',

      // Measurement log (adapter)
      'k2_log_parse_error': '⚠ Parse error: {reason}',
      'k2_log_start':
          '🟢 Measuring (probing board: 0x31 first, falls back to 0x30 on timeout)',
      // Drink recommendation preview (offline, no network)
      'glass_setting': 'Glass look',
      'glass_setting_hint':
          'Translucent panels with a blurred backdrop, across every page. '
              '⚠️ Each blur layer is recomputed every frame — '
              'if the waveform starts stuttering while measuring, turn this off first.',
      'k2_drink_vote_head':
          'Why this rule (★ = threshold hard-coded in their prompt; the rest are ours)',
      'k2_drink_vote_sym': 'Sympathetic +1',
      'k2_drink_vote_para': 'Parasympathetic +1',
      'k2_drink_vote_override': 'Override fires',
      'k2_drink_vote_not_triggered': 'No override',
      'k2_drink_vote_none': 'No vote',
      'k2_drink_vote_unused': 'Not used by rules',
      'k2_drink_tally': 'Sympathetic {s} · Parasympathetic {p}',
      'k2_drink_tally_override':
          'Elevated heart rate → override fires; every other signal is ignored',
      'k2_drink_eff_hr':
          'Elevated = override: hydrating, non-fizzy, non-stimulant only (electrolytes), ignoring all else; also an avoid condition for caffeine / cascara',
      'k2_drink_eff_lfhf':
          'The only hard number. > 1.5 votes sympathetic and is a caffeine avoid condition; ≤ 1.5 just withholds that vote — it never votes parasympathetic',
      'k2_drink_eff_stress':
          'High → sympathetic vote, excludes caffeine / cascara / bcaa / whey / lCarnitine, favours lutein; low → parasympathetic vote. Bands follow Garmin\'s stress scale (> 75 high, ≤ 50 low)',
      'k2_drink_eff_pns':
          'Derived from RMSSD, so its bands are converted from RMSSD 20 / 50 ms. Low → sympathetic vote, an avoid condition for caffeine / cascara; high → parasympathetic vote, unlocks energy & performance',
      'k2_drink_eff_rmssd':
          'One of the HRV pair (rule: high HRV — SDNN/RMSSD). High → parasympathetic vote; low → sympathetic vote. Noise pushes it up',
      'k2_drink_eff_sdnn':
          'One of the HRV pair (rule: high HRV — SDNN/RMSSD). High → parasympathetic vote; low → sympathetic vote. Noise pushes it up too',
      'k2_drink_eff_ans':
          'Derived from LF/HF (> 64.6 ⇔ LF/HF > 1.5); the rules only use the LF/HF form, so voting again would count the same signal twice. Low = parasympathetic-leaning, but a model may misread it as a low score',
      'k2_drink_eff_conf':
          'Referenced by neither the rules nor the code; it does not change which rule hits',
      'k2_fx_title':
          'Formulas with live values (fields sent to the LLM and where they come from)',
      'k2_fx_note_power':
          'P(f) = Lomb-Scargle periodogram; k scales the three bands to sum to the RR variance: VLF {vlf} + LF {lf} + HF {hf} = {total} ≈ SDNN² = {s2}',
      'k2_fx_note_hf_cyc': 'This segment holds {cyc} cycles of the HF lower edge (0.15 Hz)',
      'k2_fx_note_not_sent':
          'Our own unit (ms²), not sent to the LLM — only the numerator / denominator of lf_hf. The {api} that gets sent is in their unit, see below',
      'k2_fx_note_aquivio':
          'The value sent in the JSON (their unit; same number as LF in the side panel), not part of the LLM prompt. × 1e-6: ms² → s² (their RR is in seconds); × 1024: their Welch spectrum sums the bins without multiplying by the bin width Δf = 4 / 4096 Hz, i.e. an extra 1/Δf = 1024',
      'k2_fx_note_aquivio_hf':
          'The value sent in the JSON (their unit; same number as HF in the side panel), same conversion as above',
      'k2_fx_rolling': 'Rolling: last {sec} s, recomputed every second',
      'k2_fx_fixed':
          'Fixed window: same segment as the side panel, frozen at the end of the measurement',
      'k2_fx_round': 'Rounded for display; the full floats are what gets sent',
      'k2_fx_legend':
          'Dark = the 8 fields in the LLM prompt; faint = intermediates used to compute them',
      'k2_fx_col_field': 'Field',
      'k2_fx_col_inputs': 'From',
      'k2_fx_col_formula': 'Formula',
      'k2_fx_col_sub': 'Substituted',
      'k2_fx_col_result': 'Result',
      'k2_fx_note_sdnn':
          'N = number of RR intervals (beats − 1); sample standard deviation, divisor N − 1',
      'k2_fx_note_rmssd':
          'P = pairs adjacent in time (no missed beat between), currently {pairs} / {total}',
      'k2_fx_note_lfhf':
          'Lomb-Scargle spectrum. This segment spans {span} s — only {cyc} cycles of the LF lower edge (0.04 Hz)',
      'k2_fx_note_clamp': 'Computed {raw}, outside 0 – 100 → clamped to {v}',
      'k2_fx_note_snr':
          'P_signal = power within ±{hw} Hz of f₀ (= HR / 60) and 2f₀; P_noise = the rest of {lo} – {hi} Hz. Both powers live inside the core and are not exported',
      'k2_fx_note_conf':
          'Depends on snr_db only, not on beat count (the beat-based one is confidence_by_beats, which the LLM never sees)',
      'k2_fx_na_beats': 'Fewer than {min} beats (currently {n})',
      'k2_fx_na_spec': 'Fewer than 8 RR intervals — no spectrum',
      'k2_fx_na_snr': 'Less than 5 s of waveform, or no heart rate yet',
      'k2_fx_na_dep': 'Depends on {dep}, which has no value yet',
      'k2_fx_na_pairs': 'No adjacent pairs at all — RMSSD = 0, log undefined',
      // ---------- "?" help dialogs of the formula panel ----------
      'k2_help_tag_llm': 'Field in the LLM prompt',
      'k2_help_tag_mid': 'Intermediate (not in the LLM prompt)',
      'k2_help_sec_what': 'What it is',
      'k2_help_sec_how': 'How it is computed',
      'k2_help_sec_use': 'Role in the recommendation',
      'k2_help_sec_note': 'Caveats',
      'k2_help_sec_ref': 'Reference values',
      'k2_help_sec_math': 'The math',
      'k2_help_box_formula': 'formula',
      'k2_help_box_sub': 'values',
      'k2_help_box_result': 'result',
      'k2_help_box_inputs': 'from',
      'k2_help_lf_ms2_math': _k2LombMathEn,
      'k2_help_hf_ms2_math': _k2LombMathEn,

      'k2_help_mean_hr_what':
          'Mean heart rate: the average of all RR intervals (time between beats) in this segment, converted to beats per minute.',
      'k2_help_mean_hr_how':
          '1. Find the trough of every beat in the IR waveform\n2. Time between adjacent troughs = one RR interval, i.e. the spacing between two beats (ms)\n3. Drop outliers caused by missed or split beats\n4. mean(RR) = the average spacing: sum of all RR intervals in this segment ÷ their count\n5. Heart rate = 60000 ÷ mean(RR)\n\nWhere 60000 comes from: the units differ. The spacing is in milliseconds, heart rate is in beats per minute. 1 minute = 60 s = 60000 ms, so 60000 ÷ the average spacing is how many spacings fit into one minute = beats per minute.\nExample: average spacing 885.8 ms → 60000 ÷ 885.8 = 67.7 bpm; shorter spacing fits more into a minute, so a faster heart rate.',
      'k2_help_mean_hr_use':
          '"Heart rate: X bpm" in the prompt. Their "Elevated heart rate" rule is an override: when HR is elevated, all other signals are ignored and only hydrating, non-fizzy, non-stimulant drinks are allowed; it is also an avoid condition for caffeine / cascara. They never say how high is elevated, so the LLM decides; our preview in ② uses 100 bpm.',
      'k2_help_mean_hr_note':
          'It measures right now, not resting HR: walking, talking or nerves just before the reading push it up and can trip the override. It is derived from the mean RR, so it may differ from the beat-by-beat live HR by 1–2 bpm.',
      'k2_help_mean_hr_ref':
          'Adult resting 60–100 bpm; > 100 bpm is tachycardia (clinical definition).',

      'k2_help_sdnn_what':
          'Standard deviation of RR intervals: the total amount of beat-to-beat variation in the segment, including both fast breathing-driven swings and slower changes.',
      'k2_help_sdnn_how':
          '1. Take the N RR intervals of this segment\n2. Compute their mean\n3. Subtract the mean from each, square, sum\n4. Divide by N − 1 (sample SD) and take the square root',
      'k2_help_sdnn_use':
          '"HRV SDNN: X ms" in the prompt. Their rules pair it with RMSSD as HRV: high HRV — SDNN/RMSSD → parasympathetic / recovered; low HRV → sympathetic / stressed.',
      'k2_help_sdnn_note':
          'The least reliable HRV metric in short windows: SDNN includes slow variation, and a short window captures less of it. Literature suggests at least 30 s; a PPG study needed 240 s to stabilise; our window is 12–30 s. Missed beats and noise also inflate it.',
      'k2_help_sdnn_ref':
          'Nunan 2010 short-term (5-min) norms: mean 50 ± 16 ms (range 32–93). Declines with age.',

      'k2_help_rmssd_what':
          'Root mean square of successive differences: only the fast change from one beat to the next, mainly reflecting vagal (parasympathetic) activity.',
      'k2_help_rmssd_how':
          '1. Take only pairs adjacent in time (no missed beat in between)\n2. Next beat − previous beat, square, sum\n3. Divide by the number of pairs P and take the square root',
      'k2_help_rmssd_use':
          '"RMSSD: X ms" in the prompt. It is also the sole source of pns, and through pns drives 60% of stress — one RMSSD moves three lines of the prompt.',
      'k2_help_rmssd_note':
          'Very sensitive to noise: one misplaced trough creates two large successive differences which, squared, inflate RMSSD → read as well-recovered → pushes towards stimulants. Deliberate slow, deep breathing also makes it spike (respiratory sinus arrhythmia).',
      'k2_help_rmssd_ref':
          'Nunan 2010: mean 42 ± 15 ms (range 19–75). Ultra-short 10–30 s RMSSD is validated (Munoz 2015, r = 0.94 vs 5 min). Declines with age.',

      'k2_help_lf_ms2_what':
          'Power of heart-rate variation at low frequency (0.04–0.15 Hz, periods of about 7–25 s), in ms². Mostly blood-pressure regulation (baroreflex), with both sympathetic and parasympathetic input.',
      'k2_help_lf_ms2_how':
          '1. Lay out RR by the time each occurred (unevenly spaced, so no plain FFT)\n2. Estimate the power P(f) at each frequency with a Lomb-Scargle periodogram\n3. Sum P(f)·Δf over 0.04–0.15 Hz\n4. Multiply by k so that VLF + LF + HF equals the RR variance (SDNN²)',
      'k2_help_lf_ms2_use':
          'Not sent to the LLM. It is only the numerator of lf_hf; converted to their unit it goes into the JSON as lf.',
      'k2_help_lf_ms2_note':
          'One cycle at 0.04 Hz takes 25 s — a 12–30 s window cannot hold even one full slow wave, so this value is unreliable at our window length. That is exactly why standard short-term HRV uses 5 minutes.',

      'k2_help_hf_ms2_what':
          'Power of heart-rate variation at high frequency (0.15–0.40 Hz, periods of 2.5–6.7 s), in ms². Matches breathing at 9–24 breaths per minute (respiratory sinus arrhythmia), mainly vagal.',
      'k2_help_hf_ms2_how': 'Same as lf_ms2, with the band changed to 0.15–0.40 Hz.',
      'k2_help_hf_ms2_use':
          'Not sent to the LLM. It is only the denominator of lf_hf; converted to their unit it goes into the JSON as hf.',
      'k2_help_hf_ms2_note':
          'Breathing rate decides where it lands: breathing slower than 9 per minute (e.g. deliberate deep breathing) moves the breathing-driven swing into the LF band → LF/HF rises → misread as sympathetic. A 30 s window holds about 4.5 HF cycles, more reliable than LF.',

      'k2_help_lf_what':
          'lf_ms2 converted to their unit (the camera-side aquivio-vitals): the value actually sent as lf in the JSON, the same number as "LF (lf)" in the side panel.',
      'k2_help_lf_how':
          'lf_ms2 × 1e-6 × 1024\n· × 1e-6: ms² → s² (their RR is in seconds)\n· × 1024: their Welch spectrum (fs = 4 Hz, nfft = 4096) sums the bins without multiplying by the bin width Δf = 4 / 4096 Hz, i.e. an extra 1/Δf = 1024',
      'k2_help_lf_use':
          'Sent in the JSON to the software side, but not part of the LLM prompt. The conversion keeps the same-named field on the same scale on the camera machine and ours, so downstream comparisons are not off by a thousand.',
      'k2_help_lf_note':
          'The 1024 is tied to their nfft = 4096 and fs = 4; if they change those, this factor must change too. The two sides estimate the spectrum differently (Welch vs Lomb-Scargle), so only the order of magnitude is guaranteed to match.',

      'k2_help_hf_what':
          'hf_ms2 converted to their unit: the value actually sent as hf in the JSON, the same number as "HF (hf)" in the side panel.',
      'k2_help_hf_how': 'hf_ms2 × 1e-6 × 1024, same conversion as lf.',
      'k2_help_hf_use': 'Sent in the JSON to the software side, but not part of the LLM prompt.',
      'k2_help_hf_note':
          'Same as lf: the factor is tied to their spectrum settings and only the order of magnitude is guaranteed.',

      'k2_help_lf_hf_what':
          'LF power ÷ HF power. Traditionally read as sympatho-vagal balance: above 1 leans sympathetic, below 1 leans parasympathetic.',
      'k2_help_lf_hf_how':
          'lf_ms2 ÷ hf_ms2. Units cancel in the ratio, so lf ÷ hf gives the same result.',
      'k2_help_lf_hf_use':
          '"ANS balance (LF/HF X)" in the prompt. It carries the only hard number in their rules: LF/HF > 1.5 → sympathetic-dominant, also an avoid condition for caffeine. It is also the sole source of ans.',
      'k2_help_lf_hf_note':
          'Three problems stack up:\n① Window: LF cannot be measured properly in 12–30 s (see lf_ms2)\n② Disputed meaning: Billman 2013 argues LF/HF does not accurately measure sympatho-vagal balance\n③ Threshold: healthy people at rest average about 2.8, so with 1.5 most healthy, relaxed people are labelled sympathetic-dominant\nWe send an lf_reliable flag about this, but they do not read it.',
      'k2_help_lf_hf_ref':
          'Nunan 2010 short-term (5-min) norms: mean 2.8 ± 2.6 (range 1.1–11.6).',

      'k2_help_pns_what':
          'Their parasympathetic / recovery score (0–100, called Recovery on their screen). It is RMSSD on a log scale and adds no new information.',
      'k2_help_pns_how':
          '(log₁₀ RMSSD − 1) ÷ (log₁₀ 80 − 1), clamped to 0–1, then × 100.\nRMSSD 10 ms → 0, 80 ms → 100, clamped beyond either end.',
      'k2_help_pns_use':
          '"PNS / recovery: X/100" in the prompt. Their rules: low PNS → sympathetic; high PNS → parasympathetic. It also makes up 60% of stress.',
      'k2_help_pns_note':
          'Any RMSSD ≥ 80 ms scores 100 (hits the ceiling), so "genuinely great" and "inflated by noise" look the same. The formula comes from aquivio-vitals, whose own comment calls it heuristic, not clinical. It is not the same thing as "PNS z" in the side panel (a Kubios-style z-score); the scales are not comparable.',
      'k2_help_pns_ref': 'The norm-average RMSSD of 42 ms maps to about 69.',

      'k2_help_ans_what':
          'Their autonomic balance score (0–100): LF/HF on a log scale. Higher means more sympathetic.',
      'k2_help_ans_how':
          '0.5 + log₂(LF/HF) ÷ 4, clamped to 0–1, then × 100.\nLF/HF 0.25 → 0, 1 → 50, 4 → 100.',
      'k2_help_ans_use':
          '"ANS score X/100" in the prompt, printed on the same line as LF/HF. Their rules never name it directly, but it makes up 40% of stress.',
      'k2_help_ans_note':
          'Easy to misread: a low score means parasympathetic-leaning (relaxed), not "a poor score". It inherits every problem of LF/HF. LF/HF > 1.5 is the same as ans > 64.6.',

      'k2_help_stress_what':
          'Their stress score (0–100): a weighted mix of pns and ans, not an independent measurement.',
      'k2_help_stress_how': '0.6 × (100 − PNS) + 0.4 × ANS, clamped to 0–100.',
      'k2_help_stress_use':
          '"Stress: X/100" in the prompt. Their rules: high stress → sympathetic, excludes caffeine, cascara, bcaa, whey, lCarnitine; low stress → parasympathetic.',
      'k2_help_stress_note':
          'Expanded, it is 60% RMSSD + 40% LF/HF, so stress, rmssd and pns are not three independent pieces of evidence. With RMSSD ≥ 80 ms, PNS = 100 and stress can be at most 40 — always read as low stress. The side panel also shows a Baevsky stress index (stress_baevsky); that is a different thing and is not sent to the LLM.',
      'k2_help_stress_ref':
          'Their scale has no literature basis. For comparison, Garmin 0–100 stress bands: 0–25 rest, 26–50 low, 51–75 medium, 76–100 high (the preview in ② uses these bands).',

      'k2_help_snr_db_what':
          'Waveform signal-to-noise ratio (dB): power at the pulse frequency versus power elsewhere. Measures how clean the waveform is.',
      'k2_help_snr_db_how':
          '1. Remove the mean of the raw IR waveform and apply a Hann window\n2. FFT (zero-padded to a power of two)\n3. Within 0.5–4 Hz, power within ±0.2 Hz of f₀ (= HR ÷ 60) and 2f₀ counts as signal, the rest as noise\n4. 10 · log₁₀(signal ÷ noise)',
      'k2_help_snr_db_use': 'Not sent to the LLM, but it alone decides confidence.',
      'k2_help_snr_db_note':
          'It also measures how steady the heart rate is: the signal window is only ±0.2 Hz (about ±12 bpm), so if HR swings beyond that during the segment, pulse energy falls outside and counts as noise — HR swings from deep breathing lower the SNR. Bands and thresholds are copied from the camera-side aquivio-vitals and were calibrated for rPPG, not necessarily for our contact PPG.',
      'k2_help_snr_db_ref':
          'aquivio-vitals source comment: below about 6 dB the RMSSD noise floor exceeds typical resting HRV.',

      'k2_help_confidence_what': 'Reading confidence: good / rough / very rough.',
      'k2_help_confidence_how':
          'Depends only on snr_db:\n≥ 6 dB → good\n≥ 1 dB → rough\notherwise → very rough\nno snr_db → null',
      'k2_help_confidence_use':
          '"Reading confidence: X" in the prompt. But neither their rules nor their code use it anywhere — the model sees it without being told what to do with it.',
      'k2_help_confidence_note':
          'Unrelated to beat count. The beat-based one is a separate field, confidence_by_beats, which the LLM never sees. So "good" does not mean enough beats, only a clean spectrum.',

      'k2_drink_btn': 'Drink pick',
      'k2_drink_title': 'What drink would these numbers produce?',
      'k2_drink_sec_payload': '① Fields that get sent (verbatim, their template)',
      'k2_drink_sec_rule': '② Rule this reading hits',
      'k2_drink_sec_picks': '③ Infusions favored / excluded',
      'k2_drink_favored': 'Favored',
      'k2_drink_avoided': 'Excluded',
      'k2_drink_close': 'Close',
      'k2_drink_apply_stock': 'Only what the machine has',
      'k2_drink_stock_row': 'Machine stock (simulated)',
      'k2_drink_none_stocked':
          '⚠️ None of the shortlisted infusions are stocked — their side would get no usable slug',
      'k2_drink_no_avoid_note':
          'ℹ️ 5 of the 11 (electrolytes / collagen / lutein / creatine / fiber) have **no avoidWhen field at all**\n'
              'in their knowledge base, so they can never appear under "Excluded".\n'
              '"Not excluded" does not mean "evaluated and passed".\n'
              'electrolytes also has two inconsistent sources (its own bestFor names only elevated HR,\n'
              'while the prompt\'s sympathetic rule pulls in hydration/mineral), so it is a candidate almost always.',
      'k2_drink_rule_hr':
          'Elevated heart rate → hydrating, non-fizzy, non-stimulant. Their prompt says this applies **regardless of the other signals**',
      'k2_drink_rule_sym':
          'Sympathetic / stressed → recovery and calm: hydration-mineral, antioxidant, recovery. **No caffeine or any stimulant**',
      'k2_drink_rule_para':
          'Parasympathetic / well-recovered → energy and performance: stimulant, amino-acid, protein, metabolic',
      'k2_drink_rule_neutral':
          'Neutral / mixed, no dominant signal → general-support, still leaning toward the strongest signal present',
      'k2_drink_trust_head':
          '⚠️ This reading may not be trustworthy — and their side **does not gate on it**',
      'k2_drink_trust_pi':
          'Perfusion index too low; the signal does not look like a pulse (measured: wooden desk 0.149%, real finger 10.1%)',
      'k2_drink_trust_hr': 'Heart rate outside the physiologically possible range',
      'k2_drink_trust_direction':
          '⚠️ And the bias is dangerous: noise inflates HRV → read as "well recovered" → pushes stimulants',
      'k2_drink_disclaimer':
          '① is exact (laid out verbatim from their k2-recommend-prompts.ts template).\n'
              '②③ are a local approximation: their prompt pins down **only LF/HF > 1.5**;\n'
              '"high stress / low PNS / low HRV / elevated HR" are left to the LLM,\n'
              'so the thresholds here are ours (see K2DrinkThresholds), not their behaviour.\n'
              'The infusion list is a snapshot of infusion-knowledge.ts and will not track their edits.\n'
              'This page makes no network calls and sends nothing.',
      'k2_log_stop': '⏸ Stopped',
      'k2_log_round_late':
          '⏳ No complete reply within {ms}ms (comm delay; port reopens only after several in a row)',
      'k2_log_cleared_core': '🧹 Cleared core + waveform',
      'k2_log_board_main':
          '🔒 Board locked: main 0x30 (expansion 0x31 did not answer)',
      'k2_log_board_expansion': '🔒 Board locked: expansion 0x31',
      'k2_log_tx_failed': '❌ Send failed: {label}',
      'k2_log_tx': '→ TX {label}',
      'k2_log_core_reset': '♻ Core reset; UI waveform restarted',
      'k2_log_no_wave': '⚠ No waveform data — cannot save snapshot',
      'k2_log_snap_saved': '📸 Snapshot saved: {name}',
      'k2_log_snap_failed': '❌ Failed to save snapshot (desktop path not found?)',
    },
  };
}

/// 全域翻譯函式（簡寫）
String tr(String key) => LocalizationService().tr(key);

/// 全域翻譯函式（含參數）
String trParams(String key, Map<String, dynamic> params) =>
    LocalizationService().trParams(key, params);
