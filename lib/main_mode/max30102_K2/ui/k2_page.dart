// ============================================================================
// K2Page — K2 獨立驗證畫面(UI 層,不屬於交接內容)
// ============================================================================
// 三段式(對應示意圖):
//   ① 框1:即時數值 + 【短期 HRV:滾動最近 30 秒】
//   ② 新增:【長期 HRV:累積 300 拍】← 與短期並列，直接對照差異
//   ③ 框2:晶片控制(命令 + 可調參數 + 接收日誌)
//
// 這一步先做「骨架 + 數值 + 命令 + 日誌」,確認資料流通;
// 波形圖 / RR趨勢 / Poincaré 下一步再加。
// ============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';

import '../../../shared/services/localization_service.dart';
import '../../../shared/services/serial_port_manager.dart';
import '../k2_config.dart';
import '../k2_hrv_calculator.dart';
import '../k2_protocol.dart';
import '../k2_setting_limits.dart';
import 'k2_hrv_chart.dart';
import 'k2_serial_adapter.dart';
import 'k2_snapshot.dart';
import 'k2_wave_chart.dart';

class K2Page extends StatefulWidget {
  /// **共用**的串口管理(與 UR / MAX30102 等頁面同一個;整個 app 只有一條連線)。
  final SerialPortManager manager;

  /// 由導航層提供的可用埠清單(與其他頁一致)。
  final List<String> availablePorts;

  const K2Page({
    super.key,
    required this.manager,
    this.availablePorts = const [],
  });

  @override
  State<K2Page> createState() => _K2PageState();
}

class _K2PageState extends State<K2Page> {
  SerialPortManager get _manager => widget.manager;
  late final K2SerialAdapter _adapter = K2SerialAdapter(manager: _manager);

  List<String> _ports = const [];
  String? _selected;
  bool _connecting = false;

  /// 可選視窗長度(秒)。波形圖與短期 HRV **共用同一個視窗** —— 兩者本來就是
  /// 同一段時間的兩種呈現(波形=樣本、HRV=那段的拍),分開選只會對不起來。
  static const List<int> _secOptions = [10, 20, 30];

  /// 目前視窗長(秒)。上限受 K2SerialAdapter._waveCap 限制(目前 30s)。
  int _shortSec = 30;

  /// 即時區塊的高度(可拖曳調整,比照原本波形圖2 的做法)。
  double _sec1Height = 430;

  // ── 快照檢視 ──
  List<K2Snapshot> _snapshots = const [];
  K2Snapshot? _openSnap; // 目前展開的那張;null = 沒展開
  bool _snapLoading = false;

  @override
  void initState() {
    super.initState();
    _adapter.addListener(_onUpdate);
    // 連線狀態是非同步變的 → 監聽通知器才會即時反映(只靠 await 後 setState 會漏)
    _manager.isConnectedNotifier.addListener(_onUpdate);
    _refreshPorts();
    _reloadSnapshots(); // 進頁面先掃一次桌面既有快照
  }

  @override
  void dispose() {
    _adapter.removeListener(_onUpdate);
    _manager.isConnectedNotifier.removeListener(_onUpdate);
    // 只停自己的量測與回呼;**不關共用串口**(其他頁還在用)
    _adapter.dispose();
    super.dispose();
  }

  void _onUpdate() {
    if (mounted) setState(() {});
  }

  void _refreshPorts() {
    List<String> list;
    try {
      // 優先用導航層給的清單(與其他頁一致);沒有才自己掃
      list = widget.availablePorts.isNotEmpty
          ? (widget.availablePorts.toSet().toList()..sort())
          : (SerialPort.availablePorts.toSet().toList()..sort());
    } catch (_) {
      list = const [];
    }
    setState(() {
      _ports = list;
      // 已連線就跟著顯示目前那個埠
      _selected = _manager.currentPortName ??
          (_selected != null && list.contains(_selected)
              ? _selected
              : (list.isEmpty ? null : list.first));
    });
  }

  Future<void> _connect() async {
    if (_selected == null) return;
    setState(() => _connecting = true);
    bool ok = false;
    String? err;
    try {
      ok = await _manager.connectRaw(_selected!);
    } catch (e) {
      err = '$e';
    }
    if (!mounted) return;
    setState(() => _connecting = false);
    // 明確提示:成功/失敗都要講,不要默默失敗
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok
            ? trParams('k2_snack_connected', {'port': _selected})
            : trParams('k2_snack_connect_failed', {
                'port': _selected,
                'detail': err != null ? '：$err' : tr('k2_port_busy'),
              })),
        backgroundColor: ok ? Colors.green.shade700 : Colors.red.shade700,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _disconnect() {
    _adapter.stop();
    _manager.close();
    setState(() {});
  }

  /// 存快照 → 桌面 max30102_snapshots,SnackBar 回報,並刷新清單。
  Future<void> _saveSnapshot() async {
    final path = await _adapter.saveSnapshot();
    if (!mounted) return;
    final name = path?.split(RegExp(r'[\\/]')).last;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(path != null
          ? trParams('k2_snap_saved', {'name': name})
          : tr('k2_snap_save_failed')),
      duration: const Duration(seconds: 3),
    ));
    if (path != null) _reloadSnapshots();
  }

  /// 重新掃描桌面的快照清單。
  Future<void> _reloadSnapshots() async {
    setState(() => _snapLoading = true);
    final list = await K2SnapshotStore.loadAll();
    if (!mounted) return;
    setState(() {
      _snapshots = list;
      _snapLoading = false;
      // 若目前展開的那張已不在清單(被刪)→ 收起
      if (_openSnap != null && !list.any((s) => s.path == _openSnap!.path)) {
        _openSnap = null;
      }
    });
  }

  // ══════════════════════════════════════════════════════════════
  // ③ 快照檢視(存檔重畫,重用即時畫面的圖表元件)
  // ══════════════════════════════════════════════════════════════
  Widget _snapshotViewer() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Text(tr('k2_snap_hint'),
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          const Spacer(),
          TextButton.icon(
            onPressed: _snapLoading ? null : _reloadSnapshots,
            icon: const Icon(Icons.refresh, size: 15),
            label: Text(_snapLoading ? tr('k2_scanning') : tr('k2_refresh')),
          ),
        ]),
        const SizedBox(height: 6),
        if (_snapshots.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 16),
            alignment: Alignment.center,
            child: Text(
              _snapLoading ? tr('k2_scanning') : tr('k2_snap_empty'),
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
            ),
          )
        else
          // 清單:橫向捲動的檔案膠囊,點一個就在下方展開
          SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _snapshots.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (_, i) {
                final s = _snapshots[i];
                final open = _openSnap?.path == s.path;
                final t = s.time;
                String two(int v) => v.toString().padLeft(2, '0');
                final label = '${two(t.month)}/${two(t.day)} '
                    '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
                return ChoiceChip(
                  label: Text(label, style: const TextStyle(fontSize: 11)),
                  selected: open,
                  onSelected: (_) =>
                      setState(() => _openSnap = open ? null : s),
                );
              },
            ),
          ),
        if (_openSnap != null) ...[
          const SizedBox(height: 10),
          _snapshotDetail(_openSnap!),
        ],
      ],
    );
  }

  Widget _snapshotDetail(K2Snapshot s) {
    final cfg = _adapter.core.config;
    final shortRr = [for (final p in s.rrPoints) p.rr];
    final shortCont = _adapter.contOf(s.rrPoints);
    final shortHv = s.rrPoints.isEmpty
        ? null
        : Max30102HrvCalculator.hrvFrom(s.rrPoints);
    final marks = [for (final sec in _secOptions) if (sec < s.windowSeconds) sec];

    Widget kv(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Row(children: [
            SizedBox(
                width: 78,
                child: Text(k,
                    style:
                        TextStyle(fontSize: 11, color: Colors.grey.shade600))),
            Text(v,
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.bold)),
          ]),
        );

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 頂列:摘要 + 刪除
          Row(children: [
            Text(trParams('k2_snap_saved_at', {'time': s.time}),
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
            const SizedBox(width: 12),
            Text(
                trParams('k2_snap_summary', {
                  'wave': s.ir.length,
                  'trough': s.goldTroughs.length,
                  'rr': s.rrPoints.length,
                }),
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
            const Spacer(),
            TextButton.icon(
              onPressed: () async {
                await K2SnapshotStore.delete(s.path);
                _reloadSnapshots();
              },
              icon: const Icon(Icons.delete_outline, size: 15),
              label: Text(tr('k2_delete')),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
            ),
          ]),
          const SizedBox(height: 8),
          // ── 30 秒視窗:左數值面板 + 右(上波形 / 下 RR趨勢+Poincaré)──
          SizedBox(
            height: 380,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 150,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 原本寫死「30 秒視窗」，改用快照自己的 windowSeconds
                      // （快照可能是 10s / 20s 存的，寫死會標錯）
                      Text(
                          trParams(
                              'k2_window_sec', {'sec': s.windowSeconds}),
                          style: const TextStyle(
                              fontSize: 12, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      kv(tr('k2_hr'), s.bpm?.toStringAsFixed(0) ?? '—'),
                      kv(tr('k2_spo2'), s.spo2?.toStringAsFixed(1) ?? '—'),
                      kv('SDNN', shortHv?.sdnn.toStringAsFixed(1) ?? '—'),
                      kv('RMSSD', shortHv?.rmssd.toStringAsFixed(1) ?? '—'),
                      kv('SD1', shortHv?.sd1.toStringAsFixed(1) ?? '—'),
                      kv('SD2', shortHv?.sd2.toStringAsFixed(1) ?? '—'),
                      kv('pNN50',
                          shortHv != null ? '${shortHv.pnn50.toStringAsFixed(0)}%' : '—'),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(children: [
                    Expanded(
                      flex: 5,
                      child: K2WaveChart(
                        ir: s.ir,
                        red: s.red,
                        troughs: s.goldTroughs,
                        version: s.tsMillis, // 靜態:固定值即可
                        markSeconds: marks,
                        displaySamples: s.windowSeconds * s.fs,
                        windowSeconds: s.windowSeconds,
                        baselineWindow:
                            (100 / cfg.bandLowHz).round(),
                        trimWindow: 9,
                        promRatio: cfg.promRatio,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Expanded(
                      flex: 4,
                      child: Max30102HrvChartView(
                        rr: shortRr,
                        cont: shortCont,
                        hv: shortHv,
                        markSeconds: marks,
                      ),
                    ),
                  ]),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final connected = _manager.isConnected;
    return Scaffold(
      // 標題與連線列同一行(連線列放 AppBar 內,省一整條版面高度)
      appBar: AppBar(
        titleSpacing: 12,
        title: Row(
          children: [
            Text(tr('k2_title'),
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.bold)),
            const SizedBox(width: 14),
            Expanded(child: _connectionBar(connected)),
          ],
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 免洗版移除了原本的「② 長期 HRV(UI 累積 300 拍)」——
            // 跨測試累積會把不同使用者的拍混在一起。剩下三區重新編號。
            _sectionBox(trParams('k2_sec1', {'sec': _shortSec}),
                _liveAndShortHrv()),
            const SizedBox(height: 12),
            _sectionBox(tr('k2_sec2'), _snapshotViewer()),
            const SizedBox(height: 12),
            _sectionBox(tr('k2_sec3'), _chipControl()),
          ],
        ),
      ),
    );
  }

  // ── 連線 / 量測控制 ────────────────────────────────────────────
  Widget _connectionBar(bool connected) {
    // 緊湊工具列:小按鈕 + 小字;不用 VerticalDivider(它在 Wrap 裡會把高度撐開)
    final small = FilledButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      textStyle: const TextStyle(fontSize: 12),
      minimumSize: const Size(0, 30),
    );
    final smallOut = OutlinedButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      textStyle: const TextStyle(fontSize: 12),
      minimumSize: const Size(0, 30),
    );
    // 在 AppBar 內 → 高度固定,不能用 Wrap(換行會 overflow);改單行橫向捲動。
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        spacing: 6,
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 連線狀態燈(一眼看出有沒有連上)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: connected ? Colors.green.shade50 : Colors.grey.shade200,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: connected ? Colors.green : Colors.grey.shade400),
            ),
            child: Text(
              connected
                  ? trParams('k2_connected',
                      {'port': _manager.currentPortName ?? ''})
                  : tr('k2_not_connected'),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: connected ? Colors.green.shade800 : Colors.grey.shade600,
              ),
            ),
          ),
          SizedBox(
            width: 108,
            height: 32,
            child: DropdownButtonFormField<String>(
              initialValue: _selected,
              isDense: true,
              style: const TextStyle(fontSize: 12, color: Colors.black87),
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              ),
              items: [
                for (final p in _ports)
                  DropdownMenuItem(
                      value: p,
                      child: Text(p, style: const TextStyle(fontSize: 12))),
              ],
              onChanged: connected ? null : (v) => setState(() => _selected = v),
            ),
          ),
          IconButton(
            tooltip: tr('k2_rescan'),
            onPressed: _refreshPorts,
            icon: const Icon(Icons.refresh, size: 16),
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            padding: EdgeInsets.zero,
          ),
          if (!connected)
            FilledButton(
              onPressed: _connecting || _selected == null ? null : _connect,
              style: small,
              child: Text(
                  _connecting ? tr('k2_connecting') : tr('k2_connect')),
            )
          else
            OutlinedButton(
              onPressed: _disconnect,
              style: smallOut,
              child: Text(tr('k2_disconnect')),
            ),
          if (!_adapter.measuring)
            FilledButton(
              onPressed: connected ? () => _adapter.start() : null,
              style: small.copyWith(
                  backgroundColor: WidgetStatePropertyAll(Colors.teal)),
              child: Text(tr('k2_start_measure')),
            )
          else
            FilledButton(
              onPressed: () => _adapter.stop(),
              style: small.copyWith(
                  backgroundColor: WidgetStatePropertyAll(Colors.orange)),
              child: Text(tr('k2_stop_measure')),
            ),
          OutlinedButton(
            // 兩個池分開清:核心(緩衝+RR池)與 UI 長期池是各自獨立的東西,
            // 按鈕這裡決定「要清哪些」,而不是把它綁死在 adapter.reset() 裡。
            // 免洗版沒有長期池了,reset() 就是全部歸零的唯一入口。
            onPressed: _adapter.reset,
            style: smallOut,
            child: Text(tr('k2_clear')),
          ),
          Text(
            'RX ${_adapter.rxPackets} / TX ${_adapter.txPackets}',
            style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
          ),
        ],
      ),
    );
  }

  // ── ① 即時數值 + 短期 HRV ─────────────────────────────────────
  Widget _liveAndShortHrv() {
    final c = _adapter.latest; // 狀態旗標(手指 / SQI / 沉澱中)看原始的
    final v = _adapter.displayCompute; // 數值看這個 —— 手指離開時是保留的舊值
    final holding = _adapter.holding;
    // 短期窗一律先拿「帶索引的拍」,值與連續性都從它導出 → 三者保證同一批
    final shortPts = _adapter.pointsRecentSeconds(_shortSec);
    final shortHrv = _adapter.hrvRecentSeconds(_shortSec);
    final shortRr = [for (final p in shortPts) p.rr];
    final waveSamples = _shortSec * 100; // fs=100Hz;波形與短期 HRV 同一個視窗
    // 「N 秒前」參考線:比目前視窗小的那幾檔(視窗 30s → 畫 10s/20s 線,
    //  最左緣本身就是 30s,不另外畫)。波形圖與 RR 趨勢圖用同一組 → 兩張圖對得起來。
    final marks = [for (final s in _secOptions) if (s < _shortSec) s];
    // 佈局(對應示意圖):最上一列切視窗;下方左右分欄 —
    //   左(黃)= 垂直資料面板;右(綠)= 上波形、下 RR趨勢+Poincaré(藍)
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(tr('k2_window'),
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
            const SizedBox(width: 6),
            for (final s in _secOptions)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: ChoiceChip(
                  label: Text('${s}s', style: const TextStyle(fontSize: 11)),
                  selected: _shortSec == s,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) => setState(() => _shortSec = s),
                ),
              ),
            const SizedBox(width: 8),
            // 實際涵蓋時間 = 末拍終谷 − 首拍起谷(用絕對索引算,**含洞**)。
            // 它與「RR 加總」的差就是被過濾器剔掉的空窗長度 → 對照著看很有用。
            Text(
              trParams('k2_actual_span', {
                'sec': _adapter.spanSeconds(shortPts).toStringAsFixed(1),
                'beats': shortPts.length,
              }),
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
            const SizedBox(width: 12),
            // 存快照:把當下 30 秒視窗(+超過 30 秒的長期累積)存成 JSON。純 UI 行為。
            OutlinedButton.icon(
              onPressed: _saveSnapshot,
              icon: const Icon(Icons.photo_camera_outlined, size: 15),
              label: Text(tr('k2_save_snapshot')),
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                textStyle: const TextStyle(fontSize: 12),
              ),
            ),
            const Spacer(),
            // 即時心跳計數:直接聽 sampleVersionNotifier(10Hz),不靠整頁 rebuild。
            // 用途:一眼分辨「資料停了」vs「畫面沒重繪」——
            //   數字不動 = 串口/解析停了;數字在動但波形不動 = 繪圖問題。
            ValueListenableBuilder<int>(
              valueListenable: _adapter.sampleVersionNotifier,
              builder: (context, ver, _) => Text(
                trParams('k2_feed_stats', {
                  'ver': ver,
                  'rx': _adapter.rxPackets,
                  'wave': _adapter.waveIr.length,
                }),
                style: TextStyle(
                    fontSize: 11,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: Colors.blueGrey.shade400),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: _sec1Height,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── 黃:左側垂直資料面板 ──
              _sidePanel([
                // 手指離開 → 顯示保留的舊值,但一定要標示出來,
                // 不然會被當成這一次量測的即時數字。
                if (holding) ...[
                  Container(
                    width: double.infinity,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.blueGrey.shade50,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.blueGrey.shade200),
                    ),
                    child: Row(children: [
                      Icon(Icons.pause_circle_outline,
                          size: 14, color: Colors.blueGrey.shade600),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          tr('k2_finger_off_hold'),
                          style: TextStyle(
                              fontSize: 10.5, color: Colors.blueGrey.shade700),
                        ),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 8),
                ],
                _bigValue(tr('k2_hr_new'), v?.bpm?.toStringAsFixed(0), 'bpm',
                    Colors.red,
                    dim: holding),
                const SizedBox(height: 8),
                _bigValue(tr('k2_spo2_new'), v?.spo2?.toStringAsFixed(1), '%',
                    Colors.blue,
                    dim: holding),
                const SizedBox(height: 8),
                Row(children: [
                  _flag(tr('k2_finger'), c?.fingerPresent ?? false),
                  const SizedBox(width: 10),
                  _flag('SQI', c?.sqiOk ?? false),
                  const SizedBox(width: 10),
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('spike',
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey.shade700)),
                    const SizedBox(height: 4),
                    Text(c?.spikeMax.toStringAsFixed(2) ?? '—',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: Colors.orange.shade800)),
                  ]),
                ]),
                // 沉澱期:明確講「在等什麼」,不要放一個 0 或殘留的舊值誤導人
                if (c?.settling ?? false) ...[
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade50,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.amber.shade300),
                    ),
                    child: Text(
                      trParams('k2_settling', {
                        'dead': (_adapter.core.config.fingerDeadMs / 1000)
                            .toStringAsFixed(1),
                        'settle': (_adapter.core.config.settleSamples / 100)
                            .toStringAsFixed(1),
                      }),
                      style: TextStyle(
                          fontSize: 11, color: Colors.amber.shade900),
                    ),
                  ),
                ],
                const Divider(height: 18),
                Text(trParams('k2_hrv_short', {'sec': _shortSec}),
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                // 短期不顯示拍數/對數:拍數上面已有、對數因近似成連續而恆為 N/N
                _kvList(shortHrv, shortRr.length, showCounts: false),
              ]),
              const SizedBox(width: 8),
              // ── 綠:右側(上波形 / 下 RR趨勢+Poincaré)──
              Expanded(
                child: Column(
                  children: [
                    // 波形圖吃剩餘空間 → 拖曳把手變高時，只有它長大。
                    // 照原版 max30102_waveform_chart2 的做法:用 sampleVersionNotifier
                    // 讓波形自己以樣本速率(~10Hz)重繪,不必整頁 rebuild;
                    // 谷標點也在 builder 內每次重算(不能在外層凍結,否則標點不會跟著動)。
                    Expanded(
                      child: ValueListenableBuilder<int>(
                        valueListenable: _adapter.sampleVersionNotifier,
                        builder: (context, ver, _) => K2WaveChart(
                          ir: _adapter.waveIr,
                          red: _adapter.waveRed,
                          troughs: _adapter.displayTroughs(),
                          version: ver,
                          markSeconds: marks,
                          displaySamples: waveSamples,
                          windowSeconds: _shortSec,
                          baselineWindow:
                              (100 / _adapter.core.config.bandLowHz).round(),
                          trimWindow: 9,
                          promRatio: _adapter.core.config.promRatio,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    // ── 藍:RR 趨勢 + Poincaré ── 固定高,不隨拖曳變大
                    SizedBox(
                      height: 175,
                      child: Max30102HrvChartView(
                        rr: shortRr,
                        cont: _adapter.contOf(shortPts),
                        hv: shortHrv,
                        markSeconds: marks, // 與上方波形圖同一組秒數線
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        _resizeHandle(_sec1Height, (v) => _sec1Height = v),
      ],
    );
  }

  /// 黃框:左側垂直資料面板(比照原本 `_buildChart2Panel` 的定寬側欄)。
  Widget _sidePanel(List<Widget> children) => SizedBox(
        width: 215,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade300),
            borderRadius: BorderRadius.circular(4),
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
        ),
      );

  /// HRV 統計:**垂直列**(左標籤右數值),放進側欄用。
  /// [showCounts]:短期(UI 切窗)→ false;長期(核心算)→ true。
  Widget _kvList(HrvStats? hv, int beats, {bool showCounts = true}) {
    Widget kv(String k, String v, {Color? color}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(k,
                  style:
                      TextStyle(fontSize: 11, color: Colors.grey.shade700)),
              Text(v,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                    color: color,
                  )),
            ],
          ),
        );
    if (hv == null) {
      return Text(trParams('k2_hrv_insufficient', {'beats': beats}),
          style: TextStyle(fontSize: 11, color: Colors.grey.shade500));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        kv(tr('k2_hrv_score'), hv.hrvScore.toStringAsFixed(0),
            color: Colors.purple),
        kv('SDNN', '${hv.sdnn.toStringAsFixed(1)} ms'),
        kv('RMSSD', '${hv.rmssd.toStringAsFixed(1)} ms'),
        kv('pNN50', '${hv.pnn50.toStringAsFixed(0)} %'),
        kv('SD1', hv.sd1.toStringAsFixed(1)),
        kv('SD2', hv.sd2.toStringAsFixed(1)),
        kv(tr('k2_mean_rr'), '${hv.meanRr.toStringAsFixed(0)} ms'),
        kv(tr('k2_mean_hr'), '${hv.meanHr.toStringAsFixed(0)} bpm'),
        if (showCounts) ...[
          kv(tr('k2_beats_total'), '${hv.beats} / 300'),
          kv(
            tr('k2_valid_pairs'),
            '${hv.pairs}/${hv.totalPairs}'
                '${hv.totalPairs > hv.pairs ? trParams('k2_skipped', {
                    'n': hv.totalPairs - hv.pairs
                  }) : ""}',
            color: hv.totalPairs > hv.pairs ? Colors.orange.shade800 : null,
          ),
        ],
      ],
    );
  }

  /// 高度拖曳把手(比照原本 `_buildResizeHandle2`)。
  Widget _resizeHandle(double h, void Function(double) onSet) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeUpDown,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (d) =>
            setState(() => onSet((h + d.delta.dy).clamp(200.0, 1200.0))),
        child: Container(
          height: 16,
          alignment: Alignment.center,
          child: Container(
            width: 48,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade400,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }

  // ── ③ 晶片控制 ────────────────────────────────────────────────
  Widget _chipControl() {
    final cfg = _adapter.core.config;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: _adapter.sendInit,
              icon: const Icon(Icons.power_settings_new, size: 16),
              label: Text(tr('k2_btn_init')),
            ),
            OutlinedButton.icon(
              onPressed: _adapter.sendQueryOnce,
              icon: const Icon(Icons.download, size: 16),
              label: Text(tr('k2_btn_query')),
            ),
            OutlinedButton.icon(
              onPressed: () => _adapter.sendReadReg(Max30102Protocol.kRegLedIr),
              icon: const Icon(Icons.search, size: 16),
              label: Text(tr('k2_btn_read_reg')),
            ),
            OutlinedButton.icon(
              onPressed: _adapter.applyLedCurrent,
              icon: const Icon(Icons.edit, size: 16),
              label: Text(tr('k2_btn_apply_led')),
            ),
            OutlinedButton.icon(
              onPressed: _adapter.sendReset,
              icon: const Icon(Icons.restart_alt, size: 16),
              label: Text(tr('k2_btn_reset')),
              style: OutlinedButton.styleFrom(foregroundColor: Colors.orange),
            ),
          ],
        ),
        const Divider(height: 20),
        Text(tr('k2_params_title'),
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.grey.shade800)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            _numField(tr('k2_f_finger_threshold'), cfg.fingerThreshold,
                (v) => cfg.fingerThreshold = v,
                hint: tr('k2_f_finger_threshold_hint')),
            _numField(tr('k2_f_hr_min'), cfg.hrMin, (v) => cfg.hrMin = v,
                hint: trParams('k2_f_filter_hint',
                    {'hz': cfg.bandLowHz.toStringAsFixed(2)})),
            _numField(tr('k2_f_hr_max'), cfg.hrMax, (v) => cfg.hrMax = v,
                hint: trParams('k2_f_filter_hint',
                    {'hz': cfg.bandHighHz.toStringAsFixed(2)})),
            _dblField(tr('k2_f_prom_ratio'), cfg.promRatio,
                (v) => cfg.promRatio = v,
                hint: '0.05 ~ 2.0'),
            // 計算窗已改成固定常數(500,不開放調)→ 這裡只顯示不給改
            _roField(tr('k2_f_compute_window'),
                '${Max30102Config.computeWindow}', tr('k2_f_fixed')),
            _numField(tr('k2_f_compute_every'), cfg.computeEvery,
                (v) => cfg.computeEvery = v,
                hint: '10 ~ ${Max30102Config.computeWindow}'),
            _numField(tr('k2_f_finger_dead'), cfg.fingerDeadMs,
                (v) => cfg.fingerDeadMs = v,
                hint: '0 ~ 2000'),
            _roField(tr('k2_f_settle_samples'), '${cfg.settleSamples}',
                tr('k2_f_settle_hint')),
            _numField(tr('k2_f_data_history'), cfg.dataHistoryMs,
                (v) => cfg.dataHistoryMs = v,
                hint: tr('k2_f_data_history_hint')),
            _numField(tr('k2_f_finger_off_batches'), cfg.fingerOffBatches,
                (v) => cfg.fingerOffBatches = v,
                hint: '1 ~ 100'),
            _numField(tr('k2_f_led_red'), cfg.ledCurrentRed,
                (v) => cfg.ledCurrentRed = v,
                hint: '0 ~ 255'),
            _numField(tr('k2_f_led_ir'), cfg.ledCurrentIr,
                (v) => cfg.ledCurrentIr = v,
                hint: '0 ~ 255'),
            _numField(tr('k2_f_poll_interval'), _adapter.pollIntervalMs,
                (v) => _adapter.pollIntervalMs = v,
                hint: tr('k2_f_poll_hint')),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _switchField(tr('k2_sw_searchback'), cfg.searchBackEnabled,
                (v) => cfg.searchBackEnabled = v),
            _switchField(tr('k2_sw_clean'), cfg.cleanEnabled,
                (v) => cfg.cleanEnabled = v),
            OutlinedButton.icon(
              onPressed: _checkSettings,
              icon: const Icon(Icons.rule, size: 15),
              label: Text(tr('k2_btn_check')),
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                textStyle: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
        const Divider(height: 20),
        Row(
          children: [
            Text(tr('k2_log_title'),
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey.shade800)),
            const Spacer(),
            TextButton.icon(
              onPressed: () => setState(_adapter.logs.clear),
              icon: const Icon(Icons.delete_outline, size: 14),
              label: Text(tr('k2_clear_log')),
            ),
          ],
        ),
        Container(
          height: 220,
          width: double.infinity,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: const Color(0xFF101418),
            borderRadius: BorderRadius.circular(4),
          ),
          child: ListView.builder(
            reverse: true,
            itemCount: _adapter.logs.length,
            itemBuilder: (_, i) {
              final line = _adapter.logs[_adapter.logs.length - 1 - i];
              return Padding(
                padding: const EdgeInsets.only(bottom: 1),
                child: Text(
                  line,
                  style: TextStyle(
                    fontSize: 10,
                    fontFamily: 'monospace',
                    height: 1.35,
                    color: _logColor(line),
                    // UI 註解用斜體 → 一眼分辨「這行是核心說的」還是「UI 加的」
                    fontStyle: line.contains('↳ UI:')
                        ? FontStyle.italic
                        : FontStyle.normal,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // ── 小元件 ────────────────────────────────────────────────────
  Widget _sectionBox(String title, Widget child) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }

  /// [dim] = 這是保留的舊值 → 淡化顯示,與即時數值區分開。
  Widget _bigValue(String label, String? v, String unit, Color color,
      {bool dim = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 11, color: Colors.grey.shade700)),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(v ?? '—',
                style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: dim ? color.withValues(alpha: 0.45) : color)),
            const SizedBox(width: 3),
            Text(unit, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          ],
        ),
      ],
    );
  }

  Widget _flag(String label, bool ok) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 11, color: Colors.grey.shade700)),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: ok ? Colors.green.shade100 : Colors.grey.shade300,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(ok ? 'OK' : '—',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: ok ? Colors.green.shade800 : Colors.grey.shade600)),
        ),
      ],
    );
  }

  // ══════════════════════════════════════════════════════════════
  // 設定檢查 → 寫進日誌
  // ══════════════════════════════════════════════════════════════
  //
  // 呈現原則(交接時對方也會這樣接):
  //   ① **先原封輸出核心回傳的東西** —— severity / field / message / applied
  //      一個字都不改。對方看到的跟核心說的完全一致,不會被 UI 的轉譯誤導。
  //   ② **再補一行 UI 自己的註解** —— 例如「這對應畫面上哪個欄位」。
  //      這是呈現層的加值,所以標明「↳ UI:」與原始訊息區分開。

  /// 這個欄位對應畫面上哪個控制項(純 UI 知識,核心不會也不該知道)。
  ///
  /// 存的是**欄位標籤的翻譯 key**而非寫死字串 —— 日誌裡提到的欄位名必須跟
  /// 畫面上那個輸入框的 label 完全一致,否則切成英文後會叫使用者去找一個
  /// 畫面上根本不存在的中文欄位。
  static const Map<String, String> _fieldToLabelKey = {
    'fingerThreshold': 'k2_f_finger_threshold',
    'hrMin': 'k2_f_hr_min',
    'hrMax': 'k2_f_hr_max',
    'promRatio': 'k2_f_prom_ratio',
    'computeEvery': 'k2_f_compute_every',
    'fingerDeadMs': 'k2_f_finger_dead',
    'dataHistoryMs': 'k2_f_data_history',
    'fingerOffBatches': 'k2_f_finger_off_batches',
    'ledCurrentRed': 'k2_f_led_red',
    'ledCurrentIr': 'k2_f_led_ir',
  };

  /// 對應到開關而非輸入框的欄位(措辭不同:「開關」而非「欄位」)。
  static const Map<String, String> _switchToLabelKey = {
    'searchBackEnabled': 'k2_sw_searchback',
    'cleanEnabled': 'k2_sw_clean',
  };

  /// 只有 UI 會用、核心不讀的欄位 —— 畫面上沒有對應控制項。
  static const Set<String> _uiOnlyFields = {
    'spo2SmoothFactor',
    'hrSmoothFactor',
  };

  /// 組出「這個欄位在畫面上叫什麼」;畫面上沒有對應控制項就回 null。
  String? _uiLabelFor(String field) {
    final fieldKey = _fieldToLabelKey[field];
    if (fieldKey != null) {
      return trParams('k2_chk_field_ref', {'label': tr(fieldKey)});
    }
    final switchKey = _switchToLabelKey[field];
    if (switchKey != null) {
      return trParams('k2_chk_switch_ref', {'label': tr(switchKey)});
    }
    if (_uiOnlyFields.contains(field)) return tr('k2_chk_ui_smooth');
    return null;
  }

  static const Map<ConfigSeverity, String> _sevMark = {
    ConfigSeverity.error: '🔴',
    ConfigSeverity.warn: '🟠',
    ConfigSeverity.info: 'ℹ️',
  };

  /// 日誌一行的顏色。原始訊息依 severity 上色,UI 註解用灰藍(次要資訊)。
  Color _logColor(String line) {
    if (line.startsWith('   ↳ UI:')) return Colors.blueGrey.shade300;
    if (line.startsWith('🔴')) return Colors.redAccent.shade100;
    if (line.startsWith('🟠')) return Colors.orangeAccent.shade100;
    if (line.startsWith('ℹ️')) return Colors.lightBlueAccent.shade100;
    if (line.contains('✅')) return Colors.greenAccent;
    if (line.contains('⚙') || line.contains('──')) return Colors.white70;
    return Colors.greenAccent;
  }

  /// 跑一次設定檢查,把結果寫進下方日誌。
  /// 用 [Max30102SettingLimits.check](**不改值**),讓使用者先看到問題再自己決定;
  /// 核心那邊每次進料都會 enforce,所以就算不理會也不會壞。
  void _checkSettings() {
    final issues = Max30102SettingLimits.check(_adapter.core.config);
    // info 不是問題,只是提醒 → 標題的數字只算真正要處理的那些,
    // 不然「設定檢查:1 則」配上一則純說明,看起來像出事了。
    final problems =
        issues.where((e) => e.severity != ConfigSeverity.info).length;
    final notes = issues.length - problems;

    if (problems == 0) {
      _adapter.log(notes == 0
          ? tr('k2_chk_all_ok')
          : trParams('k2_chk_all_ok_notes', {'notes': notes}));
    } else {
      _adapter.log(trParams('k2_chk_problems', {
        'problems': problems,
        'notes':
            notes > 0 ? trParams('k2_chk_notes_tail', {'notes': notes}) : '',
      }));
    }

    for (final e in issues) {
      // ① 原始:核心回傳什麼就印什麼(applied 為空代表沒有東西要處置 → 不加尾巴)
      final tail = e.applied.isEmpty ? '' : ' → ${e.applied}';
      _adapter.log('${_sevMark[e.severity]} [${e.field}] ${e.message}$tail');
      // ② UI 註解:對應到畫面上哪裡
      final where = _uiLabelFor(e.field);
      if (where != null) {
        _adapter.log(trParams('k2_chk_ui_ref', {'where': where}));
      }
    }
  }

  /// 唯讀欄位:核心固定不開放調的常數,只顯示不給改。
  Widget _roField(String label, String value, String hint) {
    return SizedBox(
      width: 140,
      child: TextFormField(
        key: ValueKey('ro$label$value'),
        initialValue: value,
        readOnly: true,
        enabled: false,
        decoration: InputDecoration(
          labelText: label,
          helperText: hint,
          isDense: true,
          border: const OutlineInputBorder(),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        ),
        style: const TextStyle(fontSize: 12),
      ),
    );
  }

  /// 小數欄位(promRatio 之類)。改完一樣自動跑一次設定檢查。
  Widget _dblField(String label, double value, void Function(double) onSet,
      {String? hint}) {
    return SizedBox(
      width: 140,
      child: TextFormField(
        key: ValueKey('$label$value'),
        initialValue: value.toString(),
        decoration: InputDecoration(
          labelText: label,
          helperText: hint,
          isDense: true,
          border: const OutlineInputBorder(),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        ),
        style: const TextStyle(fontSize: 12),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        onFieldSubmitted: (s) {
          final v = double.tryParse(s.trim());
          if (v == null) return;
          setState(() => onSet(v));
          _checkSettings(); // 改完立刻回報,不用等使用者自己按
        },
      ),
    );
  }

  /// 開關型設定(布林,沒有範圍問題,但值得在日誌留一筆)。
  Widget _switchField(String label, bool value, void Function(bool) onSet) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Switch(
          value: value,
          onChanged: (v) {
            setState(() => onSet(v));
            _adapter.log(trParams('k2_sw_log', {
              'label': label,
              'state': v ? tr('k2_state_on') : tr('k2_state_off'),
            }));
            _checkSettings();
          },
        ),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }

  Widget _numField(String label, int value, void Function(int) onSet,
      {String? hint}) {
    return SizedBox(
      width: 140,
      child: TextFormField(
        key: ValueKey('$label$value'),
        initialValue: '$value',
        decoration: InputDecoration(
          labelText: label,
          helperText: hint,
          isDense: true,
          border: const OutlineInputBorder(),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        ),
        style: const TextStyle(fontSize: 12),
        keyboardType: TextInputType.number,
        onFieldSubmitted: (s) {
          final v = int.tryParse(s.trim());
          if (v == null) return;
          setState(() => onSet(v));
          _checkSettings(); // 改完立刻回報,不用等使用者自己按
        },
      ),
    );
  }
}
