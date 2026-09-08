// ============================================================================
// K2 快照(UI 層,不屬於交接內容)
// ============================================================================
// ★ 這一層純粹是我們驗證用的:把「當下畫面上看得到的東西」存成一個 JSON 檔,
//   之後可以肉眼看、或餵回核心重放對拍。
//
// 分層界線:核心 Max30102K2 只算、不存 —— 快照是「呈現 / 驗證需求」,做在 UI。
//   核心早就吐出畫快照需要的一切(newIr/newRed、troughAbs、rrPoints、latest),
//   這裡只是把它們組起來寫檔。**核心一個字都不用改。**
//
// 內容分兩塊:
//   ① 30 秒視窗(一定有)      — 核心保留上限就是 30 秒,對應畫面上的波形 + 短期 HRV
//   ② 長期累積(超過 30 秒才有)— UI 自存的 allPoints;若沒超過 30 秒就留白(null)
//
// 檔案格式與舊版 max30102 快照相容(ir/red/goldTroughs/fs 同名),所以
// test/k2_replay_verify_test 也讀得到、能重放。
// ============================================================================

import 'dart:convert';
import 'dart:io';

import '../k2_hrv_calculator.dart';

/// 解析後的 K2 快照(給檢視器重畫)。
class K2Snapshot {
  final String path;
  final int tsMillis;
  final int fs;
  final int windowSeconds;

  // 核心視窗那一段(免洗版沒有長期累積,快照就只有這一段)
  final List<int> ir;
  final List<int> red;
  final List<int> goldTroughs; // 視窗內索引
  final List<HrvRrPoint> rrPoints; // 30 秒視窗的 RR(帶起訖谷)
  final double? bpm;
  final double? spo2;
  final bool fingerPresent;

  /// 存檔當下的訊號品質閘門與沉澱狀態。
  ///
  /// **舊快照沒有這兩個欄位 → null。** 它們是 `confidence` / `sqi` 的必要輸入,
  /// 所以舊檔開起來那兩格會是「—」而不是猜一個值。缺資訊就誠實留白,
  /// 不要拿 false 當預設 —— 那會讓舊快照看起來像品質不良。
  final bool? sqiOk;
  final bool? settling;

  /// 存檔當下判定出來的**通道方向**(`'normal'` / `'swapped'` / `'unknown'`)。
  ///
  /// **舊快照沒有這個欄位 → null。**
  ///
  /// 為什麼值得存:`'swapped'` 代表當時那片模組把兩顆 LED 晶粒裝反了 ——
  /// 那是**仿製品的指紋**(原廠封裝不會出這種錯,而且 PART_ID / REV_ID 都偽造得
  /// 一模一樣,讀暫存器分不出來)。存進快照之後,幾個月後回頭看歷史資料,
  /// 還答得出「這筆是用原廠 IC 還是外面代工的板子量的」。
  ///
  /// 存字串而不是 enum:快照要能被不懂 Dart 的人直接開起來看,
  /// 而且將來 enum 增減不會讓舊檔解析失敗。
  final String? channelOrient;

  const K2Snapshot({
    required this.path,
    required this.tsMillis,
    required this.fs,
    required this.windowSeconds,
    required this.ir,
    required this.red,
    required this.goldTroughs,
    required this.rrPoints,
    required this.bpm,
    required this.spo2,
    required this.fingerPresent,
    this.sqiOk,
    this.settling,
    this.channelOrient,
  });

  DateTime get time => DateTime.fromMillisecondsSinceEpoch(tsMillis);

  static List<HrvRrPoint> _points(List rr, List sa, List ea) {
    final n = [rr.length, sa.length, ea.length].reduce((a, b) => a < b ? a : b);
    return [
      for (int i = 0; i < n; i++)
        (
          rr: (rr[i] as num).toDouble(),
          startAbs: (sa[i] as num).toInt(),
          endAbs: (ea[i] as num).toInt(),
        ),
    ];
  }

  factory K2Snapshot.fromJson(String path, Map<String, dynamic> j) {
    List<int> ints(String k) =>
        ((j[k] as List?) ?? const []).map((e) => (e as num).toInt()).toList();
    // ⚠️ 舊版快照檔裡可能還有 'longTerm' 欄位 —— 免洗版直接忽略,不會讀取失敗。
    //    舊檔的波形與短期 HRV 照樣開得起來,只是不再顯示長期那一段。
    return K2Snapshot(
      path: path,
      tsMillis: (j['tsMillis'] as num?)?.toInt() ?? 0,
      fs: (j['fs'] as num?)?.toInt() ?? 100,
      windowSeconds: (j['windowSeconds'] as num?)?.toInt() ?? 30,
      ir: ints('ir'),
      red: ints('red'),
      goldTroughs: ints('goldTroughs'),
      rrPoints: _points(
        (j['rr'] as List?) ?? const [],
        (j['rrStartAbs'] as List?) ?? const [],
        (j['rrEndAbs'] as List?) ?? const [],
      ),
      bpm: (j['bpm'] as num?)?.toDouble(),
      spo2: (j['spo2'] as num?)?.toDouble(),
      fingerPresent: j['fingerPresent'] == true,
      // 舊檔沒有這兩個 key → 保持 null(不要用 `== true`,那會把「沒有」
      // 變成 false,舊快照就會全部顯示成品質不良)
      sqiOk: j['sqiOk'] as bool?,
      settling: j['settling'] as bool?,
      channelOrient: j['channelOrient'] as String?,
    );
  }
}

/// 存 K2 快照 → 桌面 `max30102_snapshots` 資料夾(與舊版共用同一夾)。
class K2SnapshotStore {
  static const String folderName = 'max30102_snapshots';
  static const int maxFiles = 50;

  /// 桌面資料夾路徑(Windows 用 USERPROFILE,其他用 HOME);取不到回 null。
  static String? _desktopDirPath() {
    final home = Platform.isWindows
        ? Platform.environment['USERPROFILE']
        : Platform.environment['HOME'];
    if (home == null || home.isEmpty) return null;
    final sep = Platform.pathSeparator;
    return '$home${sep}Desktop$sep$folderName';
  }

  /// 存一筆快照 → k2snap_<年月日_時分秒>_<ts>.json;修剪超量舊檔。
  /// 回傳存檔路徑(失敗回 null)。
  static Future<String?> save(Map<String, dynamic> snapJson, int tsMillis) async {
    try {
      final p = _desktopDirPath();
      if (p == null) return null;
      final d = Directory(p);
      if (!await d.exists()) await d.create(recursive: true);

      final t = DateTime.fromMillisecondsSinceEpoch(tsMillis);
      String two(int v) => v.toString().padLeft(2, '0');
      final stamp = '${t.year}-${two(t.month)}-${two(t.day)}_'
          '${two(t.hour)}${two(t.minute)}${two(t.second)}';
      final sep = Platform.pathSeparator;
      final path = '${d.path}${sep}k2snap_${stamp}_$tsMillis.json';
      await File(path).writeAsString(jsonEncode(snapJson));
      await _prune(d);
      return path;
    } catch (_) {
      return null;
    }
  }

  /// 掃描桌面資料夾,讀回全部 K2 快照(新→舊)。壞檔跳過。
  static Future<List<K2Snapshot>> loadAll() async {
    try {
      final p = _desktopDirPath();
      if (p == null) return const [];
      final d = Directory(p);
      if (!await d.exists()) return const [];
      final files = (await d.list().toList())
          .whereType<File>()
          .where((f) => f.path.split(Platform.pathSeparator).last
              .startsWith('k2snap_'))
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path)); // 新→舊
      final out = <K2Snapshot>[];
      for (final f in files) {
        try {
          final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
          out.add(K2Snapshot.fromJson(f.path, j));
        } catch (_) {}
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// 刪一個快照檔。
  static Future<void> delete(String path) async {
    try {
      await File(path).delete();
    } catch (_) {}
  }

  /// 只保留最新 [maxFiles] 個 k2snap_*.json,其餘刪除。
  static Future<void> _prune(Directory d) async {
    try {
      final files = (await d.list().toList())
          .whereType<File>()
          .where((f) => f.path.split(Platform.pathSeparator).last
              .startsWith('k2snap_'))
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path)); // 新→舊
      for (int i = maxFiles; i < files.length; i++) {
        try {
          await files[i].delete();
        } catch (_) {}
      }
    } catch (_) {}
  }
}
