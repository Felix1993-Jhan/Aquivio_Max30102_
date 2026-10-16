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
import '../../../shared/ui/glass.dart';
import '../k2_vitals_metrics.dart';

/// 本地推演用的門檻。**這些數字是我們訂的，不是對方的。**
///
/// 對方的提示詞裡唯一寫死的只有 [sympatheticLfHf]（`LF/HF > 1.5`），
/// 那一個是照抄的；其餘都是我們為了讓預覽有東西可顯示而選的常見休息值。
/// 改這裡只影響這個預覽畫面，不影響任何實際送出的資料。
class K2DrinkThresholds {
  /// ★ 唯一照抄對方的數字：提示詞裡寫死的 `LF/HF > 1.5` = 交感主導。
  static const double sympatheticLfHf = 1.5;

  /// 以下皆為**我們自訂**的近似門檻。
  ///
  /// Stress 參考 Garmin 公開的 0~100 壓力分段（0~25 休息、26~50 低、
  /// 51~75 中、76~100 高）：≤ 50 投副交感、> 75 投交感、中間不投。
  /// 對方的 stress 是自創量表沒有文獻,選消費級裝置的通行分段,
  /// 是因為 LLM 讀到 `high stress` 時最可能套用的就是這類印象。
  static const double lowStress = 50;
  static const double highStress = 75;

  // HRV 兩個欄位的門檻都參考 Nunan 2010 的短時（5 分鐘）常模：
  // RMSSD 正常範圍約 19~75ms、SDNN 約 32~93ms（平均約 50）。
  // 對方規則寫的是 `high HRV — SDNN/RMSSD` 與 `low HRV`，沒有數字。
  static const double lowRmssd = 20; // 成人休息典型 20~50ms
  static const double highRmssd = 50;
  static const double lowSdnn = 30;
  static const double highSdnn = 50;

  /// PNS 是 RMSSD 換算來的（對數縮放），所以門檻**直接由 RMSSD 門檻換算**
  /// （= 33.3 / 77.4），不另外手訂。
  ///
  /// ⚠️ 原本手訂 40 / 60 時，換算回去是 RMSSD 23 / 35ms，與 RMSSD 自己的
  ///    20 / 50 對不上 —— RMSSD 35~50 的人會「PNS 投副交感、RMSSD 不投」，
  ///    同一個量測自相矛盾。改 RMSSD 門檻時 PNS 會跟著動。
  static final double lowPns = Max30102VitalsMetrics.pnsScore(lowRmssd)!;
  static final double highPns = Max30102VitalsMetrics.pnsScore(highRmssd)!;
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
    avoidWhenZh:
        '高 stress、低 PNS、交感主導（LF/HF > 1.5）或心率偏高 —— '
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
    bestForZh:
        '高壓力或交感主導的讀數，依據是抗氧化／氧化負荷的論點'
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
    bestForZh:
        '強恢復、準備好表現的讀數 —— 而且**獨特地**也適用於'
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

/// 一個欄位在推演裡投給哪一邊。
enum K2VoteSide {
  /// 投交感／壓力端一票。
  sympathetic,

  /// 投副交感／恢復端一票。
  parasympathetic,

  /// 心率偏高 —— 否決權生效，其餘不計。
  override,

  /// 心率沒有偏高，否決權沒觸發。
  notTriggered,

  /// 落在中間帶（或缺值），兩邊都不投。
  none,

  /// 這個欄位在 ① 裡，但四條規則**沒有引用**它（ANS score、confidence）。
  unused,
}

/// 推演裡的一筆投票：「哪個欄位、多少、照什麼門檻、投給誰」。
///
/// ⚠️ 規則（[K2DrinkPreview.rule]）是**從這些投票算出來的**，不是另外算一份。
///    顯示與判定同一個來源，才不會出現「畫面上說 A，實際算的是 B」。
class K2DrinkVote {
  const K2DrinkVote({
    required this.field,
    required this.value,
    required this.criterion,
    required this.side,
    required this.effectKey,
    this.theirs = false,
  });

  /// 欄位名，照 ① 的模板原文（英文），方便對照。
  final String field;

  /// 已格式化的數值。
  final String value;

  /// 門檻。只用符號（`> 60`、`40 ~ 60`），不需要翻譯。
  final String criterion;

  final K2VoteSide side;

  /// 「這個欄位大致影響什麼」的翻譯 key。
  final String effectKey;

  /// 門檻是**對方提示詞寫死的**（只有 LF/HF > 1.5）。其餘是我們本地自訂的。
  final bool theirs;
}

/// 推演結果。純資料，沒有 Flutter 相依，可以直接寫測試。
class K2DrinkPreview {
  K2DrinkPreview({
    required this.lines,
    required this.rule,
    required this.favored,
    required this.avoided,
    required this.trustIssues,
    required this.votes,
    required this.symVotes,
    required this.paraVotes,
  });

  /// 每個欄位的投票，照判定順序排（心率 → LF/HF → Stress → PNS → RMSSD → SDNN），
  /// 後面接兩個規則沒引用的（ANS score / confidence）。
  final List<K2DrinkVote> votes;

  /// 交感票數與副交感票數。心率偏高時兩者仍照實計算，但不參與判定。
  final int symVotes;
  final int paraVotes;

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
  /// 它是目前唯一的可信度依據 —— 而且是**有量過的**：
  /// 實測木頭桌面 0.149%、真手指 10.1%，差兩個量級，門檻怎麼挑都對。
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

    // ── ② 主導訊號 —— 先逐欄投票，規則再**從投票算出來** ─────────────
    //
    // 順序照對方的提示詞:心率偏高是**否決權**(寫明 regardless of the
    // other signals),所以先判它;其餘用「哪一端的票多」決定。
    // 畫面上 ② 底下那張表就是這份 votes —— 顯示與判定同一個來源。
    String n(double v) => _trim(v);
    final votes = <K2DrinkVote>[];

    // 心率:否決權
    final hrOver = meanHr != null && meanHr > K2DrinkThresholds.elevatedHr;
    votes.add(
      K2DrinkVote(
        field: 'Heart rate',
        value: f(meanHr, ' bpm'),
        criterion: meanHr == null
            ? '—'
            : (hrOver
                  ? '> ${n(K2DrinkThresholds.elevatedHr)}'
                  : '≤ ${n(K2DrinkThresholds.elevatedHr)}'),
        side: meanHr == null
            ? K2VoteSide.none
            : (hrOver ? K2VoteSide.override : K2VoteSide.notTriggered),
        effectKey: 'k2_drink_eff_hr',
      ),
    );

    // LF/HF:唯一寫死的門檻。≤ 1.5 只是「不投交感」,**不會投副交感**。
    final lfSym = lfHf != null && lfHf > K2DrinkThresholds.sympatheticLfHf;
    votes.add(
      K2DrinkVote(
        field: 'LF/HF',
        value: f(lfHf),
        criterion: lfHf == null
            ? '—'
            : (lfSym
                  ? '> ${n(K2DrinkThresholds.sympatheticLfHf)}'
                  : '≤ ${n(K2DrinkThresholds.sympatheticLfHf)}'),
        side: lfSym ? K2VoteSide.sympathetic : K2VoteSide.none,
        effectKey: 'k2_drink_eff_lfhf',
        theirs: true,
      ),
    );

    // Stress:照 Garmin 分段 —— ≤ 50 投副交感、> 75 投交感、50 ~ 75 不投
    K2VoteSide stressSide = K2VoteSide.none;
    String stressCrit = '—';
    if (stress != null) {
      if (stress > K2DrinkThresholds.highStress) {
        stressSide = K2VoteSide.sympathetic;
        stressCrit = '> ${n(K2DrinkThresholds.highStress)}';
      } else if (stress <= K2DrinkThresholds.lowStress) {
        stressSide = K2VoteSide.parasympathetic;
        stressCrit = '≤ ${n(K2DrinkThresholds.lowStress)}';
      } else {
        stressCrit =
            '${n(K2DrinkThresholds.lowStress)} ~ ${n(K2DrinkThresholds.highStress)}';
      }
    }
    votes.add(
      K2DrinkVote(
        field: 'Stress',
        value: f(stress),
        criterion: stressCrit,
        side: stressSide,
        effectKey: 'k2_drink_eff_stress',
      ),
    );

    // PNS:門檻由 RMSSD 20 / 50ms 換算(33.3 ~ 77.4 是中間帶)
    K2VoteSide pnsSide = K2VoteSide.none;
    String pnsCrit = '—';
    if (pns != null) {
      if (pns < K2DrinkThresholds.lowPns) {
        pnsSide = K2VoteSide.sympathetic;
        pnsCrit = '< ${n(K2DrinkThresholds.lowPns)}';
      } else if (pns > K2DrinkThresholds.highPns) {
        pnsSide = K2VoteSide.parasympathetic;
        pnsCrit = '> ${n(K2DrinkThresholds.highPns)}';
      } else {
        pnsCrit =
            '${n(K2DrinkThresholds.lowPns)} ~ ${n(K2DrinkThresholds.highPns)}';
      }
    }
    votes.add(
      K2DrinkVote(
        field: 'PNS',
        value: f(pns),
        criterion: pnsCrit,
        side: pnsSide,
        effectKey: 'k2_drink_eff_pns',
      ),
    );

    // HRV:對方兩條規則都有寫(交感 low HRV、副交感 high HRV — SDNN/RMSSD),
    // 所以 RMSSD 與 SDNN 各投一票。低於下限投交感、高於上限投副交感,中間不投。
    K2DrinkVote hrvVote(
      String field,
      double? v,
      double lo,
      double hi,
      String effectKey,
    ) {
      var side = K2VoteSide.none;
      var crit = '—';
      if (v != null) {
        if (v < lo) {
          side = K2VoteSide.sympathetic;
          crit = '< ${n(lo)} ms';
        } else if (v > hi) {
          side = K2VoteSide.parasympathetic;
          crit = '> ${n(hi)} ms';
        } else {
          crit = '${n(lo)} ~ ${n(hi)} ms';
        }
      }
      return K2DrinkVote(
        field: field,
        value: f(v, ' ms'),
        criterion: crit,
        side: side,
        effectKey: effectKey,
      );
    }

    votes.add(
      hrvVote(
        'RMSSD',
        rmssd,
        K2DrinkThresholds.lowRmssd,
        K2DrinkThresholds.highRmssd,
        'k2_drink_eff_rmssd',
      ),
    );
    votes.add(
      hrvVote(
        'SDNN',
        sdnn,
        K2DrinkThresholds.lowSdnn,
        K2DrinkThresholds.highSdnn,
        'k2_drink_eff_sdnn',
      ),
    );

    // 在 ① 裡、但規則沒引用的兩個:
    //   · ANS score —— 規則只用 `LF/HF > 1.5` 的寫法。它是 LF/HF 換算來的
    //     (ANS > 64.6 ⇔ LF/HF > 1.5),投票就等於同一票算兩次。
    //   · Reading confidence —— 提示詞與程式都沒有任何一條用到它。
    votes.add(
      K2DrinkVote(
        field: 'ANS score',
        value: f(ans),
        criterion: '—',
        side: K2VoteSide.unused,
        effectKey: 'k2_drink_eff_ans',
      ),
    );
    votes.add(
      K2DrinkVote(
        field: 'Reading confidence',
        value: conf is String && conf.isNotEmpty ? conf : 'n/a',
        criterion: '—',
        side: K2VoteSide.unused,
        effectKey: 'k2_drink_eff_conf',
      ),
    );

    final symVotes = votes
        .where((v) => v.side == K2VoteSide.sympathetic)
        .length;
    final paraVotes = votes
        .where((v) => v.side == K2VoteSide.parasympathetic)
        .length;

    final K2DrinkRule rule;
    if (hrOver) {
      rule = K2DrinkRule.elevatedHr;
    } else if (symVotes > paraVotes) {
      rule = K2DrinkRule.sympathetic;
    } else if (paraVotes > symVotes) {
      rule = K2DrinkRule.parasympathetic;
    } else {
      rule = K2DrinkRule.neutral;
    }

    // ── ③ 依規則分出偏好 / 排除 ──────────────────────────────────────
    bool inStock(K2Infusion i) => stocked == null || stocked.contains(i.slug);
    final favored = [
      for (final i in kK2Infusions)
        if (i.bestForRules.contains(rule) && inStock(i)) i.slug,
    ];
    final avoided = [
      for (final i in kK2Infusions)
        if (i.avoidRules.contains(rule) && inStock(i)) i.slug,
    ];

    // ── ④ 這筆資料到底可不可信 ───────────────────────────────────────
    //
    // 這一段才是這個畫面真正的價值 —— 對方**完全不做**這種檢查,
    // 送什麼他們就信什麼。
    final issues = <K2TrustIssue>[];
    if (perfusionPct != null &&
        perfusionPct < K2DrinkThresholds.minPerfusionPct) {
      issues.add(
        K2TrustIssue(
          'k2_drink_trust_pi',
          '${perfusionPct.toStringAsFixed(3)}%'
              ' < ${K2DrinkThresholds.minPerfusionPct}%',
        ),
      );
    }
    // ⚠️⚠️ 不要再加「SD1 > SD2 ⇒ 雜訊」這條判斷。**在我們的視窗長度下它是錯的。**
    //
    //    數學上 SD1 = RMSSD/√2、SD2² = 2·SDNN² − SD1²，
    //    所以 SD2 > SD1 等價於 SDNN > RMSSD/√2。
    //    而 SD2 量的是**長期變異** —— 12~30 秒、約 30 拍的窗裡根本沒有長期
    //    變異可以量，SD2 在結構上就被低估。於是呼吸性竇性心律不整明顯的人
    //    （年輕、休息、呼吸深）在短窗裡出現 SD1 > SD2 是**正常的**。
    //
    //    「SD1 > SD2 幾乎不可能」那個說法成立的前提是**五分鐘的標準量測**，
    //    拿到這裡來用等於拿錯尺。實測使用者本人的正常量測就會一直觸發，
    //    每秒重算一次還會讓警告框閃爍。移除，而且不要用別的啟發式補上去 ——
    //    沒驗證過的判斷比沒有判斷更糟。
    if (meanHr != null &&
        (meanHr < K2DrinkThresholds.hrMinPlausible ||
            meanHr > K2DrinkThresholds.hrMaxPlausible)) {
      issues.add(
        K2TrustIssue(
          'k2_drink_trust_hr',
          '${_trim(meanHr)} bpm'
              '（${_trim(K2DrinkThresholds.hrMinPlausible)}'
              '~${_trim(K2DrinkThresholds.hrMaxPlausible)}）',
        ),
      );
    }
    // 雜訊會把 HRV 推高 → 落在「恢復良好」端 → 推刺激類。
    // 這個方向性是這整件事最危險的地方,所以單獨標出來。
    if (rule == K2DrinkRule.parasympathetic && issues.isNotEmpty) {
      issues.add(const K2TrustIssue('k2_drink_trust_direction', ''));
    }

    return K2DrinkPreview(
      lines: lines,
      rule: rule,
      favored: favored,
      avoided: avoided,
      trustIssues: issues,
      votes: votes,
      symVotes: symVotes,
      paraVotes: paraVotes,
    );
  }

  static String _trim(double v) {
    final s = v.toStringAsFixed(1);
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }
}

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
    barrierColor: globalGlassNotifier.value
        ? const Color.fromRGBO(0, 0, 0, 0.28)
        : null,
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

  @override
  Widget build(BuildContext context) => globalGlassNotifier.value
      ? _glassDialog(context)
      : _materialDialog(context);

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
              color: GlassColors.shell,
              border: Border.all(color: GlassColors.shellEdge, width: 1.2),
              borderRadius: BorderRadius.circular(20),
            ),
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 14),
            child: _content(context),
          ),
        ),
      ),
    );
  }

  /// 原本的 Material 版本。留著是為了能一鍵比較，見 [globalGlassNotifier.value]。
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
        Icon(
          warn ? Icons.warning_amber_rounded : Icons.local_cafe_outlined,
          color: warn ? Colors.orange.shade800 : Colors.teal.shade700,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            tr('k2_drink_title'),
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
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
              color: globalGlassNotifier.value
                  ? GlassColors.warnFill
                  : Colors.orange.shade50,
              border: globalGlassNotifier.value
                  ? GlassColors.warnEdge
                  : Colors.orange.shade300,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr('k2_drink_trust_head'),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.orange.shade900,
                    ),
                  ),
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
                color: Color(0xFFD4D4D4),
              ),
            ),
          ),
          const SizedBox(height: 14),

          _head(tr('k2_drink_sec_rule')),
          _box(
            color: globalGlassNotifier.value
                ? GlassColors.tealFill
                : Colors.teal.shade50,
            border: globalGlassNotifier.value
                ? GlassColors.tealEdge
                : Colors.teal.shade200,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr(k2DrinkRuleKey(p.rule)),
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 10),
                // 為什麼命中這一條:① 裡每個欄位投給哪一邊。
                // 這張表就是判定用的 votes 本身,不是另外算的說明。
                Text(
                  tr('k2_drink_vote_head'),
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade800,
                  ),
                ),
                const SizedBox(height: 6),
                for (final v in p.votes) _voteRow(v),
                const Divider(height: 14),
                Text(
                  p.rule == K2DrinkRule.elevatedHr
                      ? tr('k2_drink_tally_override')
                      : trParams('k2_drink_tally', {
                          's': '${p.symVotes}',
                          'p': '${p.paraVotes}',
                        }),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          Row(
            children: [
              Expanded(child: _head(tr('k2_drink_sec_picks'))),
              // 只看機器實際有的。和主畫面共用同一個 notifier,
              // 所以開著視窗切換也會兩邊一致。
              if (applyStock != null)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      value: applyStock!.value,
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      onChanged: (b) => applyStock!.value = b ?? false,
                    ),
                    Text(
                      tr('k2_drink_apply_stock'),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
            ],
          ),
          if (p.favored.isEmpty && p.avoided.isEmpty)
            Text(
              tr('k2_drink_none_stocked'),
              style: TextStyle(fontSize: 12, color: Colors.orange.shade800),
            ),
          for (final s in p.favored) _pickRow(s, true),
          for (final s in p.avoided) _pickRow(s, false),
          const SizedBox(height: 10),
          // 5 款沒有 avoidWhen —— 「不在排除清單」不等於「評估過且通過」。
          Text(
            tr('k2_drink_no_avoid_note'),
            style: TextStyle(
              fontSize: 11,
              color: Colors.grey.shade600,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 16),

          // ── 免責:哪些是精確的、哪些是我們猜的 ────────────────────
          Text(
            tr('k2_drink_disclaimer'),
            style: TextStyle(
              fontSize: 11,
              color: Colors.grey.shade600,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _head(String s) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      s,
      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
    ),
  );

  Widget _box({
    required Color color,
    required Color border,
    required Widget child,
  }) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: color,
      border: Border.all(color: border),
      borderRadius: BorderRadius.circular(6),
    ),
    child: child,
  );

  /// 一筆投票一列：欄位 數值 門檻 → 投給誰，底下一行小字「這個欄位影響什麼」。
  Widget _voteRow(K2DrinkVote v) {
    final (String label, Color color) = switch (v.side) {
      K2VoteSide.sympathetic => (
        tr('k2_drink_vote_sym'),
        Colors.orange.shade800,
      ),
      K2VoteSide.parasympathetic => (
        tr('k2_drink_vote_para'),
        Colors.teal.shade700,
      ),
      K2VoteSide.override => (
        tr('k2_drink_vote_override'),
        Colors.red.shade700,
      ),
      K2VoteSide.notTriggered => (
        tr('k2_drink_vote_not_triggered'),
        Colors.grey.shade600,
      ),
      K2VoteSide.none => (tr('k2_drink_vote_none'), Colors.grey.shade600),
      K2VoteSide.unused => (tr('k2_drink_vote_unused'), Colors.grey.shade500),
    };
    final dim = v.side == K2VoteSide.unused;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 132,
                child: Text(
                  v.theirs ? '${v.field} ★' : v.field,
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'Consolas',
                    fontWeight: FontWeight.bold,
                    color: dim ? Colors.grey.shade500 : Colors.grey.shade900,
                  ),
                ),
              ),
              SizedBox(
                width: 76,
                child: Text(
                  v.value,
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'Consolas',
                    color: dim ? Colors.grey.shade500 : null,
                  ),
                ),
              ),
              SizedBox(
                width: 92,
                child: Text(
                  v.criterion,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontFamily: 'Consolas',
                    color: Colors.grey.shade600,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  border: Border.all(color: color),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  label,
                  style: TextStyle(fontSize: 11, color: color),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 1, left: 2),
            child: Text(
              tr(v.effectKey),
              style: TextStyle(
                fontSize: 10.5,
                height: 1.35,
                color: Colors.grey.shade600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 一款飲品一列：標記 + slug + 中文 + 分類，底下一行「為什麼」。
  ///
  /// 理由直接取自對方知識庫的 `bestFor` / `avoidWhen`（中文濃縮）——
  /// 這才是真正的判斷依據，光給一個 slug 等於沒解釋。
  Widget _pickRow(String slug, bool favored) {
    final info = kK2Infusions.firstWhere(
      (i) => i.slug == slug,
      orElse: () => K2Infusion(
        slug: slug,
        zh: '',
        category: '',
        bestForZh: '',
        bestForRules: const [],
      ),
    );
    final c = favored ? Colors.green : Colors.red;
    final why = favored ? info.bestForZh : (info.avoidWhenZh ?? '');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            favored ? Icons.check_circle : Icons.cancel,
            size: 15,
            color: c.shade600,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // slug 在前、等寬字體:它才是對帳用的識別碼。
                    Text(
                      info.slug,
                      style: TextStyle(
                        fontSize: 12,
                        fontFamily: 'Consolas',
                        fontWeight: FontWeight.bold,
                        color: c.shade800,
                      ),
                    ),
                    if (info.zh.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Text(info.zh, style: const TextStyle(fontSize: 12)),
                    ],
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        info.category,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10.5,
                          color: Colors.grey.shade500,
                        ),
                      ),
                    ),
                  ],
                ),
                if (why.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      why,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.4,
                        color: Colors.grey.shade700,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
