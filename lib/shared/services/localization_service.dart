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
      'k2_log_stop': '⏸ 停止量測',
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
      'k2_log_stop': '⏸ Stopped',
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
