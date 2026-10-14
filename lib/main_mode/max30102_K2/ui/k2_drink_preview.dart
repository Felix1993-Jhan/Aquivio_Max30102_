// ============================================================================
// 推薦飲品預覽 —— 離線推演，不連外
// ============================================================================
// ★ 這一層**不屬於交接內容**，和 ui/ 底下其他檔案一樣是我們自己驗證用的。
//
// 它回答一個問題：**這次量測的數字，送到飲品推薦那邊會變成什麼？**
//
// 範圍（刻意畫得很死）：
//   · 只讀 [Max30102VitalsMetrics.toStrapiJson] 已經算好的欄位
//   · **不碰核心、不碰串口、不碰 server、不發任何網路請求**
//   · 純函式 + 一個對話框，沒有狀態
//
// ── 對方那側是怎麼用這些數字的（實地讀過 aquivio-fastify 的程式）──────────
//
// `POST /k2/:token/recommend-vitals` 把 8 個欄位逐字塞進提示詞，交給 LLM
// 從固定的飲品清單裡挑 1~4 款。伺服器端**只驗兩件事**：
//   ① `vitals` 是不是一個物件（連有哪些欄位都不檢查）
//   ② 回傳的 slug 存不存在於這台機器（純硬體可行性）
//
// ⚠️ **`confidence` 被送過去，但從頭到尾沒有任何一行程式拿它做判斷。**
//    它只是被印進提示詞的一行文字，而提示詞的判讀規則裡完全沒提到它。
//    也就是說：**可信度再低，照樣會得到一杯看起來很有道理的推薦。**
//
// ── 這份預覽的誠實邊界 ────────────────────────────────────────────────
//
// 「送出的欄位」那一段是**精確的**（照他們的模板逐字排版）。
//
// 「命中哪條規則」「偏好／排除哪些飲品」是**我們本地推演的近似值**，因為
// 他們的提示詞裡**只有 `LF/HF > 1.5` 一個硬數字**，其餘「高 stress」
// 「低 PNS」「低 HRV」「心率偏高」全是給 LLM 自由心證的形容詞。
// 下面 [K2DrinkThresholds] 的門檻**是我們訂的，不是對方的**，畫面上也會標明。
// ============================================================================

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../../shared/services/localization_service.dart';

/// 本地推演用的門檻。**這些數字是我們訂的，不是對方的。**
///
/// 對方的提示詞裡唯一寫死的只有 [sympatheticLfHf]（`LF/HF > 1.5`），
/// 那一個是照抄的；其餘都是我們為了讓預覽有東西可顯示而選的常見休息值。
/// 改這裡只影響這個預覽畫面，不影響任何實際送出的資料。
class K2DrinkThresholds {
  /// ★ 唯一照抄對方的數字：提示詞裡寫死的 `LF/HF > 1.5` = 交感主導。
  static const double sympatheticLfHf = 1.5;

  /// 以下皆為**我們自訂**的近似門檻。
  static const double highStress = 60;
  static const double lowPns = 40;
  static const double highPns = 60;
  static const double lowRmssd = 20; // 成人休息典型 20~50ms
  static const double highRmssd = 50;
  static const double elevatedHr = 100; // 成人休息上緣

  /// 灌流指數下限：低於這個值就不像是手指。
  /// 實測木頭桌面 0.149%、真手指 10.1%，差兩個量級，所以門檻怎麼挑都行。
  static const double minPerfusionPct = 0.3;

  /// 生理上可能的心率範圍，超出就不是人。
  static const double hrMinPlausible = 30;
  static const double hrMaxPlausible = 220;
}

/// 推演出來的主導訊號。順序照對方提示詞裡那四條規則。
enum K2DrinkRule {
  /// 心率偏高 —— 對方寫明「regardless of the other signals」，是否決權。
  elevatedHr,

  /// 交感主導／壓力：LF/HF > 1.5、高 stress、低 PNS、低 HRV。
  sympathetic,

  /// 副交感／恢復良好：高 PNS、高 HRV、低 stress。
  parasympathetic,

  /// 中性／混合，沒有主導訊號。
  neutral,
}

/// 一款飲品在對方知識庫裡的定位（`infusion-knowledge.ts` 的摘要）。
class K2Infusion {
  const K2Infusion({
    required this.slug,
    required this.zh,
    required this.category,
    required this.bestForZh,
    required this.bestForRules,
    this.avoidWhenZh,
    this.avoidRules = const [],
  });

  /// 對方知識庫裡的鍵值，**一個字母都不能改**（含大小寫）——
  /// 它是兩邊對帳的唯一識別碼，改了就對不回去。
  final String slug;

  /// 中文名，只為了讓人看得懂，不參與任何比對。
  final String zh;

  /// 對方知識庫裡的分類，**原文照搬不翻譯** —— 它是用來對帳的技術名詞，
  /// 翻譯之後就對不回他們的 `infusion-knowledge.ts` 了。
  final String category;

  /// 為什麼入圍：對方 `bestFor` 的中文濃縮。
  final String bestForZh;

  /// 為什麼被排除：對方 `avoidWhen` 的中文濃縮。null = **對方根本沒寫這欄**。
  final String? avoidWhenZh;

  /// 這款飲品適合哪些主導訊號。
  final List<K2DrinkRule> bestForRules;

  /// 哪些主導訊號下要避開它。
  final List<K2DrinkRule> avoidRules;
}

/// 對方 `infusion-knowledge.ts` 裡的 11 款，照它的 `bestFor` / `avoidWhen` 歸類。
///
/// ⚠️ 這是**快照**，不是即時讀取 —— 對方改了知識庫這裡不會自動跟著動。
///    畫面上有標明，而且它只用來解釋傾向，不會真的決定任何事。
const List<K2Infusion> kK2Infusions = [
  // ⚠️ electrolytes 的依據**有兩條來源而且不一致**：它自己的 bestFor 只講
  //    「心率偏高、脫水/運動後」，但提示詞的交感規則又寫「Favor
  //    hydration/mineral…」把它包進去。所以它實際上幾乎永遠是候選。
  K2Infusion(
    slug: 'electrolytes',
    zh: '電解質',
    category: 'hydration & minerals',
    bestForZh: '心率偏高、有脫水或運動後的跡象 —— 補水優先的選擇',
    bestForRules: [K2DrinkRule.elevatedHr, K2DrinkRule.sympathetic],
  ),
  // ⚠️ 駝峰,不是 multivitamins —— 對方的鍵值就是這樣寫的。
  K2Infusion(
    slug: 'multiVitamins',
    zh: '綜合維生素',
    category: 'micronutrient support',
    bestForZh: '中性或耗損、沒有單一主導訊號時的一般支持',
    avoidWhenZh: '有明確的強訊號（高壓力、恢復良好、心率偏高）時，該用更針對性的',
    bestForRules: [K2DrinkRule.neutral],
    avoidRules: [K2DrinkRule.sympathetic, K2DrinkRule.parasympathetic],
  ),
  K2Infusion(
    slug: 'caffeine',
    zh: '咖啡因',
    category: 'stimulant / energy',
    bestForZh: '恢復良好、副交感的讀數：高 PNS、高 HRV、低 stress —— 身體承受得起刺激',
    avoidWhenZh: '高 stress、低 PNS、交感主導（LF/HF > 1.5）或心率偏高 —— '
        '預防性迴避，不要在已經活化的狀態上再加喚起',
    bestForRules: [K2DrinkRule.parasympathetic],
    avoidRules: [K2DrinkRule.sympathetic, K2DrinkRule.elevatedHr],
  ),
  K2Infusion(
    slug: 'cascara',
    zh: '咖啡果皮',
    category: 'gentle botanical lift',
    bestForZh: '中度恢復、想要軟性提振而不是強刺激',
    avoidWhenZh: '高 stress、低 PNS 或心率偏高',
    bestForRules: [K2DrinkRule.parasympathetic],
    avoidRules: [K2DrinkRule.sympathetic, K2DrinkRule.elevatedHr],
  ),
  K2Infusion(
    slug: 'collagen',
    zh: '膠原蛋白',
    category: 'recovery & connective support',
    bestForZh: '恢復導向或活動後的讀數 —— 運動後與恢復良好的狀態',
    bestForRules: [K2DrinkRule.parasympathetic],
  ),
  K2Infusion(
    slug: 'lutein',
    zh: '葉黃素',
    category: 'antioxidant / eye support',
    bestForZh: '高壓力或交感主導的讀數，依據是抗氧化／氧化負荷的論點'
        '（**不是**直接宣稱能改善 HRV）',
    bestForRules: [K2DrinkRule.sympathetic],
  ),
  K2Infusion(
    slug: 'bcaa',
    zh: '支鏈胺基酸',
    category: 'amino-acid recovery',
    bestForZh: '恢復良好、偏活動的讀數（PNS/HRV 佳），或運動後恢復',
    avoidWhenZh: '高壓力且低恢復 —— 那時候鎮靜支持比表現支持合適',
    bestForRules: [K2DrinkRule.parasympathetic],
    avoidRules: [K2DrinkRule.sympathetic],
  ),
  K2Infusion(
    slug: 'whey',
    zh: '乳清蛋白',
    category: 'protein & satiety',
    bestForZh: '已恢復、表現或營養導向的讀數',
    avoidWhenZh: '急性壓力、低恢復 —— 那時候該先給鎮靜補水',
    bestForRules: [K2DrinkRule.parasympathetic],
    avoidRules: [K2DrinkRule.sympathetic],
  ),
  K2Infusion(
    slug: 'creatine',
    zh: '肌酸',
    category: 'strength, power & cognitive resilience',
    // 唯一在知識庫**自己的文字裡**就寫明兩端都適合的。
    bestForZh: '強恢復、準備好表現的讀數 —— 而且**獨特地**也適用於'
        '壓力／睡眠不足的讀數（認知韌性的論點）',
    bestForRules: [K2DrinkRule.parasympathetic, K2DrinkRule.sympathetic],
  ),
  K2Infusion(
    slug: 'fiber',
    zh: '膳食纖維',
    category: 'digestive & gut–heart support',
    bestForZh: '中性／一般健康的讀數，也可當高壓力讀數的溫和腸－迷走支持',
    bestForRules: [K2DrinkRule.neutral, K2DrinkRule.sympathetic],
  ),
  // ⚠️ 是 lCarnitine(左旋肉鹼),不是 metabolic —— metabolic 是它的分類名。
  K2Infusion(
    slug: 'lCarnitine',
    zh: '左旋肉鹼',
    category: 'metabolic / fat-to-energy',
    bestForZh: '恢復良好、偏活動、以健身為目標的讀數',
    avoidWhenZh: '高壓力或低恢復',
    bestForRules: [K2DrinkRule.parasympathetic],
    avoidRules: [K2DrinkRule.sympathetic],
  ),
];

/// 一條資料可信度的警示。
class K2TrustIssue {
  const K2TrustIssue(this.titleKey, this.detail);

  /// 翻譯 key。
  final String titleKey;

  /// 實際數值（已經格式化好，不翻譯）。
  final String detail;
}

/// 推演結果。純資料，沒有 Flutter 相依，可以直接寫測試。
class K2DrinkPreview {
  K2DrinkPreview({
    required this.lines,
    required this.rule,
    required this.favored,
    required this.avoided,
    required this.trustIssues,
  });

  /// 會送出去的欄位，**逐字照對方提示詞的格式**。這一段是精確的。
  final List<String> lines;

  /// 推演出來的主導訊號。
  final K2DrinkRule rule;

  /// 會被偏好的飲品 slug。
  final List<String> favored;

  /// 會被排除的飲品 slug。
  ///
  /// ⚠️ **11 款裡有 5 款永遠不會出現在這裡**（`electrolytes` / `collagen` /
  ///    `lutein` / `creatine` / `fiber`）—— 它們在對方知識庫裡根本沒有
  ///    `avoidWhen` 欄位。所以「不在排除清單」不等於「被評估過且通過」。
  final List<String> avoided;

  /// 資料可不可信的警示。空的代表沒看出問題。
  final List<K2TrustIssue> trustIssues;

  /// 從 `toStrapiJson()` 的欄位推演。
  ///
  /// [perfusionPct] 是灌流指數 AC/DC（百分比），由呼叫端從波形算。
  /// [sd1] / [sd2] 來自 HRV，用來抓「SD1 > SD2」這個白雜訊特徵。
  ///
  /// [stocked] 給了就只留機器真的有的那幾款（模擬現場的實際庫存）；
  /// 給 null 就是把 11 款全部當成有貨。
  ///
  /// ⚠️ 過濾只影響**顯示**。真實情況是對方的 `loadMachineInfusions()` 在
  ///    組提示詞之前就先把這台機器的清單撈出來，所以 **LLM 根本看不到
  ///    沒進貨的那幾款** —— 不是挑完再刪掉。這個差別很重要：
  ///    少一款不是「少一個選項」，而是整個推薦會改挑別的組合。
  factory K2DrinkPreview.from(
    Map<String, dynamic> vitals, {
    double? perfusionPct,
    double? sd1,
    double? sd2,
    Set<String>? stocked,
  }) {
    double? num_(String k) {
      final v = vitals[k];
      return v is num && v.isFinite ? v.toDouble() : null;
    }

    final meanHr = num_('mean_hr');
    final sdnn = num_('sdnn');
    final rmssd = num_('rmssd');
    final lfHf = num_('lf_hf');
    final ans = num_('ans');
    final pns = num_('pns');
    final stress = num_('stress');
    final conf = vitals['confidence'];

    // ── ① 會送出去的欄位:**照對方模板逐字排版** ─────────────────────
    String f(double? v, [String unit = '']) =>
        v == null ? 'n/a' : '${_trim(v)}$unit';
    final lines = <String>[
      '- HRV SDNN: ${f(sdnn, ' ms')}, RMSSD: ${f(rmssd, ' ms')}',
      '- ANS balance (LF/HF ${f(lfHf)}); ANS score ${f(ans)}/100',
      '- PNS / recovery: ${f(pns)}/100',
      '- Stress: ${f(stress)}/100',
      '- Heart rate: ${f(meanHr, ' bpm')}',
      '- Reading confidence: ${conf is String && conf.isNotEmpty ? conf : 'n/a'}',
    ];

    // ── ② 主導訊號 ───────────────────────────────────────────────────
    //
    // 順序照對方的提示詞:心率偏高是**否決權**(寫明 regardless of the
    // other signals),所以先判它;其餘用「哪一端的訊號多」決定。
    K2DrinkRule rule;
    if (meanHr != null && meanHr > K2DrinkThresholds.elevatedHr) {
      rule = K2DrinkRule.elevatedHr;
    } else {
      var sym = 0;
      var para = 0;
      if (lfHf != null && lfHf > K2DrinkThresholds.sympatheticLfHf) sym++;
      if (stress != null && stress > K2DrinkThresholds.highStress) sym++;
      if (pns != null && pns < K2DrinkThresholds.lowPns) sym++;
      if (rmssd != null && rmssd < K2DrinkThresholds.lowRmssd) sym++;
      if (pns != null && pns > K2DrinkThresholds.highPns) para++;
      if (rmssd != null && rmssd > K2DrinkThresholds.highRmssd) para++;
      if (stress != null && stress < K2DrinkThresholds.highStress) para++;
      if (sym > para) {
        rule = K2DrinkRule.sympathetic;
      } else if (para > sym) {
        rule = K2DrinkRule.parasympathetic;
      } else {
        rule = K2DrinkRule.neutral;
      }
    }

    // ── ③ 依規則分出偏好 / 排除 ──────────────────────────────────────
    bool inStock(K2Infusion i) => stocked == null || stocked.contains(i.slug);
    final favored = [
      for (final i in kK2Infusions)
        if (i.bestForRules.contains(rule) && inStock(i)) i.slug
    ];
    final avoided = [
      for (final i in kK2Infusions)
        if (i.avoidRules.contains(rule) && inStock(i)) i.slug
    ];

    // ── ④ 這筆資料到底可不可信 ───────────────────────────────────────
    //
    // 這一段才是這個畫面真正的價值 —— 對方**完全不做**這種檢查,
    // 送什麼他們就信什麼。
    final issues = <K2TrustIssue>[];
    if (perfusionPct != null &&
        perfusionPct < K2DrinkThresholds.minPerfusionPct) {
      issues.add(K2TrustIssue(
          'k2_drink_trust_pi',
          '${perfusionPct.toStringAsFixed(3)}%'
              ' < ${K2DrinkThresholds.minPerfusionPct}%'));
    }
    // ⚠️ SD1 > SD2 **刻意不列成一條說明**。
    //    SD1/SD2 不在送出去的 8 個欄位裡,對方看不到也不會用,
    //    在這個「對方會怎麼判讀」的畫面上講它只會造成混淆。
    //    但它仍然是判斷「這段 RR 是不是白雜訊」最有力的依據
    //    （逐拍變異大於整體變異,生理上幾乎不可能）,
    //    所以留著當下面方向性警告的觸發條件之一,只是不寫出來。
    final looksLikeNoise = sd1 != null && sd2 != null && sd1 > sd2;
    if (meanHr != null &&
        (meanHr < K2DrinkThresholds.hrMinPlausible ||
            meanHr > K2DrinkThresholds.hrMaxPlausible)) {
      issues.add(K2TrustIssue(
          'k2_drink_trust_hr',
          '${_trim(meanHr)} bpm'
              '（${_trim(K2DrinkThresholds.hrMinPlausible)}'
              '~${_trim(K2DrinkThresholds.hrMaxPlausible)}）'));
    }
    // 雜訊會把 HRV 推高 → 落在「恢復良好」端 → 推刺激類。
    // 這個方向性是這整件事最危險的地方,所以單獨標出來。
    if (rule == K2DrinkRule.parasympathetic &&
        (issues.isNotEmpty || looksLikeNoise)) {
      issues.add(const K2TrustIssue('k2_drink_trust_direction', ''));
    }

    return K2DrinkPreview(
      lines: lines,
      rule: rule,
      favored: favored,
      avoided: avoided,
      trustIssues: issues,
    );
  }

  static String _trim(double v) {
    final s = v.toStringAsFixed(1);
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }
}

/// 玻璃質感開關。`true` = 方案 B（玻璃外框 + 資料區維持實心），
/// `false` = 原本的 Material `AlertDialog`。
///
/// 做成常數而**不是把舊版註解掉**：兩條路都保持可編譯，想比較就翻這個 bool。
/// 註解掉的程式碼會隨著其他地方的改動默默爛掉，常數不會。
///
/// 關掉的時機：如果發現滾動模式下開著這個視窗會讓波形圖掉幀。
/// `BackdropFilter` 會強制一個 save layer 並且每一幀重算模糊，它不是免費的。
const bool _glass = true;

/// 規則 → 翻譯 key。
String k2DrinkRuleKey(K2DrinkRule r) => switch (r) {
      K2DrinkRule.elevatedHr => 'k2_drink_rule_hr',
      K2DrinkRule.sympathetic => 'k2_drink_rule_sym',
      K2DrinkRule.parasympathetic => 'k2_drink_rule_para',
      K2DrinkRule.neutral => 'k2_drink_rule_neutral',
    };

/// 彈出預覽對話框。
///
/// [listenable] 變動時重算一次 [compute]，所以**兩種模式自動分流、不用判斷**：
///   · 定長 —— `fixedWindow.view()` 有 memo，重算回同一份 ⇒ 畫面凍結
///   · 滾動 —— 每秒重算 ⇒ 持續更新
///
/// 看著它在滾動模式下更新，會直接看出**推薦有多不穩定** —— 同一個人同一次
/// 量測，截在不同秒數可能換一杯。那件事靜態截圖看不出來。
///
/// [compute] 回 null（例如手指離開、一拍都不剩）時**保留上一份**，
/// 不要把畫面清空 —— 內容突然消失比停在舊值更難理解。
/// [applyStock] 是「只看機器實際有的」那個開關。對話框裡也放一份，
/// 可以開著視窗直接比對「全部有貨」和「現場庫存」兩種結果。
/// 它和主畫面共用同一個 notifier，所以兩邊永遠一致。
Future<void> showK2DrinkPreview(
  BuildContext context, {
  required Listenable listenable,
  required K2DrinkPreview? Function() compute,
  ValueNotifier<bool>? applyStock,
}) {
  return showDialog<void>(
    context: context,
    // 遮罩要調淡,否則背景被壓黑之後「模糊」就沒東西可模糊,玻璃感出不來。
    // 代價是背後的波形圖會透出來 —— 所以模糊給得重(sigma 22),
    // 讓它只剩色塊感、看不出形狀。
    barrierColor: _glass ? const Color.fromRGBO(0, 0, 0, 0.28) : null,
    builder: (ctx) => _K2DrinkLive(
      listenable: listenable,
      compute: compute,
      applyStock: applyStock,
    ),
  );
}

class _K2DrinkLive extends StatefulWidget {
  const _K2DrinkLive({
    required this.listenable,
    required this.compute,
    this.applyStock,
  });

  final Listenable listenable;
  final K2DrinkPreview? Function() compute;
  final ValueNotifier<bool>? applyStock;

  @override
  State<_K2DrinkLive> createState() => _K2DrinkLiveState();
}

class _K2DrinkLiveState extends State<_K2DrinkLive> {
  K2DrinkPreview? _last;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.listenable,
      builder: (context, _) {
        _last = widget.compute() ?? _last;
        final p = _last;
        if (p == null) return const SizedBox.shrink();
        return _K2DrinkDialog(preview: p, applyStock: widget.applyStock);
      },
    );
  }
}

class _K2DrinkDialog extends StatelessWidget {
  const _K2DrinkDialog({required this.preview, this.applyStock});

  final K2DrinkPreview preview;
  final ValueNotifier<bool>? applyStock;

  // ── 玻璃用色 ────────────────────────────────────────────────────────
  //
  // 用 Color.fromRGBO 而不是 withOpacity / withValues：那兩個 API 在不同
  // Flutter 版本之間一個被棄用、一個還不存在，fromRGBO 從以前到現在都一樣。
  static const _shell = Color.fromRGBO(255, 255, 255, 0.72);
  static const _shellEdge = Color.fromRGBO(255, 255, 255, 0.65);
  static const _warnFill = Color.fromRGBO(255, 167, 38, 0.20);
  static const _warnEdge = Color.fromRGBO(239, 108, 0, 0.50);
  static const _ruleFill = Color.fromRGBO(0, 150, 136, 0.13);
  static const _ruleEdge = Color.fromRGBO(0, 150, 136, 0.38);

  @override
  Widget build(BuildContext context) =>
      _glass ? _glassDialog(context) : _materialDialog(context);

  /// 方案 B：玻璃只做在「框」上，資料區（第①塊）維持深色實心。
  ///
  /// 玻璃感的本質是**降低對比**，而第①塊正好是最需要對比的東西
  /// （那串等寬數字是拿來對帳的）。所以裝飾歸裝飾、資料歸資料。
  Widget _glassDialog(BuildContext context) {
    return Dialog(
      // 不設透明的話 Material 自己的白底會擋在前面，模糊完全看不到。
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
      child: ClipRRect(
        // ⚠️ 一定要裁切。沒有 ClipRRect 的話模糊會溢出到整個畫面。
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 620),
            decoration: BoxDecoration(
              color: _shell,
              border: Border.all(color: _shellEdge, width: 1.2),
              borderRadius: BorderRadius.circular(20),
            ),
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 14),
            child: _content(context),
          ),
        ),
      ),
    );
  }

  /// 原本的 Material 版本。留著是為了能一鍵比較，見 [_glass]。
  Widget _materialDialog(BuildContext context) => AlertDialog(
        title: _titleRow(),
        content: SizedBox(width: 560, child: _body(context)),
        actions: [_closeButton(context)],
      );

  Widget _content(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _titleRow(),
          const SizedBox(height: 14),
          Flexible(child: _body(context)),
          const SizedBox(height: 6),
          Align(alignment: Alignment.centerRight, child: _closeButton(context)),
        ],
      );

  Widget _titleRow() {
    final warn = preview.trustIssues.isNotEmpty;
    return Row(
      children: [
        Icon(warn ? Icons.warning_amber_rounded : Icons.local_cafe_outlined,
            color: warn ? Colors.orange.shade800 : Colors.teal.shade700),
        const SizedBox(width: 8),
        Expanded(
          child: Text(tr('k2_drink_title'),
              style: const TextStyle(
                  fontSize: 17, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }

  Widget _closeButton(BuildContext context) => TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(tr('k2_drink_close')),
      );

  Widget _body(BuildContext context) {
    final p = preview;
    final warn = p.trustIssues.isNotEmpty;
    return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── 可信度警示擺最上面:它比推薦結果重要 ──────────────────
              if (warn) ...[
                _box(
                  color: _glass ? _warnFill : Colors.orange.shade50,
                  border: _glass ? _warnEdge : Colors.orange.shade300,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(tr('k2_drink_trust_head'),
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.orange.shade900)),
                      const SizedBox(height: 6),
                      for (final i in p.trustIssues)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 3),
                          child: Text(
                            i.detail.isEmpty
                                ? '• ${tr(i.titleKey)}'
                                : '• ${tr(i.titleKey)}：${i.detail}',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
              ],

              _head(tr('k2_drink_sec_payload')),
              _box(
                color: const Color(0xFF1E1E1E),
                border: Colors.black26,
                child: SelectableText(
                  p.lines.join('\n'),
                  style: const TextStyle(
                      fontFamily: 'Consolas',
                      fontSize: 12,
                      height: 1.5,
                      color: Color(0xFFD4D4D4)),
                ),
              ),
              const SizedBox(height: 14),

              _head(tr('k2_drink_sec_rule')),
              _box(
                color: _glass ? _ruleFill : Colors.teal.shade50,
                border: _glass ? _ruleEdge : Colors.teal.shade200,
                child: Text(tr(k2DrinkRuleKey(p.rule)),
                    style: const TextStyle(fontSize: 13)),
              ),
              const SizedBox(height: 14),

              Row(
                children: [
                  Expanded(child: _head(tr('k2_drink_sec_picks'))),
                  // 只看機器實際有的。和主畫面共用同一個 notifier,
                  // 所以開著視窗切換也會兩邊一致。
                  if (applyStock != null)
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Checkbox(
                        value: applyStock!.value,
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                        onChanged: (b) => applyStock!.value = b ?? false,
                      ),
                      Text(tr('k2_drink_apply_stock'),
                          style: const TextStyle(fontSize: 12)),
                    ]),
                ],
              ),
              if (p.favored.isEmpty && p.avoided.isEmpty)
                Text(tr('k2_drink_none_stocked'),
                    style:
                        TextStyle(fontSize: 12, color: Colors.orange.shade800)),
              for (final s in p.favored) _pickRow(s, true),
              for (final s in p.avoided) _pickRow(s, false),
              const SizedBox(height: 10),
              // 5 款沒有 avoidWhen —— 「不在排除清單」不等於「評估過且通過」。
              Text(tr('k2_drink_no_avoid_note'),
                  style: TextStyle(
                      fontSize: 11, color: Colors.grey.shade600, height: 1.4)),
              const SizedBox(height: 16),

              // ── 免責:哪些是精確的、哪些是我們猜的 ────────────────────
              Text(tr('k2_drink_disclaimer'),
                  style: TextStyle(
                      fontSize: 11, color: Colors.grey.shade600, height: 1.5)),
            ],
          ),
        );
  }

  Widget _head(String s) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(s,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
      );

  Widget _box({
    required Color color,
    required Color border,
    required Widget child,
  }) =>
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: color,
          border: Border.all(color: border),
          borderRadius: BorderRadius.circular(6),
        ),
        child: child,
      );

  /// 一款飲品一列：標記 + slug + 中文 + 分類，底下一行「為什麼」。
  ///
  /// 理由直接取自對方知識庫的 `bestFor` / `avoidWhen`（中文濃縮）——
  /// 這才是真正的判斷依據，光給一個 slug 等於沒解釋。
  Widget _pickRow(String slug, bool favored) {
    final info = kK2Infusions.firstWhere((i) => i.slug == slug,
        orElse: () => K2Infusion(
            slug: slug,
            zh: '',
            category: '',
            bestForZh: '',
            bestForRules: const []));
    final c = favored ? Colors.green : Colors.red;
    final why = favored ? info.bestForZh : (info.avoidWhenZh ?? '');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(favored ? Icons.check_circle : Icons.cancel,
              size: 15, color: c.shade600),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  // slug 在前、等寬字體:它才是對帳用的識別碼。
                  Text(info.slug,
                      style: TextStyle(
                          fontSize: 12,
                          fontFamily: 'Consolas',
                          fontWeight: FontWeight.bold,
                          color: c.shade800)),
                  if (info.zh.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Text(info.zh, style: const TextStyle(fontSize: 12)),
                  ],
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(info.category,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 10.5, color: Colors.grey.shade500)),
                  ),
                ]),
                if (why.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(why,
                        style: TextStyle(
                            fontSize: 11,
                            height: 1.4,
                            color: Colors.grey.shade700)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
