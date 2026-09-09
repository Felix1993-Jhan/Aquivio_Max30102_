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

import 'dart:math' as math;

import 'package:flutter/gestures.dart'; // PointerDeviceKind(桌面版拖曳)
import 'package:flutter/material.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';

import '../../../shared/services/localization_service.dart';
import '../../../shared/services/serial_port_manager.dart';
import '../k2_config.dart';
import '../k2_core.dart';
import '../k2_hrv_calculator.dart';
import '../k2_protocol.dart';
import '../k2_setting_limits.dart';
import '../k2_vitals_metrics.dart';
import 'k2_hrv_chart.dart';
import 'k2_breathhold_chart.dart';
import 'k2_lf_experiment.dart';
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

  /// 快照分頁列的捲動控制 —— Scrollbar 與 ListView 必須共用同一個,
  /// 各自給一個會讓捲軸抓不到位置(Flutter 會直接丟例外)。
  final ScrollController _snapScroll = ScrollController();
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
    _snapScroll.dispose();
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
          //
          // ⚠️ 桌面版要多做兩件事,不然「看起來不能捲」:
          //   ① Flutter 的預設 dragDevices **不含滑鼠** —— 觸控裝置拖得動,
          //      滑鼠拖不動。桌面版是主要平台,一定要補上。
          //   ② 沒有捲軸的話,使用者連「它可以捲」都看不出來,
          //      只會以為舊快照不見了(實測就是這樣被回報的)。
          SizedBox(
            height: 48,
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(
                dragDevices: {
                  PointerDeviceKind.touch,
                  PointerDeviceKind.mouse,
                  PointerDeviceKind.trackpad,
                  PointerDeviceKind.stylus,
                },
              ),
              child: Scrollbar(
                controller: _snapScroll,
                thumbVisibility: true, // 一直顯示,不要只在捲動時才浮現
                child: ListView.separated(
                  controller: _snapScroll,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.only(bottom: 8),
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
          // ── 軟體端衍生:從快照的 rr / ir 現場重算 ────────────────────
          //
          // **不存進快照,每次開檔重算。** 這樣有三個好處:
          //   ① 舊快照(存檔時還沒有這些欄位)照樣看得到
          //   ② 演算法之後改了,舊快照會反映新結果 —— 這正是回頭檢查
          //      「換了公式之後那次量測會變怎樣」的用途
          //   ③ 快照格式不用動
          // 原料快照裡本來就有:rrPoints(帶起訖谷)、ir 波形、bpm。
          const SizedBox(height: 8),
          _snapshotStrapiPanel(s, shortHv),
        ],
      ),
    );
  }

  /// 快照的「軟體端衍生」區塊(全寬,從快照資料現場重算)。
  Widget _snapshotStrapiPanel(K2Snapshot s, HrvStats? hv) {
    // sqiOk / settling 是舊快照沒有的欄位 —— 缺了就不能算 confidence / sqi。
    final qualityKnown = s.sqiOk != null;
    final m = Max30102VitalsMetrics.compute(
      pts: s.rrPoints,
      hv: hv,
      sqiOk: s.sqiOk ?? false,
      settling: s.settling ?? false,
      bpm: s.bpm,
      ir: s.ir,
    );
    final spec = m.spectrum;

    String f(double? v, {int d = 2}) =>
        v == null ? '—' : v.toStringAsFixed(d);

    Widget stat(String k, String v, {Color? color, String? api}) => Padding(
          padding: const EdgeInsets.only(right: 18, bottom: 2),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(k,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade700)),
            if (api != null)
              Text(' ($api)',
                  style: TextStyle(
                      fontSize: 9,
                      color: Colors.blueGrey.shade300,
                      fontFamily: 'monospace')),
            const SizedBox(width: 4),
            Text(v,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                    color: color)),
          ]),
        );

    final lfColor = (spec?.lfUsable ?? false) ? null : Colors.grey.shade400;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Text('軟體端衍生 (Strapi)',
                style:
                    TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold)),
            const SizedBox(width: 8),
            Text('開檔時從快照的 RR 與波形重算',
                style: TextStyle(fontSize: 9.5, color: Colors.grey.shade600)),
          ]),
          const SizedBox(height: 6),
          // 送出去的那一套(對齊 aquivio-vitals 的公式與單位)
          Wrap(children: [
            stat('ln(RMSSD)', f(m.lnRmssd), api: 'ln_rmssd'),
            stat('副交感', f(m.pnsScore, d: 1), api: 'pns'),
            stat('自律平衡', f(m.ansScore, d: 1), api: 'ans'),
            stat('壓力', f(m.stressScore, d: 1), api: 'stress'),
            stat('活動量', f(m.activityScore, d: 1), api: 'activity'),
            stat('可信度', m.confidenceBySnr ?? '—', api: 'confidence'),
            stat('訊噪比', m.snrDb == null ? '—' : '${f(m.snrDb, d: 1)} dB',
                api: 'snr_db'),
            // sqi 的輸入(sqiOk)舊快照沒存 → 算不出來就誠實留白
            stat('SQI', qualityKnown ? '${m.sqi}' : '—',
                api: 'sqi', color: qualityKnown ? null : Colors.grey.shade400),
          ]),
          Wrap(children: [
            stat('LF', spec == null ? '—' : spec.lfAquivio.toStringAsFixed(3),
                api: 'lf', color: lfColor),
            stat('HF', spec == null ? '—' : spec.hfAquivio.toStringAsFixed(3),
                api: 'hf',
                color:
                    (spec?.hfUsable ?? false) ? null : Colors.grey.shade400),
            stat(
                'LF/HF',
                spec == null
                    ? '—'
                    : (spec.lfUsable ? f(spec.lfHf) : '${f(spec.lfHf)} ⚠'),
                api: 'lf_hf',
                color: lfColor),
            if (spec != null)
              stat('LF 圈數',
                  '${spec.lfCycles.toStringAsFixed(1)} / 需 ≥'
                      '${HrvSpectrum.minBandCycles.toStringAsFixed(0)}',
                  color: lfColor),
          ]),
          // 我們自己的判讀 —— 同一批 RR,不同尺度,不送出去
          const Divider(height: 12),
          Row(children: [
            Text('我們自己的判讀',
                style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: Colors.blueGrey.shade600)),
            const SizedBox(width: 6),
            Text('不送出 · Kubios 式 z-score,與上面尺度不同',
                style: TextStyle(fontSize: 9, color: Colors.grey.shade500)),
          ]),
          const SizedBox(height: 4),
          Wrap(children: [
            stat('副交感 z', f(m.pns)),
            stat('交感 z', f(m.sns)),
            stat('自律平衡', f(m.ansTimeDomain)),
            stat('壓力(Baevsky)', f(m.stress, d: 1)),
            stat('可信度(拍數)',
                qualityKnown ? (m.confidence ?? '—') : '—',
                color: qualityKnown ? null : Colors.grey.shade400),
            stat('LF', spec == null ? '—' : '${spec.lf.toStringAsFixed(0)} ms²'),
            stat('HF', spec == null ? '—' : '${spec.hf.toStringAsFixed(0)} ms²'),
            // 通道方向 —— 存這個是為了事後還答得出「這筆是哪種板子量的」。
            // 'swapped' 代表當時那片把兩顆 LED 裝反了(仿製品的指紋)。
            stat(
                tr('k2_orient'),
                switch (s.channelOrient) {
                  'normal' => tr('k2_orient_normal'),
                  'swapped' => tr('k2_orient_swapped'),
                  'unknown' => tr('k2_orient_unknown'),
                  _ => '—', // 舊快照沒有這個欄位
                },
                color: s.channelOrient == 'swapped'
                    ? Colors.orange.shade800
                    : (s.channelOrient == null ? Colors.grey.shade400 : null)),
          ]),
          if (!qualityKnown)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '⚠ 這張快照存檔時還沒有記錄 SQI 與沉澱狀態,'
                '所以 SQI 與「可信度(拍數)」無法重建(顯示「—」而不是猜一個值)。'
                '上面的可信度看 SNR,不受影響。',
                style: TextStyle(fontSize: 9, color: Colors.orange.shade700),
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
            _sectionBox(
              trParams('k2_sec1', {'sec': _shortSec}),
              _liveAndShortHrv(),
              trailing: _sec1Controls(),
            ),
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

  /// 區塊 ① 標題列右側的控制項:視窗長度、實際涵蓋、存快照、進料計數。
  ///
  /// 這排本來自己佔一列,現在併進標題列 —— 側欄高度是稀缺資源,
  /// 省下的那一列直接變成多看得到一列資料。
  Widget _sec1Controls() {
    final shortPts = _adapter.pointsRecentSeconds(_shortSec);
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
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
        // 存快照:把當下 30 秒視窗存成 JSON。純 UI 行為。
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
    );
  }

  /// 即時數值列:心率 / 血氧 / 手指 / SQI / spike **橫排**,擺在區塊最上面。
  ///
  /// [c] 看狀態旗標(原始結果),[v] 看數值(手指離開時是保留的舊值)。
  /// 兩個狀態橫幅(保留中 / 沉澱期)接在同一列右側 —— 它們互斥,
  /// 而且放右邊剛好用掉本來空著的水平空間,不再另外吃掉一列高度。
  Widget _liveValuesBar(K2Compute? c, K2Compute? v, bool holding) {
    final settling = c?.settling ?? false;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _bigValue(tr('k2_hr_new'), v?.bpm?.toStringAsFixed(0), 'bpm',
              Colors.red,
              dim: holding),
          const SizedBox(width: 28),
          _bigValue(tr('k2_spo2_new'), v?.spo2?.toStringAsFixed(1), '%',
              Colors.blue,
              dim: holding),
          const SizedBox(width: 28),
          _flag(tr('k2_finger'), c?.fingerPresent ?? false),
          const SizedBox(width: 14),
          _flag('SQI', c?.sqiOk ?? false),
          const SizedBox(width: 14),
          _orientFlag(c?.orient ?? K2ChannelOrient.unknown),
          const SizedBox(width: 14),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('spike',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade700)),
            const SizedBox(height: 4),
            Text(c?.spikeMax.toStringAsFixed(2) ?? '—',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: Colors.orange.shade800)),
          ]),
          const SizedBox(width: 16),
          // 手指離開 → 顯示保留的舊值,但一定要標示出來,
          // 不然會被當成這一次量測的即時數字。
          if (holding)
            Expanded(
              child: Container(
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
            )
          // 沉澱期:明確講「在等什麼」,不要放一個 0 或殘留的舊值誤導人
          else if (settling)
            Expanded(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
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
                  style:
                      TextStyle(fontSize: 11, color: Colors.amber.shade900),
                ),
              ),
            )
          else
            const Spacer(),
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
    // 軟體端(Strapi)要的衍生欄位 —— 用**同一批** shortPts/shortHrv 算,
    // 保證畫面上的 SDNN 跟 pns/stress 那些是同一段資料導出來的。
    // 每秒算一次:Lomb-Scargle 約 250 個頻率 × 35 拍、FFT 4096 點,都可忽略。
    final metrics = Max30102VitalsMetrics.compute(
      pts: shortPts,
      hv: shortHrv,
      sqiOk: c?.sqiOk ?? false,
      settling: c?.settling ?? false,
      bpm: v?.bpm,
      ir: _adapter.waveIr,
    );
    final waveSamples = _shortSec * 100; // fs=100Hz;波形與短期 HRV 同一個視窗
    // 「N 秒前」參考線:比目前視窗小的那幾檔(視窗 30s → 畫 10s/20s 線,
    //  最左緣本身就是 30s,不另外畫)。波形圖與 RR 趨勢圖用同一組 → 兩張圖對得起來。
    final marks = [for (final s in _secOptions) if (s < _shortSec) s];
    // 佈局(對應示意圖):最上一列切視窗;下方左右分欄 —
    //   左(黃)= 垂直資料面板;右(綠)= 上波形、下 RR趨勢+Poincaré(藍)
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── 即時數值:橫排一列,擺在最上面 ────────────────────────────
        // 心率 / 血氧 / 手指 / SQI / spike 原本是直向擠在側欄最上方,
        // 佔掉約 150px 的欄高。橫排之後側欄那段高度全部還給 HRV 與衍生指標,
        // 而且這五個值本來就該一眼掃過去,不需要垂直排列。
        _liveValuesBar(c, v, holding),
        const SizedBox(height: 8),
        SizedBox(
          height: _sec1Height,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── 黃:左側垂直資料面板 ──
              _sidePanel([
                Text(trParams('k2_hrv_short', {'sec': _shortSec}),
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                // 短期不顯示拍數/對數:拍數上面已有、對數因近似成連續而恆為 N/N
                _kvList(shortHrv, shortRr.length, showCounts: false),
                const Divider(height: 18),
                Text('軟體端衍生 (Strapi)',
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                _strapiPanel(metrics),
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
        // ── LF 窗長對照實驗:全寬 ────────────────────────────────────
        // 不放側欄的理由:10 個窗 + 基準 + 統計在 215px 寬裡一定要捲,
        // 而這一塊的重點就是「一眼看完整個分布」。全寬才排得下兩欄。
        const SizedBox(height: 10),
        _lfExperimentPanelWide(),
        const SizedBox(height: 10),
        _breathHoldPanel(),
      ],
    );
  }

  /// 憋氣血氧曲線 —— 驗證波長用。
  ///
  /// 為什麼要憋氣:血氧的校正曲線綁定波長,仿製模組若用了波長偏掉的 LED,
  /// 數字會系統性偏移而看起來完全正常。但在 99% 附近曲線很平(靈敏度只有
  /// 中段的 1/8),兩片板子擠在一起看不出差 —— **要把血氧壓下去才分得出來**。
  Widget _breathHoldPanel() {
    final rec = _adapter.breathHold;
    final c = _adapter.latest;
    final orientLabel = switch (c?.orient) {
      K2ChannelOrient.normal => tr('k2_orient_normal'),
      K2ChannelOrient.swapped => tr('k2_orient_swapped'),
      _ => '',
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(4),
      ),
      child: AnimatedBuilder(
        animation: rec,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Text(tr('k2_bh_title'),
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.bold)),
              const SizedBox(width: 12),
              // 未開始 → 只能「開始」;錄製中 → 可標記恢復呼吸、可結束
              if (!rec.active)
                FilledButton.tonal(
                  onPressed: () => rec.start(_adapter.core.totalSamples,
                      orientLabel: orientLabel),
                  child: Text(tr('k2_bh_start')),
                )
              else ...[
                FilledButton.tonal(
                  onPressed: rec.resumeT == null
                      ? () => rec.markResume(_adapter.core.totalSamples)
                      : null,
                  child: Text(tr('k2_bh_resume')),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: rec.stop,
                  child: Text(tr('k2_bh_stop')),
                ),
              ],
              const SizedBox(width: 8),
              TextButton(onPressed: rec.clear, child: Text(tr('k2_bh_clear'))),
              const Spacer(),
              Text(tr('k2_bh_hint'),
                  style: TextStyle(fontSize: 9, color: Colors.grey.shade600)),
            ]),
            if (rec.abortReason != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(tr('k2_bh_abort'),
                    style:
                        TextStyle(fontSize: 10, color: Colors.orange.shade800)),
              ),
            const SizedBox(height: 6),
            SizedBox(
              height: 180,
              child: K2BreathHoldChart(
                  rec: rec, lang: LocalizationService().currentLanguage),
            ),
          ],
        ),
      ),
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

  /// 側欄的一列:左標籤、右數值。
  ///
  /// [api] 是這個值在整合方介面(aquivio-strapi / aquivio-station)裡的欄位名,
  /// 用小灰字標在標籤後面。給的話畫面上會長成 `SDNN (sdnn)` —— 對接時
  /// 不用再回頭查對照表。沒有對應欄位就不要給。
  Widget _kv(String k, String v, {Color? color, String? api}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: RichText(
                overflow: TextOverflow.ellipsis,
                text: TextSpan(
                  style:
                      TextStyle(fontSize: 11, color: Colors.grey.shade700),
                  children: [
                    TextSpan(text: k),
                    if (api != null)
                      TextSpan(
                        text: '  ($api)',
                        style: TextStyle(
                            fontSize: 9.5,
                            color: Colors.blueGrey.shade300,
                            fontFamily: 'monospace'),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 4),
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

  /// HRV 統計:**垂直列**(左標籤右數值),放進側欄用。
  /// [showCounts]:短期(UI 切窗)→ false;長期(核心算)→ true。
  Widget _kvList(HrvStats? hv, int beats, {bool showCounts = true}) {
    if (hv == null) {
      return Text(trParams('k2_hrv_insufficient', {'beats': beats}),
          style: TextStyle(fontSize: 11, color: Colors.grey.shade500));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _kv(tr('k2_hrv_score'), hv.hrvScore.toStringAsFixed(0),
            color: Colors.purple),
        // api: 整合方(aquivio-strapi / aquivio-station)介面裡的欄位名。
        // 標在這裡是為了讓「我們的名字」與「他們的名字」一眼對得起來 ——
        // 沒標 api 的欄位代表對方介面沒有要,不是我們漏給。
        _kv('SDNN', '${hv.sdnn.toStringAsFixed(1)} ms', api: 'sdnn'),
        _kv('RMSSD', '${hv.rmssd.toStringAsFixed(1)} ms', api: 'rmssd'),
        _kv('pNN50', '${hv.pnn50.toStringAsFixed(0)} %'),
        _kv('SD1', hv.sd1.toStringAsFixed(1)),
        _kv('SD2', hv.sd2.toStringAsFixed(1)),
        _kv(tr('k2_mean_rr'), '${hv.meanRr.toStringAsFixed(0)} ms'),
        _kv(tr('k2_mean_hr'), '${hv.meanHr.toStringAsFixed(0)} bpm',
            api: 'mean_hr'),
        if (showCounts) ...[
          _kv(tr('k2_beats_total'), '${hv.beats} / 300'),
          _kv(
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

  // ══════════════════════════════════════════════════════════════
  // 軟體端(Strapi)衍生指標
  // ══════════════════════════════════════════════════════════════

  /// 整合方介面要的欄位 + 我們自己的判讀。**同一批 RR,兩種尺度。**
  ///
  /// 上半是實際送出去的(對齊 aquivio-vitals 的公式與單位);
  /// 下半是我們自己的 Kubios 式 z-score,不送出去,但判讀比較有依據。
  /// 兩套並排是刻意的 —— 之前只顯示我們那套,結果「看得到的」與
  /// 「送出去的」不一致,查問題時很容易誤判。
  ///
  /// 全部由 [Max30102VitalsMetrics] 從同一批 RR 算出來,這裡只負責顯示。
  Widget _strapiPanel(VitalsMetrics m) {
    String f(double? v, {int digits = 2}) =>
        v == null ? '—' : v.toStringAsFixed(digits);

    final spec = m.spectrum;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _kv('ln(RMSSD)', f(m.lnRmssd), api: 'ln_rmssd'),
        // ── 以下四個是 aquivio-vitals 的公式,0~100 分 ──────────────
        //    pns 就是 RMSSD、ans 就是 LF/HF、stress 是前兩者的組合、
        //    activity 就是心率。它們沒有引入新資訊,只是換尺度。
        _kv('副交感', f(m.pnsScore, digits: 1), api: 'pns'),
        _kv('自律平衡', f(m.ansScore, digits: 1), api: 'ans'),
        _kv('壓力', f(m.stressScore, digits: 1), api: 'stress'),
        _kv('活動量', f(m.activityScore, digits: 1), api: 'activity'),
        _kv('可信度', m.confidenceBySnr ?? '—', api: 'confidence'),
        _kv('SQI', '${m.sqi}', api: 'sqi'),
        _kv('訊噪比', m.snrDb == null ? '—' : '${f(m.snrDb, digits: 1)} dB',
            api: 'snr_db'),
        // ── 頻域:LF / HF 分開顯示,比值另外一列 ──────────────────────
        //
        // 為什麼要分開列:比值會把資訊丟掉。LF/HF 從 0.91 變成 2.42 可能是
        // LF 漲、也可能是 HF 掉,兩者的生理意涵完全不同(後者往往只是
        // 呼吸變淺)。只看比值分不出來,看絕對值就一目瞭然。
        //
        // 顏色編碼帶著判讀:HF 在 30 秒窗是**勉強可用**的(0.15Hz 週期只有
        // 6.7 秒,30 秒有 4.5 圈),LF 則完全不可用(0.04Hz 只走 1.2 圈)。
        // 所以 LF 與比值會被灰掉,HF 維持正常色 —— 灰不灰直接對應可不可信。
        // LF / HF 用**整合方的單位**(= 我們的 ms² × 1.024e-3),因為送出去的
        // 就是這個值。ms² 的原始值放在下面「我們自己的判讀」那一區,
        // 兩者名字不同、單位標明,不會混。
        _kv(
          'LF',
          spec == null ? '—' : spec.lfAquivio.toStringAsFixed(3),
          api: 'lf',
          color: (spec?.lfUsable ?? false) ? null : Colors.grey.shade400,
        ),
        _kv(
          'HF',
          spec == null ? '—' : spec.hfAquivio.toStringAsFixed(3),
          api: 'hf',
          color: (spec?.hfUsable ?? false) ? null : Colors.grey.shade400,
        ),
        // LF/HF 在 30 秒窗一定是 null。顯示原始值(灰)讓人看得到「它算得出來,
        // 只是不可信」,而不是一個看不出原因的空白。
        _kv(
          'LF/HF',
          spec == null
              ? '—'
              : (spec.lfUsable
                  ? f(spec.lfHf)
                  : '${f(spec.lfHf)} ⚠'),
          api: 'lf_hf',
          color: (spec?.lfUsable ?? false) ? null : Colors.grey.shade400,
        ),
        if (spec != null && !spec.lfUsable)
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 2),
            child: Text(
              '⚠ LF 只走 ${spec.lfCycles.toStringAsFixed(1)} 圈'
              '(需 ≥${HrvSpectrum.minBandCycles.toStringAsFixed(0)})。'
              'HF 有 ${spec.hfCycles.toStringAsFixed(1)} 圈,是可用的那一半。\n'
              '  數字照送(攝影機端也是 30 秒),可信度另以 lf_reliable 標明',
              style: TextStyle(fontSize: 9, color: Colors.orange.shade800),
            ),
          ),

        // ── 我們自己的判讀:同一批 RR,Kubios 式 z-score ──────────────
        //
        // 不送出去。上面那套是整合方的啟發式縮放(pns 就是 RMSSD、
        // ans 就是 LF/HF),這一套有常模依據,適合我們自己判斷。
        // 兩套並排,才看得出「送出去的」與「我們認為的」差在哪。
        const Divider(height: 14),
        Row(children: [
          Text('我們自己的判讀',
              style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.bold,
                  color: Colors.blueGrey.shade600)),
          const SizedBox(width: 6),
          Text('不送出',
              style: TextStyle(fontSize: 9, color: Colors.grey.shade500)),
        ]),
        const SizedBox(height: 2),
        _kv('副交感 z', f(m.pns)),
        _kv('交感 z', f(m.sns)),
        _kv('自律平衡', f(m.ansTimeDomain)),
        _kv('壓力(Baevsky)', f(m.stress, digits: 1)),
        _kv('可信度(拍數)', m.confidence ?? '—'),
        _kv('LF', spec == null ? '—' : '${spec.lf.toStringAsFixed(0)} ms²'),
        _kv('HF', spec == null ? '—' : '${spec.hf.toStringAsFixed(0)} ms²'),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '上半是實際送出去的(對齊 aquivio-vitals 的公式與單位);\n'
            '下半是同一批 RR 的 Kubios 式 z-score,兩者尺度不同,不可互比。',
            style: TextStyle(fontSize: 9, color: Colors.grey.shade500),
          ),
        ),
      ],
    );
  }

  // ══════════════════════════════════════════════════════════════
  // LF 窗長對照實驗
  // ══════════════════════════════════════════════════════════════

  /// 2 分鐘錄一段 → 用完整長度算基準,再切成 30 秒窗跟基準比。**全寬版**。
  ///
  /// 為什麼不是「量兩次」:兩次之間人的呼吸與狀態都變了,測到的差異
  /// 分不清是窗長造成的還是生理變化造成的。同一段切窗才是對照。
  Widget _lfExperimentPanelWide() {
    final exp = _adapter.lfExperiment;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(4),
      ),
      child: ListenableBuilder(
        listenable: exp,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Text('LF 窗長對照實驗',
                    style: TextStyle(
                        fontSize: 12, fontWeight: FontWeight.bold)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                      exp.targetSeconds >= 300
                          ? '同一段錄 5 分鐘(國際標準長度),切成 30 秒窗與 2 分鐘窗跟全長比'
                          : '同一段錄 2 分鐘,切成 30 秒窗跟全長比',
                      style: TextStyle(
                          fontSize: 10.5, color: Colors.grey.shade600)),
                ),
                // 錄製長度:錄製中不給改(改了進度條的分母會跳)。
                for (final s in K2LfExperiment.durationOptions)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: ChoiceChip(
                      label: Text('${s ~/ 60} 分鐘',
                          style: const TextStyle(fontSize: 11)),
                      selected: exp.targetSeconds == s,
                      visualDensity: VisualDensity.compact,
                      onSelected: exp.running
                          ? null
                          : (_) => setState(() => exp.targetSeconds = s),
                    ),
                  ),
                const SizedBox(width: 8),
                _lfExperimentAction(exp),
              ],
            ),
            if (exp.running) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: exp.progress, minHeight: 6),
              const SizedBox(height: 4),
              Text(
                '${exp.elapsedSeconds} / ${exp.targetSeconds} 秒'
                '  ·  已收 ${exp.collectedBeats} 拍'
                '  ·  手指請保持不動,中途離開會中止實驗',
                style: TextStyle(fontSize: 11, color: Colors.orange.shade800),
              ),
              // 途中的即時頻譜 —— 看得到「窗長變長時 LF/HF 怎麼變」,
              // 尤其是圈數爬過 4 的那一刻可信度會翻轉。那個過程本身就是
              // 這個實驗要展示的東西。
              if (exp.liveSpectrum != null) _lfLiveRow(exp.liveSpectrum!),
            ],
            if (!exp.running && exp.abortReason != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  switch (exp.abortReason!) {
                    'reset' => '⚠ 手指離開,核心已歸零 → 實驗中止'
                        '(兩段時間軸不能接起來,硬接會算出無意義的數字)',
                    'cancelled' => '已取消',
                    'insufficient' => '⚠ 拍數不足,算不出頻譜',
                    _ => '已停止',
                  },
                  style:
                      TextStyle(fontSize: 11, color: Colors.orange.shade800),
                ),
              ),
            if (exp.result != null) _lfResultBody(exp.result!),
            if (exp.history.isNotEmpty) _lfHistoryBody(exp),
          ],
        ),
      ),
    );
  }

  /// 歷次錄製的摘要表。
  ///
  /// 為什麼需要它:實測發現**單次結果不能下結論** —— 第一次量到偏差中位數
  /// 75%(2/10 在 ±20% 內),第二次卻是 15%(7/10),兩次的結論完全相反。
  /// 連 2 分鐘的基準本身都從 1.06 跳到 1.97。所以要看的是**多次的分布**,
  /// 不是任何單獨一次。最下面那兩個範圍就是真正要回報的東西。
  Widget _lfHistoryBody(K2LfExperiment exp) {
    final h = exp.history;
    final bRange = exp.baselineRange;
    final mRange = exp.medianDevRange;

    Widget cell(String s, double w,
            {Color? color, bool bold = false, TextAlign align = TextAlign.right}) =>
        SizedBox(
          width: w,
          child: Text(s,
              textAlign: align,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                fontWeight: bold ? FontWeight.bold : FontWeight.normal,
                color: color,
              )),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 16),
        Row(children: [
          Text('歷次結果 (${h.length} 次)',
              style:
                  const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
          const Spacer(),
          TextButton(
            onPressed: exp.clearHistory,
            style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                textStyle: const TextStyle(fontSize: 11)),
            child: const Text('清空歷史'),
          ),
        ]),
        // 表頭
        Row(children: [
          cell('#', 26, align: TextAlign.left),
          cell('時間', 52),
          cell('長度', 46),
          cell('基準LF/HF', 74),
          cell('偏差中位數', 76),
          cell('偏差範圍', 76),
          cell('±20%內', 56),
          cell('拍數', 46),
        ]),
        const SizedBox(height: 2),
        for (final r in h)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1.5),
            child: Row(children: [
              cell('${r.index}', 26, align: TextAlign.left),
              cell(
                  '${r.time.hour.toString().padLeft(2, '0')}:'
                  '${r.time.minute.toString().padLeft(2, '0')}',
                  52,
                  color: Colors.grey.shade600),
              // 不同錄製長度的結果不能混著比 —— 標出來免得看串行
              cell('${r.targetSeconds ~/ 60} 分', 46,
                  color: Colors.blueGrey.shade400),
              cell(r.baselineLfHf.toStringAsFixed(2), 74, bold: true),
              cell('${r.medianAbsDevPct?.toStringAsFixed(0) ?? '—'}%', 76,
                  bold: true,
                  color: (r.medianAbsDevPct ?? 0) <= 20
                      ? Colors.green.shade700
                      : ((r.medianAbsDevPct ?? 0) <= 50
                          ? Colors.orange.shade800
                          : Colors.red.shade700)),
              cell(
                  '${r.minAbsDevPct?.toStringAsFixed(0) ?? '—'}'
                  '~${r.maxAbsDevPct?.toStringAsFixed(0) ?? '—'}%',
                  76,
                  color: Colors.grey.shade700),
              cell('${r.within20}/${r.windowCount}', 56),
              cell('${r.beats}', 46, color: Colors.grey.shade600),
            ]),
          ),
        if (h.length >= 2) ...[
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.blueGrey.shade50,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '跨次分布  ·  基準 LF/HF '
                  '${bRange!.$1.toStringAsFixed(2)}~${bRange.$2.toStringAsFixed(2)}'
                  '  ·  偏差中位數 '
                  '${mRange == null ? '—' : '${mRange.$1.toStringAsFixed(0)}~${mRange.$2.toStringAsFixed(0)}%'}',
                  style: const TextStyle(
                      fontSize: 11.5, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 2),
                Text(
                  '基準本身若跨次差很多,代表連 2 分鐘的尺都在動;'
                  '偏差中位數若跨次差很多,代表「30 秒差多少」這件事本身不可預測。',
                  style:
                      TextStyle(fontSize: 10, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// 錄製途中的即時頻譜列。
  ///
  /// 重點是 LF 的圈數 —— 錄製開始時只有一兩圈(灰、✗),隨著窗長變長爬升,
  /// 過 4 之後翻成可信(綠、✓)。**同一段資料,只是看得更久,結論就不一樣**,
  /// 這正是整個實驗要說明的事,所以讓它在畫面上發生一次比看結果表更有感。
  Widget _lfLiveRow(HrvSpectrum s) {
    Widget item(String k, String v, {Color? color}) => Padding(
          padding: const EdgeInsets.only(right: 18),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text('$k ',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade700)),
            Text(v,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                    color: color)),
          ]),
        );

    final ok = s.lfUsable;
    final okColor = ok ? Colors.green.shade700 : Colors.grey.shade500;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          item('目前累積', '${s.spanSeconds.toStringAsFixed(0)}s'),
          item('LF/HF', s.lfHf.toStringAsFixed(2), color: okColor),
          item('LF', '${s.lf.toStringAsFixed(0)} ms²', color: okColor),
          item('HF', '${s.hf.toStringAsFixed(0)} ms²'),
          item(
            'LF 圈數',
            '${s.lfCycles.toStringAsFixed(1)} '
                '${ok ? "✓ 可信" : "✗ 需 ≥${HrvSpectrum.minBandCycles.toStringAsFixed(0)}"}',
            color: okColor,
          ),
        ],
      ),
    );
  }

  /// 右上角那顆按鈕:依狀態換成 開始 / 取消 / 再測一次。
  Widget _lfExperimentAction(K2LfExperiment exp) {
    if (exp.running) {
      return OutlinedButton(
        onPressed: exp.cancel,
        style: OutlinedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            textStyle: const TextStyle(fontSize: 12)),
        child: const Text('取消'),
      );
    }
    if (exp.result != null) {
      return OutlinedButton(
        onPressed: exp.clear,
        style: OutlinedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            textStyle: const TextStyle(fontSize: 12)),
        child: const Text('清除,再測一次'),
      );
    }
    return FilledButton.tonal(
      onPressed: () => exp.start(_adapter.core.totalSamples),
      style: FilledButton.styleFrom(
          visualDensity: VisualDensity.compact,
          textStyle: const TextStyle(fontSize: 12)),
      child: const Text('開始 2 分鐘錄製'),
    );
  }

  /// 帶正負號的百分比。**先四捨五入再決定符號** —— 否則 −0.3 會顯示成「-0%」。
  static String _pct(double v) {
    final n = v.round();
    return '${n > 0 ? '+' : ''}$n%';
  }

  /// 結果本體:基準一列、10 個窗分兩欄、結論一列。
  Widget _lfResultBody(LfExperimentResult r) {
    final b = r.baseline;
    Color devColor(double d) {
      final a = d.abs();
      if (a <= 20) return Colors.green.shade700;
      if (a <= 50) return Colors.orange.shade800;
      return Colors.red.shade700;
    }

    Widget stat(String k, String v, {Color? color}) => Padding(
          padding: const EdgeInsets.only(right: 20),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text('$k ',
                style:
                    TextStyle(fontSize: 11, color: Colors.grey.shade700)),
            Text(v,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                    color: color)),
          ]),
        );

    Widget windowRow(LfWindow w) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 1.5),
          child: Row(
            children: [
              SizedBox(
                width: 62,
                child: Text('${w.startSec.toInt()}-${w.endSec.toInt()}s',
                    style: TextStyle(
                        fontSize: 11, color: Colors.grey.shade600)),
              ),
              SizedBox(
                width: 50,
                child: Text(w.spec.lfHf.toStringAsFixed(2),
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                        fontSize: 12, fontFamily: 'monospace')),
              ),
              SizedBox(
                width: 62,
                child: Text(
                  // 先四捨五入再決定正負號 —— 直接 toStringAsFixed(0) 會讓
                  // −0.3 顯示成「-0%」。
                  _pct(w.lfHfDevPct),
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                    color: devColor(w.lfHfDevPct),
                  ),
                ),
              ),
            ],
          ),
        );

    /// 一組窗:標題 + 表格(自動分欄,每欄最多 10 列)+ 該組的結論。
    Widget groupBlock(LfWindowGroup g) {
      final n = g.windows.length;
      final cols = math.max(2, (n / 10).ceil());
      final rows = (n / cols).ceil();
      final median = g.medianAbsDevPct ?? 0;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          Text(
            '${g.windowSeconds} 秒窗 ($n 個,每 ${g.stepSeconds} 秒滑動一次)',
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (int cIdx = 0; cIdx < cols; cIdx++) ...[
                if (cIdx > 0) const SizedBox(width: 24),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final w in g.windows.skip(cIdx * rows).take(rows))
                      windowRow(w),
                  ],
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Wrap(children: [
            stat('偏差中位數', '${g.medianAbsDevPct?.toStringAsFixed(0) ?? '—'}%',
                color: median <= 20
                    ? Colors.green.shade700
                    : (median <= 50
                        ? Colors.orange.shade800
                        : Colors.red.shade700)),
            stat(
                '偏差範圍',
                '${g.minAbsDevPct?.toStringAsFixed(0) ?? '—'}'
                    '~${g.maxAbsDevPct?.toStringAsFixed(0) ?? '—'}%'),
            stat('±20% 內', '${g.within20}/$n'),
          ]),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 16),
        Wrap(children: [
          stat('基準', '${b.spanSeconds.toStringAsFixed(0)}s · ${b.beats} 拍'),
          stat('LF/HF', b.lfHf.toStringAsFixed(2)),
          stat('LF', '${b.lf.toStringAsFixed(0)} ms²'),
          stat('HF', '${b.hf.toStringAsFixed(0)} ms²'),
        ]),
        for (int i = 0; i < r.groups.length; i++) ...[
          if (i > 0) const Divider(height: 14),
          groupBlock(r.groups[i]),
        ],
        // 錄 5 分鐘時會有 2 分鐘那一組 —— 它回答的是「我們前面一直拿來當基準
        // 的 2 分鐘,本身夠不夠格當基準」。這句話點出該怎麼讀那組數字。
        if (r.groups.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '2 分鐘窗那一組的偏差 = 「拿 2 分鐘當基準」本身的誤差有多大。'
              '若它也偏得多,代表先前用 2 分鐘當基準的那幾次實驗,尺本身就不準。',
              style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
            ),
          ),
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
  /// [trailing] 會擺在**標題的同一列**(靠右)。
  /// 控制項併進標題列可以省下一整列的高度 —— 側欄本來就不夠高,
  /// 少一列就多看得到一列資料。
  Widget _sectionBox(String title, Widget child, {Widget? trailing}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.bold)),
                if (trailing != null) ...[
                  const SizedBox(width: 16),
                  Expanded(child: trailing),
                ],
              ],
            ),
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

  /// 通道方向指示 —— **除錯用，這是這個 App 存在的理由之一**。
  ///
  /// 有些 MAX30102 模組把兩顆 LED 晶粒裝反(實測 8 片中 7 片如此),核心會
  /// 每次量測自己判定一次。沒有這個指示的話,只能從「波形晚兩秒出現」、
  /// 「血氧一開始是空的」這些間接現象去猜,插上板子看不出答案。
  ///
  /// 三個狀態刻意用不同顏色:
  ///   · 判定中(灰)—— 此時沒有波形、沒有血氧,心率照給
  ///   · 正常(綠)  —— 符合 datasheet
  ///   · 已轉正(橘)—— 這片裝反了,**核心已經把輸出轉正**,不是錯誤狀態,
  ///                  但值得注意,所以用橘色而不是綠色
  Widget _orientFlag(K2ChannelOrient o) {
    final (String key, Color bg, Color fg) = switch (o) {
      K2ChannelOrient.unknown => (
          'k2_orient_unknown',
          Colors.grey.shade300,
          Colors.grey.shade600
        ),
      K2ChannelOrient.normal => (
          'k2_orient_normal',
          Colors.green.shade100,
          Colors.green.shade800
        ),
      K2ChannelOrient.swapped => (
          'k2_orient_swapped',
          Colors.orange.shade100,
          Colors.orange.shade900
        ),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr('k2_orient'),
            style: TextStyle(fontSize: 11, color: Colors.grey.shade700)),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(tr(key),
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.bold, color: fg)),
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
