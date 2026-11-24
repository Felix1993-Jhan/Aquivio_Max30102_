// ============================================================================
// K2EngineFixed30 —— 固定 30 秒模式(預設;`--calc fixed30`)
// ============================================================================
// 持有 [Max30102K2Fixed30]:倒數 30 秒期間只算線、交波形,30 秒到才一次算出結果。
//
// 與即時模式的差別(對外):
//   · WS 由**計時器每秒推一次**(倒數期間沒有計算,不能搭計算的便車);
//     結果算出來的那一刻另外立刻推一次。
//   · 新欄位 `phase` / `remainingSec` / `abortReason`(見 [vitalsJson])。
//   · 結果出來之前 `bpm` / `spo2` / `hrv` / `strapi` 一律 null,`sqiOk` 為 false。
//   · 結果保留到 init 成功(或下一次倒數開始);手指離開、reset 關燈都不清。
//   · `bpm` = HRV 平均心率(與 `mean_hr` 同一個值)。
// ============================================================================

part of 'max30102_server.dart';

class K2EngineFixed30 extends VitalsEngine {
  /// [clockMs]:倒數用的時鐘,只給測試注入假時鐘;正式執行不帶 = 核心預設的 Stopwatch。
  K2EngineFixed30({super.waveSeconds, int Function()? clockMs})
      : core = Max30102K2Fixed30(clockMs: clockMs) {
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => pushVitals());
  }

  final Max30102K2Fixed30 core;

  late final Timer _ticker;

  /// 結果的 strapi 區塊只在結果改變時算一次(每秒推送不必重算頻譜)。
  K2Fixed30Result? _strapiFor;
  Map<String, dynamic>? _strapiCache;

  @override
  String get calcMode => 'fixed30';

  @override
  int get totalSamples => core.totalSamples;

  @override
  Max30102Config get config => core.config;

  @override
  bool feedPacket(List<int> packet) {
    if (chipAsleep) return false;
    final r = core.feedData(packet);
    _absorbWave(r);
    if (r.computed != null) {
      pushVitals(); // 結果一出來立刻推,不等下一次計時
      return true;
    }
    return false;
  }

  /// 全部清除(切換進料來源、init 成功)。
  @override
  void reset() {
    core.reset();
    _clearWave();
  }

  /// init 成功 → 清結果、清中止狀態,開始新的量測。
  /// 只有 reset(關燈)→ 丟掉進行中的量測,**結果保留**給軟體讀。
  @override
  void afterChipCommand({required bool initialized}) {
    if (initialized) {
      reset();
    } else {
      core.dropMeasurement();
      _clearWave();
    }
  }

  /// `/vitals` 與 `/stream` 共用。原有欄位全部保留、型別不變,另加:
  ///   · `calcMode`     —— 'fixed30'
  ///   · `phase`        —— waiting / measuring / done / aborted
  ///   · `remainingSec` —— 倒數剩餘秒數(只有 measuring 時有值)
  ///   · `abortReason`  —— 'fingerRemoved'(只有 aborted 時有值)
  @override
  Map<String, dynamic> vitalsJson() {
    final res = core.result;
    final c = res?.compute;
    return {
      'calcMode': calcMode,
      'phase': core.phase.name,
      'remainingSec': core.remainingSec,
      'abortReason': core.abortReason?.name,
      // 關燈期間沒有光可以偵測手指 → 固定 false(v0.0.0.9 的修正,沿用)
      'fingerPresent': !chipAsleep && core.fingerPresent,
      'sqiOk': c?.sqiOk ?? false,
      'settling': !chipAsleep && core.settling,
      'channelOrient': core.channelOrient.name,
      'bpm': c?.bpm,
      'spo2': c?.spo2,
      'hrv': VitalsEngine._hrvJson(c?.hrv),
      'totalSamples': core.totalSamples,
      'strapi': res == null ? null : _strapi(res),
    };
  }

  /// 整合方介面形狀的區塊。與 `hrv` 同源(同一份 HrvStats)。
  /// 傳入計算窗的起訖 → `cleanShare` 連頭尾沒拍的那兩段也算(固定模式才這樣算)。
  Map<String, dynamic> _strapi(K2Fixed30Result res) {
    if (!identical(res, _strapiFor)) {
      final c = res.compute;
      _strapiCache = Max30102VitalsMetrics.compute(
        pts: c.rrPoints,
        hv: c.hrv,
        sqiOk: c.sqiOk,
        settling: false,
        bpm: c.bpm,
        ir: res.windowIr,
        spanStart: res.windowStartAbs,
        spanEnd: res.windowEndAbs,
      ).toStrapiJson();
      _strapiFor = res;
    }
    return _strapiCache!;
  }

  @override
  Future<void> dispose() async {
    _ticker.cancel();
    await super.dispose();
  }
}
