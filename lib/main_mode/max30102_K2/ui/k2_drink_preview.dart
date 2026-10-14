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
  const K2Infusion(this.slug, this.zh, this.category, this.bestForRules,
      {this.avoidRules = const []});

  /// 對方知識庫裡的鍵值，**一個字母都不能改**（含大小寫）——
  /// 它是兩邊對帳的唯一識別碼，改了就對不回去。
  final String slug;

  /// 中文名，只為了讓人看得懂，不參與任何比對。
  final String zh;

  /// 對方知識庫裡的分類，**原文照搬不翻譯** —— 它是用來對帳的技術名詞，
  /// 翻譯之後就對不回他們的 `infusion-knowledge.ts` 了。
  final String category;

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
  K2Infusion('electrolytes', '電解質', 'hydration & minerals',
      [K2DrinkRule.elevatedHr, K2DrinkRule.sympathetic]),
  // ⚠️ 駝峰,不是 multivitamins —— 對方的鍵值就是這樣寫的。
  K2Infusion('multiVitamins', '綜合維生素', 'micronutrient support',
      [K2DrinkRule.neutral],
      avoidRules: [K2DrinkRule.sympathetic, K2DrinkRule.parasympathetic]),
  K2Infusion('caffeine', '咖啡因', 'stimulant / energy',
      [K2DrinkRule.parasympathetic],
      avoidRules: [K2DrinkRule.sympathetic, K2DrinkRule.elevatedHr]),
  K2Infusion('cascara', '咖啡果皮', 'gentle botanical lift',
      [K2DrinkRule.parasympathetic],
      avoidRules: [K2DrinkRule.sympathetic, K2DrinkRule.elevatedHr]),
  K2Infusion('collagen', '膠原蛋白', 'recovery & connective support',
      [K2DrinkRule.parasympathetic]),
  K2Infusion(
      'lutein', '葉黃素', 'antioxidant / eye support', [K2DrinkRule.sympathetic]),
  K2Infusion('bcaa', '支鏈胺基酸', 'amino-acid recovery',
      [K2DrinkRule.parasympathetic],
      avoidRules: [K2DrinkRule.sympathetic]),
  K2Infusion('whey', '乳清蛋白', 'protein & satiety', [K2DrinkRule.parasympathetic],
      avoidRules: [K2DrinkRule.sympathetic]),
  // creatine 是唯一兩端都適合的 —— 對方寫明它「also defensible for
  // stressed / sleep-deprived readings（認知韌性）」。
  K2Infusion('creatine', '肌酸', 'strength, power & cognitive resilience',
      [K2DrinkRule.parasympathetic, K2DrinkRule.sympathetic]),
  K2Infusion('fiber', '膳食纖維', 'digestive & gut–heart support',
      [K2DrinkRule.neutral, K2DrinkRule.sympathetic]),
  // ⚠️ 是 lCarnitine(左旋肉鹼),不是 metabolic —— metabolic 是它的分類名。
  K2Infusion('lCarnitine', '左旋肉鹼', 'metabolic / fat-to-energy',
      [K2DrinkRule.parasympathetic],
      avoidRules: [K2DrinkRule.sympathetic]),
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
  final List<String> avoided;

  /// 資料可不可信的警示。空的代表沒看出問題。
  final List<K2TrustIssue> trustIssues;

  /// 從 `toStrapiJson()` 的欄位推演。
  ///
  /// [perfusionPct] 是灌流指數 AC/DC（百分比），由呼叫端從波形算。
  /// [sd1] / [sd2] 來自 HRV，用來抓「SD1 > SD2」這個白雜訊特徵。
  factory K2DrinkPreview.from(
    Map<String, dynamic> vitals, {
    double? perfusionPct,
    double? sd1,
    double? sd2,
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
    final favored = [
      for (final i in kK2Infusions)
        if (i.bestForRules.contains(rule)) i.slug
    ];
    final avoided = [
      for (final i in kK2Infusions)
        if (i.avoidRules.contains(rule)) i.slug
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
    if (sd1 != null && sd2 != null && sd1 > sd2) {
      issues.add(K2TrustIssue('k2_drink_trust_sd',
          'SD1 ${sd1.toStringAsFixed(1)} > SD2 ${sd2.toStringAsFixed(1)}'));
    }
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
    if (rule == K2DrinkRule.parasympathetic && issues.isNotEmpty) {
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
Future<void> showK2DrinkPreview(
  BuildContext context, {
  required Listenable listenable,
  required K2DrinkPreview? Function() compute,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => _K2DrinkLive(listenable: listenable, compute: compute),
  );
}

class _K2DrinkLive extends StatefulWidget {
  const _K2DrinkLive({required this.listenable, required this.compute});

  final Listenable listenable;
  final K2DrinkPreview? Function() compute;

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
        return _K2DrinkDialog(preview: p);
      },
    );
  }
}

class _K2DrinkDialog extends StatelessWidget {
  const _K2DrinkDialog({required this.preview});

  final K2DrinkPreview preview;

  @override
  Widget build(BuildContext context) {
    final p = preview;
    final warn = p.trustIssues.isNotEmpty;
    return AlertDialog(
      title: Row(
        children: [
          Icon(warn ? Icons.warning_amber_rounded : Icons.local_cafe_outlined,
              color: warn ? Colors.orange.shade700 : Colors.teal),
          const SizedBox(width: 8),
          Expanded(child: Text(tr('k2_drink_title'))),
        ],
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── 可信度警示擺最上面:它比推薦結果重要 ──────────────────
              if (warn) ...[
                _box(
                  color: Colors.orange.shade50,
                  border: Colors.orange.shade300,
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
                color: Colors.teal.shade50,
                border: Colors.teal.shade200,
                child: Text(tr(k2DrinkRuleKey(p.rule)),
                    style: const TextStyle(fontSize: 13)),
              ),
              const SizedBox(height: 14),

              _head(tr('k2_drink_sec_picks')),
              if (p.favored.isNotEmpty)
                _chips(tr('k2_drink_favored'), p.favored, Colors.green),
              if (p.avoided.isNotEmpty) ...[
                const SizedBox(height: 6),
                _chips(tr('k2_drink_avoided'), p.avoided, Colors.red),
              ],
              const SizedBox(height: 16),

              // ── 免責:哪些是精確的、哪些是我們猜的 ────────────────────
              Text(tr('k2_drink_disclaimer'),
                  style: TextStyle(
                      fontSize: 11, color: Colors.grey.shade600, height: 1.5)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('k2_drink_close')),
        ),
      ],
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

  Widget _chips(String label, List<String> slugs, MaterialColor c) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 56,
            child: Text(label,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
          ),
          Expanded(
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final s in slugs)
                  Builder(builder: (_) {
                    final info = kK2Infusions.firstWhere((i) => i.slug == s,
                        orElse: () => K2Infusion(s, '', '', const []));
                    return Tooltip(
                      // 滑過去看對方知識庫裡的分類,方便對帳。
                      message: info.category,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: c.shade50,
                          border: Border.all(color: c.shade200),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        // slug 在前、中文在後:slug 才是對帳用的識別碼,
                        // 中文只是讓人看得懂,所以不能喧賓奪主。
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Text(info.slug,
                              style: TextStyle(
                                  fontSize: 11,
                                  fontFamily: 'Consolas',
                                  color: c.shade800)),
                          if (info.zh.isNotEmpty) ...[
                            const SizedBox(width: 5),
                            Text(info.zh,
                                style: TextStyle(
                                    fontSize: 11, color: c.shade600)),
                          ],
                        ]),
                      ),
                    );
                  }),
              ],
            ),
          ),
        ],
      );
}
