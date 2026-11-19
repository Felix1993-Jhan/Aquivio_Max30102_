// ============================================================================
// MaxChipPage — MAX30102 晶片暫存器對照頁
// ============================================================================
// 功能：
// - 左右兩欄 = 兩個「紀錄欄位」（第 1 片 / 第 2 片）。串口同時只接一片，
//   接哪片就按哪一欄的按鈕，結果寫在那一欄；兩欄同一列數值不同時標色。
// - 每欄：INIT / RESET / LED1、LED2 電流（hex 填值送出、恢復預設 0x24）/
//   一鍵讀取（17 個暫存器 + 晶片溫度）/ 每列單獨讀取。
// - 最下方：每個暫存器各個值的意義（依 MAX30102 datasheet）。
//
// 串口：共用 _urManager。進本頁時 main_navigation_page 會停掉心跳
// （PING 的回應會混進讀暫存器的回應），本頁自己掛 onRawBytes，離開時卸下。
// 一次只送一包、等到對應的回應（或逾時）才送下一包。
//
// 文字說明：暫存器解讀與說明區是本頁專屬的技術內容，用 _l(中, 英) 就地雙語，
// 不放進 localization_service 的共用表。
// ============================================================================

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_firmware_tester_unified/shared/services/serial_port_manager.dart';
import 'package:flutter_firmware_tester_unified/shared/services/localization_service.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_protocol.dart';

/// 就地雙語
String _l(String zh, String en) =>
    LocalizationService().currentLanguage == AppLanguage.zhTW ? zh : en;

String _h(int v) => '0x${v.toRadixString(16).padLeft(2, '0').toUpperCase()}';

/// 列出某暫存器裡「為 1 的旗標」
String _flags(int v, List<(int bit, String name)> defs) {
  final on = [for (final d in defs) if (v & (1 << d.$1) != 0) d.$2];
  return on.isEmpty ? _l('無', 'none') : on.join(', ');
}

/// MAX30102 Multi-LED 的 SLOT 代碼
String _slot(int code) => switch (code) {
      0 => _l('關', 'off'),
      1 => 'LED1',
      2 => 'LED2',
      _ => _l('無/保留', 'none/rsvd'),
    };

/// 一個暫存器：位址、名稱、解碼、說明
class _Reg {
  const _Reg(this.addr, this.name, this.decode, this.help, {this.live = false});
  final int addr;
  final String name;
  final String Function(int v) decode;
  final String Function() help;

  /// 即時值（中斷旗標、FIFO 指標…）：兩片不同是正常的，不標色
  final bool live;
}

final List<_Reg> _regs = [
  _Reg(0x00, 'Interrupt Status 1',
      (v) => _flags(v, [(7, 'A_FULL'), (6, 'PPG_RDY'), (5, 'ALC_OVF'), (0, 'PWR_RDY')]),
      () => _l(
          'bit7 A_FULL：FIFO 快滿（未讀筆數達門檻）\nbit6 PPG_RDY：FIFO 有新樣本\n'
              'bit5 ALC_OVF：環境光抵銷到極限，環境光已影響讀數\nbit0 PWR_RDY：剛上電或掉電後恢復\n'
              '⚠ 讀取這個暫存器會清除旗標',
          'bit7 A_FULL: FIFO almost full\nbit6 PPG_RDY: new sample in FIFO\n'
              'bit5 ALC_OVF: ambient light cancellation at its limit\nbit0 PWR_RDY: power-up / brown-out recovery\n'
              '⚠ Reading this register clears the flags'),
      live: true),
  _Reg(0x01, 'Interrupt Status 2', (v) => _flags(v, [(1, 'DIE_TEMP_RDY')]),
      () => _l('bit1 DIE_TEMP_RDY：晶片溫度量測完成\n⚠ 讀取會清除旗標',
          'bit1 DIE_TEMP_RDY: die temperature conversion finished\n⚠ Reading clears the flag'),
      live: true),
  _Reg(0x02, 'Interrupt Enable 1',
      (v) => _flags(v, [(7, 'A_FULL_EN'), (6, 'PPG_RDY_EN'), (5, 'ALC_OVF_EN')]),
      () => _l('哪些中斷會拉低 INT 腳。bit7 / bit6 / bit5 對應 Status 1 的同名旗標',
          'Which interrupts pull the INT pin low. bit7/6/5 match the Status 1 flags')),
  _Reg(0x03, 'Interrupt Enable 2', (v) => _flags(v, [(1, 'DIE_TEMP_RDY_EN')]),
      () => _l('bit1：溫度量測完成時發中斷', 'bit1: interrupt when temperature is ready')),
  _Reg(0x04, 'FIFO_WR_PTR', (v) => _l('位置 ${v & 0x1F}', 'slot ${v & 0x1F}'),
      () => _l('晶片下一筆要寫入的 FIFO 位置（0~31）', 'Next FIFO slot the chip writes to (0–31)'),
      live: true),
  _Reg(0x05, 'OVF_COUNTER',
      (v) => (v & 0x1F) == 0 ? _l('無溢位', 'no overflow') : _l('丟了 ${v & 0x1F} 筆', '${v & 0x1F} lost'),
      () => _l('FIFO 滿了之後被丟掉的樣本數（上限 31）。0 = 韌體讀得夠快',
          'Samples lost after the FIFO filled (max 31). 0 = firmware keeps up'),
      live: true),
  _Reg(0x06, 'FIFO_RD_PTR', (v) => _l('位置 ${v & 0x1F}', 'slot ${v & 0x1F}'),
      () => _l('下一筆要被讀走的 FIFO 位置。與寫指標相等 = FIFO 已讀空',
          'Next FIFO slot to be read. Equal to WR_PTR = FIFO empty'),
      live: true),
  _Reg(0x08, 'FIFO Config', (v) {
    const avg = [1, 2, 4, 8, 16, 32, 32, 32];
    final roll = v & 0x10 != 0;
    return _l(
        '平均 ${avg[v >> 5]} 筆、${roll ? '滿了覆蓋' : '滿了停住'}、剩 ${v & 0xF} 格空時中斷',
        'avg ${avg[v >> 5]}, ${roll ? 'roll over' : 'stop when full'}, A_FULL at ${v & 0xF} free');
  },
      () => _l(
          'bit7:5 SMP_AVE：幾筆平均成一筆（000=1、001=2、010=4、011=8、100=16、101~111=32）\n'
              'bit4 FIFO_ROLLOVER_EN：1 = 滿了繼續寫、覆蓋舊的；0 = 滿了停住\n'
              'bit3:0 FIFO_A_FULL：剩幾格空時發 A_FULL 中斷（0xF = 剩 15 格空 / 17 筆未讀）',
          'bit7:5 SMP_AVE: samples averaged (000=1, 001=2, 010=4, 011=8, 100=16, 101–111=32)\n'
              'bit4 FIFO_ROLLOVER_EN: 1 = overwrite when full; 0 = stop when full\n'
              'bit3:0 FIFO_A_FULL: free slots left when A_FULL fires (0xF = 15 free / 17 unread)')),
  _Reg(0x09, 'Mode Config', (v) {
    final m = switch (v & 7) {
      0 => _l('000 POR 狀態（不採樣）', '000 POR state (idle)'),
      2 => _l('HR（只有 LED1）', 'HR (LED1 only)'),
      3 => _l('SpO2（LED1 + LED2）', 'SpO2 (LED1 + LED2)'),
      7 => 'Multi-LED',
      _ => _l('不可用的值', 'invalid'),
    };
    final extra = [if (v & 0x80 != 0) 'SHDN', if (v & 0x40 != 0) 'RESET'];
    return extra.isEmpty ? m : '$m, ${extra.join(', ')}';
  },
      () => _l(
          'bit2:0 MODE：000 = POR 狀態（RESET 後就是這個，不點燈不採樣）、010 = HR（只有 LED1）、'
              '011 = SpO2（LED1 + LED2，我們用這個）、111 = Multi-LED（由 SLOT 決定）\n'
              'bit7 SHDN：1 = 省電關機，暫存器保留\nbit6 RESET：寫 1 觸發軟體復位，完成後自動回 0',
          'bit2:0 MODE: 000 = POR state (after RESET: no LEDs, no sampling), 010 = HR (LED1 only), '
              '011 = SpO2 (LED1 + LED2, what we use), 111 = Multi-LED (set by SLOTs)\n'
              'bit7 SHDN: 1 = power-save, registers kept\nbit6 RESET: write 1 to soft-reset, self-clears')),
  _Reg(0x0A, 'SpO2 Config', (v) {
    const rge = [2048, 4096, 8192, 16384];
    const sr = [50, 100, 200, 400, 800, 1000, 1600, 3200];
    const pw = [69, 118, 215, 411];
    return '${rge[(v >> 5) & 3]} nA, ${sr[(v >> 2) & 7]} sps, ${pw[v & 3]} µs / ${15 + (v & 3)}-bit';
  },
      () => _l(
          'bit6:5 ADC 量程：00=2048、01=4096、10=8192、11=16384 nA\n'
              'bit4:2 取樣率：000=50、001=100、010=200、011=400、100=800、101=1000、110=1600、111=3200 sps\n'
              'bit1:0 脈寬 / 解析度：00=69µs/15-bit、01=118µs/16-bit、10=215µs/17-bit、11=411µs/18-bit',
          'bit6:5 ADC range: 00=2048, 01=4096, 10=8192, 11=16384 nA\n'
              'bit4:2 sample rate: 000=50, 001=100, 010=200, 011=400, 100=800, 101=1000, 110=1600, 111=3200 sps\n'
              'bit1:0 pulse width / resolution: 00=69µs/15-bit, 01=118µs/16-bit, 10=215µs/17-bit, 11=411µs/18-bit')),
  _Reg(0x0C, 'LED1_PA', (v) => v == 0 ? _l('關閉', 'off') : '${(v * 0.2).toStringAsFixed(1)} mA',
      () => _l(
          'LED1 電流，每格 0.2 mA（0x00 = 關、0x24 = 7.2 mA、0xFF = 51 mA）。'
              'datasheet 規定 LED1 是紅光，但今華那批模組裝反，實際是紅外',
          'LED1 current, 0.2 mA per step (0x00 = off, 0x24 = 7.2 mA, 0xFF = 51 mA). '
              'Datasheet says LED1 = red; on the swapped modules it is actually IR')),
  _Reg(0x0D, 'LED2_PA', (v) => v == 0 ? _l('關閉', 'off') : '${(v * 0.2).toStringAsFixed(1)} mA',
      () => _l('LED2 電流，同上。datasheet 規定是紅外；裝反的模組實際是紅光',
          'LED2 current, same scale. Datasheet says IR; red on swapped modules')),
  _Reg(0x11, 'Multi-LED SLOT2|SLOT1', (v) => 'SLOT1=${_slot(v & 7)}, SLOT2=${_slot((v >> 4) & 7)}',
      () => _l(
          '只在 Mode = Multi-LED 時有效。bit2:0 = SLOT1、bit6:4 = SLOT2\n'
              '代碼：000 = 關、001 = LED1、010 = LED2、其餘 = 無（MAX30101 的 011 是綠光）',
          'Only used in Multi-LED mode. bit2:0 = SLOT1, bit6:4 = SLOT2\n'
              'Codes: 000 = off, 001 = LED1, 010 = LED2, others = none (011 = green on MAX30101)')),
  _Reg(0x12, 'Multi-LED SLOT4|SLOT3', (v) => 'SLOT3=${_slot(v & 7)}, SLOT4=${_slot((v >> 4) & 7)}',
      () => _l('同上，bit2:0 = SLOT3、bit6:4 = SLOT4', 'Same, bit2:0 = SLOT3, bit6:4 = SLOT4')),
  _Reg(0x21, 'Die Temp Config',
      (v) => v & 1 != 0 ? _l('量測中', 'measuring') : _l('閒置', 'idle'),
      () => _l('bit0 TEMP_EN：寫 1 觸發一次溫度量測（約 29 ms），完成後自動回 0',
          'bit0 TEMP_EN: write 1 to start one conversion (~29 ms), self-clears'),
      live: true),
  _Reg(0xFE, 'REV_ID', (v) => _l('改版號', 'silicon revision'),
      () => _l('矽晶片改版號。原廠未公開對照表，只能比較兩片是否同一版；分不出型號，也分不出仿製',
          'Silicon revision. No public table — only tells whether two parts share a revision; '
              'cannot identify the model or a clone')),
  _Reg(0xFF, 'PART_ID', (v) => switch (v) {
        0x15 => 'MAX30101 / MAX30102',
        0x11 => 'MAX30100',
        _ => _l('未知', 'unknown'),
      },
      () => _l('型號 ID：0x15 = MAX30101 或 MAX30102（兩者相同，分不出來）、0x11 = MAX30100',
          'Part ID: 0x15 = MAX30101 or MAX30102 (identical), 0x11 = MAX30100')),
];

/// 一欄（一片）的紀錄
class _Side {
  _Side(this.title);
  final String Function() title;
  final Map<int, int> regs = {};
  double? temp;
  DateTime? at;
  String status = '';
  bool error = false;
  final led1 = TextEditingController(text: '24');
  final led2 = TextEditingController(text: '24');

  void dispose() {
    led1.dispose();
    led2.dispose();
  }
}

class MaxChipPage extends StatefulWidget {
  const MaxChipPage({super.key, required this.manager});

  /// 共用串口（不在本頁開關）
  final SerialPortManager manager;

  @override
  State<MaxChipPage> createState() => _MaxChipPageState();
}

class _MaxChipPageState extends State<MaxChipPage> {
  final _parser = Max30102RxParser();
  final _scroll = ScrollController();
  late final List<_Side> _sides = [
    _Side(() => _l('左：第 1 片', 'Left: unit 1')),
    _Side(() => _l('右：第 2 片', 'Right: unit 2')),
  ];

  /// 一問一答：正在等的回應
  Completer<Uint8List>? _wait;
  int _waitSub = -1;
  int _waitReg = -1;

  /// 有動作在跑時，兩欄的按鈕全部停用（只有一條串口）
  bool _busy = false;

  static const _timeout = Duration(milliseconds: 300);

  @override
  void initState() {
    super.initState();
    _parser.onPacket = _onPacket;
    widget.manager.onRawBytes = _parser.feed;
  }

  @override
  void dispose() {
    if (widget.manager.onRawBytes == _parser.feed) widget.manager.onRawBytes = null;
    _scroll.dispose();
    for (final s in _sides) {
      s.dispose();
    }
    super.dispose();
  }

  // ==================== 串口一問一答 ====================

  void _onPacket(Uint8List p) {
    final c = _wait;
    if (c == null || c.isCompleted || p[4] != _waitSub) return;
    final regCmd = _waitSub == Max30102Protocol.kSubReadReg ||
        _waitSub == Max30102Protocol.kSubWriteReg;
    if (regCmd && p[5] != _waitReg) return;
    c.complete(p);
  }

  /// 送一包並等對應的回應；沒連線 / 送失敗 / 逾時都回 null
  Future<Uint8List?> _xfer(Uint8List pkt) async {
    if (!widget.manager.isConnected) return null;
    final c = Completer<Uint8List>();
    _wait = c;
    _waitSub = pkt[4];
    _waitReg = pkt[5];
    if (!widget.manager.sendHex(pkt)) {
      _wait = null;
      return null;
    }
    try {
      return await c.future.timeout(_timeout);
    } on TimeoutException {
      return null;
    } finally {
      if (identical(_wait, c)) _wait = null;
    }
  }

  Future<int?> _readReg(int reg) async {
    final r = await _xfer(Max30102Protocol.buildReadReg(reg));
    return r?[6];
  }

  /// 把一個動作包成「忙碌中 → 執行 → 寫狀態列」
  Future<void> _run(_Side s, Future<String?> Function() job) async {
    if (_busy) return;
    if (!widget.manager.isConnected) {
      setState(() => s
        ..status = _l('STM32 未連接', 'STM32 not connected')
        ..error = true);
      return;
    }
    setState(() => _busy = true);
    final err = await job(); // null = 成功（狀態由 job 自己寫）
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (err != null) {
        s.status = err;
        s.error = true;
      }
    });
  }

  String get _noReply => _l('無回應', 'no reply');

  void _ok(_Side s, String msg) {
    s.status = msg;
    s.error = false;
  }

  // ==================== 動作 ====================

  Future<String?> _readOne(_Side s, int reg) async {
    final v = await _readReg(reg);
    if (v == null) return '${_h(reg)} $_noReply';
    s.regs[reg] = v;
    s.at = DateTime.now();
    _ok(s, '${_h(reg)} = ${_h(v)}');
    return null;
  }

  Future<String?> _readTemp(_Side s) async {
    if (await _xfer(Max30102Protocol.buildWriteReg(0x21, 0x01)) == null) {
      return _l('溫度觸發 $_noReply', 'temp trigger: no reply');
    }
    await Future.delayed(const Duration(milliseconds: 100));
    final ti = await _readReg(0x1F);
    final tf = await _readReg(0x20);
    if (ti == null || tf == null) return _l('溫度讀取 $_noReply', 'temp read: no reply');
    s.temp = (ti > 127 ? ti - 256 : ti) + (tf & 0x0F) * 0.0625;
    s.at = DateTime.now();
    _ok(s, _l('溫度 ${s.temp!.toStringAsFixed(2)} °C', 'temp ${s.temp!.toStringAsFixed(2)} °C'));
    return null;
  }

  Future<String?> _readAll(_Side s) async {
    final fail = <String>[];
    for (final r in _regs) {
      final v = await _readReg(r.addr);
      if (v == null) {
        fail.add(_h(r.addr));
      } else {
        s.regs[r.addr] = v;
      }
    }
    final tErr = await _readTemp(s);
    if (tErr != null) fail.add(_l('溫度', 'temp'));
    s.at = DateTime.now();
    if (fail.isNotEmpty) return _l('讀取失敗：${fail.join(' ')}', 'failed: ${fail.join(' ')}');
    _ok(s, _l('全部讀取完成', 'all registers read'));
    return null;
  }

  Future<String?> _init(_Side s) async {
    final r = await _xfer(Max30102Protocol.buildReInit());
    if (r == null) return 'INIT $_noReply';
    if (r[5] != 1) return _l('INIT 失敗（韌體回報晶片沒有回應）', 'INIT failed (chip did not respond)');
    _ok(s, _l('INIT 成功', 'INIT OK'));
    return null;
  }

  Future<String?> _reset(_Side s) async {
    if (await _xfer(Max30102Protocol.buildReset()) == null) return 'RESET $_noReply';
    _ok(s, _l('RESET 完成（晶片休眠，要 INIT 才會恢復）', 'RESET done (chip idle until INIT)'));
    return null;
  }

  /// 寫 LED 電流後讀回確認（[v] 為 null = 輸入格式錯誤）
  Future<String?> _setLed(_Side s, int reg, int? v) async {
    if (v == null || v < 0 || v > 0xFF) return _l('請填 00~FF', 'enter 00–FF');
    if (await _xfer(Max30102Protocol.buildWriteReg(reg, v)) == null) {
      return '${_h(reg)} ${_l('寫入', 'write')} $_noReply';
    }
    final back = await _readReg(reg);
    if (back == null) return '${_h(reg)} ${_l('讀回', 'read-back')} $_noReply';
    s.regs[reg] = back;
    s.at = DateTime.now();
    if (back != v) return _l('寫入 ${_h(v)}，讀回卻是 ${_h(back)}', 'wrote ${_h(v)}, read back ${_h(back)}');
    _ok(s, _l('${_h(reg)} 寫入並讀回 ${_h(back)}', '${_h(reg)} written, read back ${_h(back)}'));
    return null;
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: _scroll,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _scroll,
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ValueListenableBuilder<bool>(
              valueListenable: widget.manager.isConnectedNotifier,
              builder: (_, connected, _) => connected
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        _l('⚠ STM32 未連接。請先到「MAX30102 K2」或「STM32 控制」頁連線。',
                            '⚠ STM32 not connected. Connect from the K2 or STM32 Control page first.'),
                        style: TextStyle(color: Colors.red.shade700),
                      ),
                    ),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _controls(_sides[0])),
                const SizedBox(width: 12),
                Expanded(child: _controls(_sides[1])),
              ],
            ),
            const SizedBox(height: 12),
            _table(),
            const SizedBox(height: 4),
            Text(
              _l('■ 黃底 = 兩片設定值不同。即時值（中斷旗標、FIFO 指標、溫度）本來就會變，不標色。',
                  '■ Yellow = settings differ between the two units. Live values (flags, FIFO pointers, temp) are not highlighted.'),
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 16),
            _help(),
          ],
        ),
      ),
    );
  }

  Widget _card({required Widget child}) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.black12),
        ),
        child: child,
      );

  /// 一欄的控制區
  Widget _controls(_Side s) {
    final idle = !_busy;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s.title(), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: idle ? () => _run(s, () => _readAll(s)) : null,
                icon: const Icon(Icons.playlist_add_check, size: 16),
                label: Text(_l('一鍵讀取', 'Read all')),
              ),
              OutlinedButton(
                onPressed: idle ? () => _run(s, () => _init(s)) : null,
                child: const Text('INIT'),
              ),
              OutlinedButton(
                onPressed: idle ? () => _run(s, () => _reset(s)) : null,
                child: const Text('RESET'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _ledRow(s, Max30102Protocol.kRegLedRed, s.led1, _l('LED1（0x0C，規格：紅光）', 'LED1 (0x0C, spec: red)')),
          const SizedBox(height: 6),
          _ledRow(s, Max30102Protocol.kRegLedIr, s.led2, _l('LED2（0x0D，規格：紅外）', 'LED2 (0x0D, spec: IR)')),
          const SizedBox(height: 8),
          Text(
            s.status.isEmpty ? ' ' : s.status,
            style: TextStyle(fontSize: 12, color: s.error ? Colors.red.shade700 : Colors.green.shade800),
          ),
        ],
      ),
    );
  }

  Widget _ledRow(_Side s, int reg, TextEditingController ctl, String label) {
    final idle = !_busy;
    void send() => _run(s, () => _setLed(s, reg, int.tryParse(ctl.text, radix: 16)));
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(label, style: const TextStyle(fontSize: 13)),
        SizedBox(
          width: 64,
          child: TextField(
            controller: ctl,
            enabled: idle,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F]')),
              LengthLimitingTextInputFormatter(2),
            ],
            style: const TextStyle(fontFamily: 'Consolas'),
            decoration: const InputDecoration(
              prefixText: '0x',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => send(),
          ),
        ),
        // 換算 mA（跟著輸入即時更新）
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: ctl,
          builder: (_, t, _) {
            final v = int.tryParse(t.text, radix: 16);
            return Text(v == null ? '—' : '${(v * 0.2).toStringAsFixed(1)} mA',
                style: const TextStyle(fontSize: 12, color: Colors.black54));
          },
        ),
        OutlinedButton(
          onPressed: idle ? send : null,
          child: Text(_l('送出', 'Send')),
        ),
        // 恢復預設：直接送 0x24，輸入框保持使用者填的值不動
        TextButton(
          onPressed: idle
              ? () => _run(s, () => _setLed(s, reg, Max30102Protocol.kLedBaseline))
              : null,
          child: Text(_l('恢復預設 0x24', 'Default 0x24')),
        ),
      ],
    );
  }

  /// 對照表：暫存器 | 第 1 片 | 第 2 片
  Widget _table() {
    const head = TextStyle(fontWeight: FontWeight.bold);
    final rows = <TableRow>[
      TableRow(
        decoration: BoxDecoration(color: Colors.teal.shade50),
        children: [
          _cell(Text(_l('暫存器', 'Register'), style: head)),
          for (final s in _sides)
            _cell(Text(s.at == null ? s.title() : '${s.title()}  ${_time(s.at!)}', style: head)),
        ],
      ),
      for (final r in _regs) _regRow(r),
      _tempRow(),
    ];
    return _card(
      child: Table(
        columnWidths: const {0: FlexColumnWidth(0.9), 1: FlexColumnWidth(1), 2: FlexColumnWidth(1)},
        border: TableBorder.symmetric(inside: const BorderSide(color: Colors.black12)),
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: rows,
      ),
    );
  }

  String _time(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

  TableRow _regRow(_Reg r) {
    final a = _sides[0].regs[r.addr], b = _sides[1].regs[r.addr];
    final differ = !r.live && a != null && b != null && a != b;
    return TableRow(
      decoration: differ ? BoxDecoration(color: Colors.amber.shade100) : null,
      children: [
        _cell(Text('${_h(r.addr)}  ${r.name}${r.live ? _l('（即時）', ' (live)') : ''}',
            style: const TextStyle(fontSize: 13))),
        for (final s in _sides)
          _valueCell(
            s.regs[r.addr] == null ? null : _h(s.regs[r.addr]!),
            s.regs[r.addr] == null ? null : r.decode(s.regs[r.addr]!),
            () => _run(s, () => _readOne(s, r.addr)),
          ),
      ],
    );
  }

  TableRow _tempRow() => TableRow(children: [
        _cell(Text(_l('0x1F/0x20  晶片溫度（即時）', '0x1F/0x20  Die temp (live)'),
            style: const TextStyle(fontSize: 13))),
        for (final s in _sides)
          _valueCell(
            s.temp == null ? null : '${s.temp!.toStringAsFixed(2)} °C',
            null,
            () => _run(s, () => _readTemp(s)),
          ),
      ]);

  Widget _cell(Widget child) =>
      Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6), child: child);

  Widget _valueCell(String? value, String? decoded, VoidCallback onRead) => _cell(Row(
        children: [
          Expanded(
            child: value == null
                ? const Text('—', style: TextStyle(color: Colors.black38))
                : Text.rich(TextSpan(children: [
                    TextSpan(
                        text: value,
                        style: const TextStyle(fontFamily: 'Consolas', fontWeight: FontWeight.bold)),
                    if (decoded != null)
                      TextSpan(text: '  $decoded', style: const TextStyle(fontSize: 12, color: Colors.black87)),
                  ])),
          ),
          IconButton(
            onPressed: _busy ? null : onRead,
            icon: const Icon(Icons.refresh, size: 16),
            tooltip: _l('讀取這一項', 'Read this'),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ));

  /// 說明區：每個暫存器的值代表什麼
  Widget _help() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_l('暫存器說明（MAX30102 datasheet）', 'Register reference (MAX30102 datasheet)'),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          for (final r in _regs) ...[
            Text('${_h(r.addr)}  ${r.name}', style: const TextStyle(fontWeight: FontWeight.w600)),
            Padding(
              padding: const EdgeInsets.only(left: 16, top: 2, bottom: 8),
              child: Text(r.help(), style: const TextStyle(fontSize: 13)),
            ),
          ],
          Text(_l('0x1F / 0x20  晶片溫度', '0x1F / 0x20  Die temperature'),
              style: const TextStyle(fontWeight: FontWeight.w600)),
          Padding(
            padding: const EdgeInsets.only(left: 16, top: 2, bottom: 8),
            child: Text(
              _l('TINT（0x1F）= 整數部分，二補數，每格 1 °C；TFRAC（0x20）bit3:0 = 小數，每格 0.0625 °C。'
                  '要先寫 0x21 = 1 觸發量測才會更新（一鍵讀取會自動做）',
                  'TINT (0x1F) = integer part, two\'s complement, 1 °C/LSB; TFRAC (0x20) bit3:0 = fraction, 0.0625 °C/LSB. '
                  'Updated only after writing 0x21 = 1 (Read all does this)'),
              style: const TextStyle(fontSize: 13),
            ),
          ),
          Text(
            _l('辨別 LED 是否裝反：送 40 71 31 09 01 0D 00 00 07 關掉 LED2（0x0D），紅光熄滅 = 裝反。'
                '暫存器（含 PART_ID / REV_ID）讀不出這件事。',
                'Check for swapped LEDs: send 40 71 31 09 01 0D 00 00 07 to turn off LED2 (0x0D); '
                'if the red light goes out, the module is swapped. No register (incl. PART_ID / REV_ID) reveals this.'),
            style: TextStyle(fontSize: 13, color: Colors.deepOrange.shade800),
          ),
        ],
      ),
    );
  }
}
