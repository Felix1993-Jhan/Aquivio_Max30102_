// ============================================================================
// K2Engine —— 即時模式(`--calc realtime`)
// ============================================================================
// 持有即時版核心 [Max30102K2]:每秒算一次,每算出一份新結果就推給 WS。
// (0.0.1-fixed30s 從 max30102_server.dart 原封搬出;波形累積移到 engine_base.dart。
//  行為不變,只多了 `calcMode` 欄位。)
// ============================================================================

part of 'max30102_server.dart';

/// 包住 [Max30102K2]:餵資料進來、算出結果、順便替上層累積一段波形。
///
/// 核心本身**不囤長歷史**(只留 config.dataHistoryMs),要畫圖得由外面自己存 ——
/// 這裡就是那個「外面」,把每次 feedData 回傳的 newIr/newRed 接起來。
class K2Engine extends VitalsEngine {
  K2Engine({super.waveSeconds, bool resetOnFingerOff = true})
      // 免洗式量測(一人一次):確認手指離開時核心連絕對索引一起歸零,
      // 下一位使用者完全從零開始。核心預設是 false,這裡明確打開。
      : k2 = Max30102K2(
          config: Max30102Config(resetOnFingerOff: resetOnFingerOff),
        );

  final Max30102K2 k2;

  @override
  String get calcMode => 'realtime';

  @override
  int get totalSamples => k2.totalSamples;

  @override
  Max30102Config get config => k2.config;

  /// 餵一個 MCU 原始封包(含表頭與 CS)。回傳這次有沒有算出新結果。
  ///
  /// 封包壞掉 / 不是資料回應 → 核心回 empty,這裡就什麼都不做。
  /// 晶片休眠中([chipAsleep])→ 整包丟棄。
  @override
  bool feedPacket(List<int> packet) {
    if (chipAsleep) return false;
    final r = k2.feedData(packet);
    _absorbWave(r);

    if (r.computed != null) {
      if (!_vitals.isClosed) _vitals.add(vitalsJson());
      return true;
    }
    return false;
  }

  @override
  void reset() {
    k2.reset();
    _clearWave();
  }

  /// 晶片狀態變了 → 之前累積的波形與拍全部作廢(init / reset 都一樣)。
  @override
  void afterChipCommand({required bool initialized}) => reset();

  /// 最新一次計算結果。沒手指 / 沉澱中時對應欄位為 null,照核心現況輸出。
  ///
  /// ⚠️ **`/vitals` 與 `/stream` 吐的是同一個函式的輸出** —— WS 一接上先推
  ///    一份現況,之後每算完一次推一份。所以改這裡兩個端點會自動同步,
  ///    不會有一邊漏改。
  ///
  ///    **唯一的例外是 `wave`**(v0.0.0.5 起):`/stream` 會在這份輸出之外再蓋
  ///    一個 `wave` 區塊,`/vitals` 沒有。理由是 `wave` 給的是**增量**(自這個
  ///    訂閱者上次收到之後的新樣本),那需要「上次收到哪裡」這個**每連線一份**
  ///    的狀態 —— HTTP 輪詢沒有連線可依附,問十次就會拿到十份不相接的碎片。
  ///    要用 HTTP 拿波形請走 `GET /waveform`,那邊是「近 N 秒」的絕對切片。
  ///
  /// 回應分兩區:
  ///   · 頂層 + `hrv` —— **我們自己的欄位**,名稱與型別照核心的語意。
  ///   · `strapi` —— **整合方介面的形狀**(aquivio-station 的 `VitalsResult`),
  ///     欄位名與型別完全照他們的宣告,可以直接 `const v: VitalsResult = json.strapi`
  ///     零映射取用。
  ///
  /// 為什麼不直接把頂層欄位改名成他們的:**有些根本不是同一個量**。
  ///   · `sqiOk`(布林閘門) vs `sqi`(number 1/0)—— 型別不同
  ///   · `bpm`(最近 6 拍**中位**) vs `mean_hr`(全窗**平均**)—— 同一次量測
  ///     會差 1~3 bpm,改名等於送錯值
  /// 所以兩區並存,重複幾個 byte 不是問題。
  @override
  Map<String, dynamic> vitalsJson() {
    final c = k2.latest;
    return {
      'calcMode': calcMode,
      'fingerPresent': c?.fingerPresent ?? false,
      'sqiOk': c?.sqiOk ?? false,
      'settling': c?.settling ?? false,
      // 通道方向的判定結果(v0.0.0.6 起)。'unknown' = 還在判,此時波形與血氧
      // 都還不會出來(心率照給)。'swapped' = 手上這片模組把兩顆 LED 裝反了,
      // **輸出已經由核心轉正**,這個欄位只是讓上層知道、可以記錄或警示。
      'channelOrient': (c?.orient ?? K2ChannelOrient.unknown).name,
      'bpm': c?.bpm,
      'spo2': c?.spo2,
      'hrv': VitalsEngine._hrvJson(c?.hrv),
      'totalSamples': k2.totalSamples,
      'strapi': strapiJson(),
    };
  }

  /// 整合方介面(`VitalsResult`)形狀的區塊。
  ///
  /// ⚠️ **與 `hrv` 區塊必須同源。** 兩區的 `sdnn` / `rmssd` / `mean_hr` 是同一份
  ///    `HrvStats` 導出的,不可以各算各的 —— 各算一次就會有一天只改到一邊。
  ///    這裡直接把 `c.hrv` 傳進 [Max30102VitalsMetrics.compute]。
  Map<String, dynamic> strapiJson() {
    final c = k2.latest;
    final m = Max30102VitalsMetrics.compute(
      pts: c?.rrPoints ?? const [],
      hv: c?.hrv,
      sqiOk: c?.sqiOk ?? false,
      settling: c?.settling ?? false,
      bpm: c?.bpm,
      ir: _waveIr,
    );
    // 欄位、單位與可信度資訊全部由 toStrapiJson() 決定 —— server 不再自己
    // 補欄位。之前這裡加過 lf / hf / lf_reliable 等等,結果與核心那邊重複,
    // 兩處都要改才不會漂移。現在只有一個地方定義那份契約。
    return m.toStrapiJson();
  }
}
