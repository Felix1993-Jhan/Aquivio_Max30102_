// ============================================================================
// K2SerialAdapter — UI 層:串口橋接 + 歷史儲存
// ============================================================================
// ★ 這一層「不屬於交接內容」—— 它是我們自己驗證用的 UI 層。
//
// 分層界線(很重要):
//   · 核心 Max30102K2:只負責「算」。不碰串口、不開 Timer、不存歷史、不做平滑。
//   · 本檔(UI層)   :負責「收/送/存/顯示前處理」——
//        ① 開串口、定時送 QUERY_FIFO(計時器在這裡,不在核心)
//        ② 收到封包 → 丟給核心 feedData()
//        ③ **儲存歷史**(波形、RR、log)給畫面用 ← 核心不存,存在這裡
//        ④ 切時間窗、算短期 HRV ← 顯示需求,做在這裡
//
// 交接時:整個 ui/ 資料夾都可以不給,或當「參考實作」給對方看怎麼接。
// ============================================================================

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../shared/services/localization_service.dart';
import '../../../shared/services/serial_port_manager.dart';
import '../k2_config.dart';
import '../k2_core.dart';
import '../k2_hrv_calculator.dart';
import '../k2_protocol.dart';
import 'k2_snapshot.dart';

class K2SerialAdapter extends ChangeNotifier {
  K2SerialAdapter({required this.manager, Max30102K2? core})
      // 本專案是「免洗式」量測(一人一次),所以開 resetOnFingerOff:
      // 確認手指離開時核心連絕對索引一起歸零,下一位使用者完全從零開始。
      // 核心預設是 false(交接版的通用行為),這個開關只在這裡打開。
      : core = core ??
            Max30102K2(config: Max30102Config(resetOnFingerOff: true)) {
    _parser.onPacket = _onPacket;
    _parser.onError =
        (reason, partial) => _log(trParams('k2_log_parse_error', {
              'reason': reason,
            }));
  }

  /// 串口管理(由外部提供,與其他模組共用)。
  final SerialPortManager manager;

  /// K2 計算核心(交接的那包)。UI 只透過它的公開介面互動。
  final Max30102K2 core;

  final Max30102RxParser _parser = Max30102RxParser();
  Timer? _pollTimer;

  // ── UI 狀態 ────────────────────────────────────────────────────
  bool get measuring => _pollTimer != null;

  /// 詢問間隔(ms):UI 層決定,核心不管。
  int pollIntervalMs = 100;

  // ── 板子自動偵測(擴充板 0x31 優先)────────────────────────────────
  // 規則:探測期同時問 0x31 與 0x30;**收到 0x31 立刻鎖 0x31**;
  //   若 0x31 一直沒回、只有 0x30 有回,逾時(kProbeTimeoutTicks)後退鎖 0x30;
  //   鎖定後只問贏家那塊。二選一運行,不會同時兩塊。
  /// 目前鎖定的板子;null = 還在探測。
  int? activeBoard;
  int _probeTicks = 0;
  bool _sawMain = false; // 探測期間有沒有收過主板 0x30 的回應
  static const int _probeTimeoutTicks = 15; // ~1.5 秒(@100ms)沒等到 0x31 → 退 0x30

  /// 最近一次核心算出的結果(**原始**,含手指離開時的全 null)。
  /// 狀態旗標(手指 / SQI / 沉澱中)請看這個。
  K2Compute? latest;

  // ── 手指離開時的「保留上次數值」(純顯示行為,做在 UI 層)──────────
  //
  // 核心在沒手指時回全 null —— 那是對的,它手上真的沒有資料。
  // 但畫面瞬間變空白很難讀:剛量完想看數字,一鬆手就沒了。
  // 所以呈現層保留最後一筆「有手指且算得出來」的結果,並標示為保留中,
  // 等手指回來、算出新結果才換掉。
  //
  // ⚠ 一定要**看得出來是舊值**([holding] → 畫面上有徽章),
  //   不然使用者會把上一次量測的數字當成這一次的。

  /// 最後一筆「有手指、非沉澱期、真的算出東西」的結果。
  K2Compute? held;

  /// 現在畫面上顯示的是不是保留的舊值。
  bool get holding =>
      held != null && (latest == null || !latest!.fingerPresent);

  /// **數值**要用的那一份(可能是保留的舊值)。旗標請用 [latest]。
  K2Compute? get displayCompute => holding ? held : latest;

  /// 波形重繪版本(照原版 max30102_controller 的 sampleVersionNotifier 做法)。
  /// **單調遞增**,每收到一批樣本 +1 → 波形圖用 ValueListenableBuilder 監聽它,
  /// 以樣本速率(~10Hz)只重繪波形,整頁維持 1Hz(notifyListeners)不被拖累。
  /// ⚠ 千萬不要改用 waveIr.length 當版本:滿了以後長度恆定 → 畫面會凍住。
  final ValueNotifier<int> sampleVersionNotifier = ValueNotifier(0);

  // ── UI 自己儲存的歷史(核心不存)──────────────────────────────
  /// 波形歷史(給波形圖畫)。
  final List<int> waveIr = [];
  final List<int> waveRed = [];

  /// 波形歷史上限 = 核心的保留長度(config.dataHistoryMs)。跟著核心走,不另立一個數字
  /// —— 兩邊不同步的話,波形上看得到的段落在核心裡可能已經沒有對應的拍了。
  int get _waveCap => core.config.dataHistorySamples;

  // ⚠️ 這裡原本有一個「長期 RR 累積池」(allPoints,上限 300 拍),用來顯示跨越
  //    核心 30 秒視窗的長期 HRV。**免洗版已整個移除** —— 一人一次量測的場景下,
  //    跨測試累積的統計會把不同使用者的拍混在一起,不但沒有參考價值還會誤導。
  //    現在畫面上的 HRV 一律來自核心當下的視窗(見 hrvRecentSeconds)。

  /// `waveIr[0]` 的絕對位置。由核心給的 firstAbs 維護,裁掉幾筆就往前推幾筆。
  /// 有了它,谷/RR 的絕對位置才能換算成波形陣列索引。
  int waveBase = 0;

  /// 收發日誌(最新在最後)。
  final List<String> logs = [];
  static const int _logCap = 500;

  int rxPackets = 0;
  int txPackets = 0;

  // ══════════════════════════════════════════════════════════════
  // 量測控制(計時器在 UI 層)
  // ══════════════════════════════════════════════════════════════

  /// 開始量測:掛上串口接收 + 啟動輪詢計時器。
  void start() {
    if (_pollTimer != null) return;
    manager.onRawBytes = _parser.feed;
    // 每次開始量測重新探測板子(可能換了板子插)
    activeBoard = null;
    _probeTicks = 0;
    _sawMain = false;
    _log(tr('k2_log_start'));
    _pollTimer = Timer.periodic(
      Duration(milliseconds: pollIntervalMs),
      (_) => _sendQuery(),
    );
    notifyListeners();
  }

  /// 停止量測:停計時器 + 卸載接收。
  void stop() {
    _pollTimer?.cancel();
    _pollTimer = null;
    if (manager.onRawBytes == _parser.feed) manager.onRawBytes = null;
    _log(tr('k2_log_stop'));
    notifyListeners();
  }

  /// 清空核心 + 波形歷史(開始一段新檢驗前用)。
  ///
  /// 免洗版沒有長期池,這一支就是「全部歸零」的唯一入口。
  void reset() {
    core.reset();
    _clearLocal();
    _log(tr('k2_log_cleared_core'));
    notifyListeners();
  }

  /// 清掉 **UI 這一側**存的所有東西(核心不動)。
  /// 手動 reset 與核心自行歸零(didReset)兩條路都走這裡,免得有一邊漏清。
  void _clearLocal() {
    waveIr.clear();
    waveRed.clear();
    waveBase = 0;
    latest = null;
    held = null; // 保留值也一起清,不然清空後畫面還掛著上一次的數字
  }

  // ══════════════════════════════════════════════════════════════
  // 晶片命令(都是 UI 層發;核心不碰串口)
  // ══════════════════════════════════════════════════════════════

  void sendInit() => _send(Max30102Protocol.buildReInit(), 'INIT/ReInit');
  void sendQueryOnce() => _send(Max30102Protocol.buildQueryFifo(), 'QUERY_FIFO');
  void sendReset() => _send(Max30102Protocol.buildReset(), 'RESET');
  void sendReadReg(int reg) =>
      _send(Max30102Protocol.buildReadReg(reg), 'READ_REG 0x${reg.toRadixString(16)}');
  void sendWriteReg(int reg, int value) => _send(
        Max30102Protocol.buildWriteReg(reg, value),
        'WRITE_REG 0x${reg.toRadixString(16)}=0x${value.toRadixString(16)}',
      );

  /// 套用目前 config 的 LED 電流到晶片(兩顆 reg)。
  void applyLedCurrent() {
    sendWriteReg(Max30102Protocol.kRegLedRed, core.config.ledCurrentRed);
    sendWriteReg(Max30102Protocol.kRegLedIr, core.config.ledCurrentIr);
  }

  void _sendQuery() {
    if (activeBoard != null) {
      // 已鎖定:只問贏家那塊
      _send(Max30102Protocol.buildQueryFifo(board: activeBoard!), null);
      return;
    }
    // 探測期:兩塊都問,看誰回(收到 0x31 立刻鎖,見 _onPacket)
    _send(Max30102Protocol.buildQueryFifo(board: Max30102Protocol.kBoardExpansion), null);
    _send(Max30102Protocol.buildQueryFifo(board: Max30102Protocol.kBoardMain), null);
    _probeTicks++;
    // 逾時仍沒鎖 → 若期間有收過主板 0x30,退鎖 0x30;否則繼續探測
    if (_probeTicks >= _probeTimeoutTicks && _sawMain) {
      activeBoard = Max30102Protocol.kBoardMain;
      _log(tr('k2_log_board_main'));
      notifyListeners();
    }
  }

  void _send(Uint8List packet, String? label) {
    if (!manager.sendHex(packet)) {
      _log(trParams('k2_log_tx_failed', {'label': label ?? 'QUERY'}));
      return;
    }
    txPackets++;
    if (label != null) _log(trParams('k2_log_tx', {'label': label}));
  }

  // ══════════════════════════════════════════════════════════════
  // 收到封包 → 餵核心
  // ══════════════════════════════════════════════════════════════

  void _onPacket(Uint8List packet) {
    rxPackets++;

    // ── 板子偵測:packet[2] 是來源板子身分 ──────────────────────────
    if (packet.length >= 3) {
      final board = packet[2];
      if (activeBoard == null) {
        if (board == Max30102Protocol.kBoardExpansion) {
          activeBoard = board; // 收到 0x31 → 立刻鎖擴充板
          _log(tr('k2_log_board_expansion'));
          notifyListeners();
        } else if (board == Max30102Protocol.kBoardMain) {
          _sawMain = true; // 記下主板有回,但先不鎖(等 0x31 逾時)
        }
      }
    }

    // ★ 唯一與核心互動的地方:原封丟進去,核心自己驗 CS、拆 red/ir、累積、算。
    final r = core.feedData(packet);

    // 核心自行歸零過 → 我們存的座標全失效,一起丟掉重來。
    // 兩種來源:①免洗模式下確認手指離開(常態) ②絕對索引到頂(約 497 天才一次)。
    // 旗標只有一個、分不出來,所以訊息寫中性的。
    if (r.didReset) {
      _clearLocal();
      _log(tr('k2_log_core_reset'));
    }

    // UI 自己存波形歷史(核心不存)
    if (r.newIr.isNotEmpty) {
      // 核心在「沒手指 / 沉澱期」會丟棄樣本 → 絕對位置可能出現斷層。
      // 對不上就把舊波形丟掉重接,不能硬接(硬接會讓整條波形的座標整段錯位)。
      if (waveIr.isEmpty || r.firstAbs != waveBase + waveIr.length) {
        waveIr.clear();
        waveRed.clear();
        waveBase = r.firstAbs;
      }
      waveIr.addAll(r.newIr);
      waveRed.addAll(r.newRed);
      final over = waveIr.length - _waveCap;
      if (over > 0) {
        waveIr.removeRange(0, over);
        waveRed.removeRange(0, over);
        waveBase += over; // 裁掉幾筆,base 就往前推幾筆
      }
      // 波形有新資料 → 只叫波形圖重畫(不整頁 rebuild)
      sampleVersionNotifier.value++;
    }

    if (r.computed != null) {
      final c = r.computed!;
      latest = c;
      // 只有「有手指、過了沉澱期、真的算出東西」才更新保留值。
      // 沉澱期的結果是全 null,拿它當保留值等於一放手指就把畫面清空。
      if (c.fingerPresent && !c.settling && c.rrPoints.isNotEmpty) {
        held = c;
      }
      notifyListeners(); // 約每秒一次才刷新畫面
      // 手指離開時**不清波形** —— 與數值一致地保留原樣,等手指回來才更新。
      // (畫面上有「保留上次」徽章,不會被誤認成即時資料。)
    }
  }

  // ══════════════════════════════════════════════════════════════
  // 顯示用:切時間窗 + 算短期 HRV(這是「顯示需求」,做在 UI 層)
  // ══════════════════════════════════════════════════════════════

  /// 取「最近 [seconds] 秒」的拍 —— **用絕對索引切,不是把 RR 累加回推**。
  ///
  /// 為什麼:過濾器長側剔/SQI 差時會在序列上留下洞,那段時間沒有任何 RR。
  /// 累加法看不見洞 → 累到 30 秒時其實已經跨了 35 秒的真實時間,視窗會偷偷變長。
  /// 改看 endAbs:落在 `totalSamples - 秒數×fs` 之後的才算,洞多長都不影響。
  ///
  /// 手指離開時([holding])改吃保留的那份,而且**時間基準也一起凍結** ——
  /// 用「保留那批最後一拍的終谷」當基準,不用一直在跑的 `core.totalSamples`。
  /// 否則畫面雖然保留了拍,視窗卻繼續往前滑,幾秒後就把它們全部滑出去變空白。
  List<HrvRrPoint> pointsRecentSeconds(int seconds) {
    final pts = displayCompute?.rrPoints ?? const <HrvRrPoint>[];
    if (pts.isEmpty) return const [];
    final ref = holding ? pts.last.endAbs : core.totalSamples;
    final cutoff = ref - seconds * Max30102Config.samplingRateHz;
    return [for (final p in pts) if (p.startAbs >= cutoff) p];
  }

  /// 最近 [seconds] 秒的 RR 值(只要數字時用)。
  List<double> rrRecentSeconds(int seconds) =>
      [for (final p in pointsRecentSeconds(seconds)) p.rr];

  /// 短期 HRV(滾動最近 [seconds] 秒)。
  /// 帶著真實的 startAbs/endAbs 進去算 → 跨洞的配對會被正確跳過,
  /// RMSSD / pNN50 / SD1 與核心用的是**同一套連續性規則**,不再偏高。
  HrvStats? hrvRecentSeconds(int seconds) {
    final pts = pointsRecentSeconds(seconds);
    if (pts.isEmpty) return null;
    return Max30102HrvCalculator.hrvFrom(pts);
  }

  /// 真實涵蓋時間(秒)= 最後一拍終谷 − 第一拍起谷。含洞在內,與「最近 N 秒」對照用。
  double spanSeconds(List<HrvRrPoint> pts) => pts.isEmpty
      ? 0
      : (pts.last.endAbs - pts.first.startAbs) /
          Max30102Config.samplingRateHz;

  /// 連續性旗標(給 Poincaré 上色/SD1 用):本筆起谷 == 前筆終谷 才算時間相鄰。
  List<bool> contOf(List<HrvRrPoint> pts) => [
        for (int i = 0; i < pts.length; i++)
          i > 0 && pts[i].startAbs == pts[i - 1].endAbs,
      ];

  /// 波形上要標的谷 → **直接用核心採用的那批**(K2Compute.troughAbs),
  /// 這裡只做「絕對位置 → waveIr 索引」的座標換算,不做任何偵測。
  ///
  /// ⚠ 早期版本是在這裡用同一套 k2_signal 重跑一次找谷 —— 那是錯的:
  ///   核心在 **500 筆(5s)演算視窗** 上偵測、還要過生理閘門/誤拍/SQI/clean;
  ///   UI 在 **整個顯示視窗(最多 3000 筆)** 上重抓,門檻被大尖峰墊高、也沒過濾器,
  ///   結果是兩批不同的谷 → 標點與 RR/HRV 數字對不起來。
  ///   現在標點與數字保證同源。
  List<int> displayTroughs() {
    final abs = latest?.troughAbs;
    if (abs == null || abs.isEmpty || waveIr.isEmpty) return const [];
    final out = <int>[];
    for (final a in abs) {
      final i = a - waveBase;
      if (i >= 0 && i < waveIr.length) out.add(i);
    }
    return out;
  }

  // ══════════════════════════════════════════════════════════════
  // 快照(UI 層存檔;核心不參與)
  // ══════════════════════════════════════════════════════════════

  /// 組一份快照 JSON:核心視窗內的 ir/red 波形、goldTroughs(視窗內索引)、
  /// 當下數值與短期 HRV。
  ///
  /// 格式與舊版快照相容(ir/red/goldTroughs/fs 同名),可餵回核心重放。
  /// ⚠️ 免洗版**不再寫 longTerm 欄位**(長期池已移除)。舊快照檔裡若有,讀取時忽略。
  Map<String, dynamic> buildSnapshot() {
    const fs = Max30102Config.samplingRateHz;
    final c = latest;
    final hv = c?.hrv;

    return {
      'version': 'k2-1',
      'tsMillis': DateTime.now().millisecondsSinceEpoch,
      'fs': fs,
      'windowSeconds': _waveCap ~/ fs,
      // 核心視窗(畫面上看得到的那段)
      'ir': List<int>.of(waveIr),
      'red': List<int>.of(waveRed),
      'goldTroughs': displayTroughs(), // 視窗內索引,重放對拍用
      // 30 秒視窗的 RR(帶起訖谷)→ 檢視器重畫 RR 趨勢 / Poincaré 用
      'rr': [for (final p in (c?.rrPoints ?? const <HrvRrPoint>[])) p.rr],
      'rrStartAbs': [for (final p in (c?.rrPoints ?? const <HrvRrPoint>[])) p.startAbs],
      'rrEndAbs': [for (final p in (c?.rrPoints ?? const <HrvRrPoint>[])) p.endAbs],
      'bpm': c?.bpm,
      'spo2': c?.spo2,
      'fingerPresent': c?.fingerPresent ?? false,
      if (hv != null)
        'shortHrv': {
          'sdnn': hv.sdnn,
          'rmssd': hv.rmssd,
          'sd1': hv.sd1,
          'sd2': hv.sd2,
          'pnn50': hv.pnn50,
          'meanRr': hv.meanRr,
          'meanHr': hv.meanHr,
          'beats': hv.beats,
        },
    };
  }

  /// 存快照到桌面 `max30102_snapshots`。回傳存檔路徑(失敗回 null)。
  Future<String?> saveSnapshot() async {
    if (waveIr.isEmpty) {
      _log(tr('k2_log_no_wave'));
      notifyListeners();
      return null;
    }
    final snap = buildSnapshot();
    final path = await K2SnapshotStore.save(
      snap,
      snap['tsMillis'] as int,
    );
    if (path != null) {
      _log(trParams('k2_log_snap_saved', {
        'name': path.split(RegExp(r'[\\/]')).last,
      }));
    } else {
      _log(tr('k2_log_snap_failed'));
    }
    notifyListeners();
    return path;
  }

  // ══════════════════════════════════════════════════════════════

  /// 對外寫一行日誌(給頁面把設定檢查結果寫進同一條時間軸)。
  void log(String s) {
    _log(s);
    notifyListeners();
  }

  void _log(String s) {
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    logs.add('[${two(t.hour)}:${two(t.minute)}:${two(t.second)}] $s');
    while (logs.length > _logCap) {
      logs.removeAt(0);
    }
  }

  @override
  void dispose() {
    stop();
    sampleVersionNotifier.dispose();
    super.dispose();
  }
}
