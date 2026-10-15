// ============================================================================
// 推薦飲品預覽（離線推演）測試
// ============================================================================
// 案例全部用**實際量到的數據**，不是編的：
//   · 木頭桌面那筆（PI 0.149%、心率 207）
//   · 被串口停滯汙染那筆（RMSSD 188.8、SD1 > SD2）
//   · 正常健康的一筆
//
// 最重要的是 ② ——「雜訊把 HRV 推高 → 被讀成恢復良好 → 推刺激類」這個方向性，
// 是整件事最危險的地方。測試把它釘住，將來改門檻時不會不小心讓它消音。
// ============================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/ui/k2_drink_preview.dart';

/// 組一份 toStrapiJson() 形狀的欄位。沒給的就是 null（真實情況常常有 null）。
Map<String, dynamic> vitals({
  double? meanHr,
  double? sdnn,
  double? rmssd,
  double? lfHf,
  double? ans,
  double? pns,
  double? stress,
  String? confidence,
}) =>
    {
      'mean_hr': meanHr,
      'sdnn': sdnn,
      'rmssd': rmssd,
      'lf_hf': lfHf,
      'ans': ans,
      'pns': pns,
      'stress': stress,
      'confidence': confidence,
    };

void main() {
  group('K2DrinkPreview', () {
    test('① 木頭桌面：心率 207 + 灌流指數 0.149% → 命中心率偏高，且標出不可信', () {
      final p = K2DrinkPreview.from(
        vitals(meanHr: 207, sdnn: 50.9, rmssd: 78.4, pns: 99, ans: 0),
        perfusionPct: 0.149, // 實測木頭桌面
      );

      expect(p.rule, K2DrinkRule.elevatedHr,
          reason: '心率偏高是否決權,對方寫明不管其他訊號');
      expect(p.favored, contains('electrolytes'));
      expect(p.avoided, contains('caffeine'),
          reason: '心率偏高時咖啡因一定要被排除');

      expect(p.trustIssues.map((e) => e.titleKey), contains('k2_drink_trust_pi'),
          reason: '灌流指數兩個量級的差距必須被抓到');
    });

    test('② 訊號強度正常的高 HRV → 推到刺激類，但**不可以**跳警告', () {
      // 這組原本是「被停滯汙染」的案例,靠 SD1 > SD2 觸發警告。
      // ⚠️ 那條判斷已經移除:SD2 量的是長期變異,12~30 秒的窗裡根本沒有
      //    長期變異可量,SD2 在結構上被低估 —— 呼吸性竇性心律不整明顯的人
      //    在短窗裡 SD1 > SD2 是**正常的**。實測使用者本人就會一直觸發。
      //    「SD1 > SD2 幾乎不可能」成立的前提是五分鐘的標準量測。
      final p = K2DrinkPreview.from(
        vitals(meanHr: 61, sdnn: 123.8, rmssd: 188.8, pns: 99, stress: 20),
        perfusionPct: 10.1, // 訊號強度沒問題
      );

      expect(p.rule, K2DrinkRule.parasympathetic,
          reason: '高 HRV + 高 PNS + 低 stress 會被讀成「恢復良好」');
      expect(p.favored, contains('caffeine'),
          reason: '這個傾向本身還在 —— 只是我們沒有可靠的依據去警告它');

      expect(p.trustIssues, isEmpty,
          reason: '灌流指數正常就不該跳警告 —— **誤報會讓人以後忽略真正的警告**');
    });

    test('③ 正常健康的一筆 → 不可以亂喊狼來了', () {
      final p = K2DrinkPreview.from(
        vitals(
            meanHr: 72,
            sdnn: 48,
            rmssd: 35,
            lfHf: 1.0,
            pns: 50,
            stress: 40,
            confidence: 'high'),
        perfusionPct: 8.0,
      );

      expect(p.trustIssues, isEmpty,
          reason: '一切正常卻跳警示,會讓人以後忽略真正的警示');
      expect(p.rule, isNot(K2DrinkRule.elevatedHr));
    });

    test('④ 交感主導 → 咖啡因與各種刺激／表現類全部排除', () {
      final p = K2DrinkPreview.from(
        vitals(meanHr: 88, sdnn: 18, rmssd: 12, lfHf: 3.2, pns: 20, stress: 80),
        perfusionPct: 6.0,
      );

      expect(p.rule, K2DrinkRule.sympathetic);
      expect(p.favored, contains('lutein'));
      expect(p.favored, contains('electrolytes'));
      for (final s in ['caffeine', 'cascara', 'bcaa', 'whey', 'lCarnitine']) {
        expect(p.avoided, contains(s), reason: '$s 在交感主導時應該被排除');
      }
      // creatine 是唯一兩端都適合的（對方寫明壓力/睡眠不足也站得住腳）
      expect(p.favored, contains('creatine'));
    });

    test('⑤ 欄位全是 null → 顯示 n/a,不可以崩潰', () {
      final p = K2DrinkPreview.from(vitals());

      expect(p.rule, K2DrinkRule.neutral);
      expect(p.lines.join('\n'), contains('n/a'));
      expect(p.lines.length, 6, reason: '六行都要在,缺值用 n/a 表達');
      expect(p.trustIssues, isEmpty, reason: '沒有資料不等於資料有問題');
    });

    test('⑧ 只看機器有的：沒進貨的不會出現在任何一邊', () {
      final v = vitals(
          meanHr: 88, sdnn: 18, rmssd: 12, lfHf: 3.2, pns: 20, stress: 80);

      final all = K2DrinkPreview.from(v, perfusionPct: 6.0);
      expect(all.favored, contains('lutein'));
      expect(all.avoided, contains('caffeine'));

      // 這台機器只有電解質和纖維
      final some = K2DrinkPreview.from(v,
          perfusionPct: 6.0, stocked: {'electrolytes', 'fiber'});
      expect(some.favored, ['electrolytes', 'fiber']);
      expect(some.avoided, isEmpty,
          reason: 'caffeine 沒進貨,連「排除」都不該列 —— 對方根本看不到它');

      // 一款都沒有 → 兩邊都空,畫面要能講出這件事
      final none = K2DrinkPreview.from(v, perfusionPct: 6.0, stocked: {});
      expect(none.favored, isEmpty);
      expect(none.avoided, isEmpty);
    });

    test('⑨ 每一款都要有入圍理由；有 avoidRules 的就一定要有迴避理由', () {
      for (final i in kK2Infusions) {
        expect(i.bestForZh, isNotEmpty, reason: '${i.slug} 少了入圍理由');
        if (i.avoidRules.isNotEmpty) {
          expect(i.avoidWhenZh, isNotNull,
              reason: '${i.slug} 有迴避規則卻沒有理由,畫面會列出一條空的');
        }
      }
      // 對方知識庫裡**沒有** avoidWhen 的那 5 款,我們也不可以自己編一個出來
      final noAvoid =
          kK2Infusions.where((i) => i.avoidWhenZh == null).map((i) => i.slug);
      expect(noAvoid, containsAll(
          ['electrolytes', 'collagen', 'lutein', 'creatine', 'fiber']));
    });

    test('⑦ slug 必須逐字對上對方 infusion-knowledge.ts 的鍵值', () {
      // ⚠️ 這 11 個是從對方原始碼抄來的,**含大小寫一個字母都不能改** ——
      //    slug 是兩邊對帳的唯一識別碼。
      //    寫這份工具時我靠猜錯了兩個(multivitamins → multiVitamins、
      //    metabolic → lCarnitine,後者其實是分類名不是鍵值),所以把它釘住。
      expect(kK2Infusions.map((i) => i.slug).toList(), [
        'electrolytes',
        'multiVitamins',
        'caffeine',
        'cascara',
        'collagen',
        'lutein',
        'bcaa',
        'whey',
        'creatine',
        'fiber',
        'lCarnitine',
      ]);
      // 每一款都要有中文,否則畫面上會只剩英文 slug
      expect(kK2Infusions.every((i) => i.zh.isNotEmpty), isTrue);
    });

    test('⑥ 送出的欄位要逐字照對方模板', () {
      final p = K2DrinkPreview.from(
        vitals(
            meanHr: 56,
            sdnn: 105,
            rmssd: 127.3,
            lfHf: 0.77,
            ans: 37.3,
            pns: 100,
            confidence: '粗略'),
      );

      final text = p.lines.join('\n');
      expect(text, contains('- HRV SDNN: 105 ms, RMSSD: 127.3 ms'));
      expect(text, contains('- ANS balance (LF/HF 0.8); ANS score 37.3/100'));
      expect(text, contains('- PNS / recovery: 100/100'));
      expect(text, contains('- Stress: n/a/100'));
      expect(text, contains('- Heart rate: 56 bpm'));
      expect(text, contains('- Reading confidence: 粗略'));
    });
  });
}
