// ============================================================================
// k2_vitals_metrics 的驗證測試
// ============================================================================
// 這一組測試的目的很單純:**頻譜類的程式寫錯不會報錯,只會安靜地給錯數字。**
// 所以用「已知答案」的合成訊號去餵它 —— 我在 RR 序列裡埋一個指定頻率的振盪,
// 檢查功率有沒有落在該落的頻帶。這種錯誤靠肉眼看畫面是抓不出來的。
//
// 另外驗證幾條「誠實性」規則:30 秒的 LF 必須被判為不可用、
// toStrapiJson 的 lf_hf / ans 必須是 null。那些是刻意的設計,不是漏做,
// 有測試釘著才不會被之後的人「順手修好」。
// ============================================================================

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_hrv_calculator.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_vitals_metrics.dart';

/// 合成一段 RR:平均 [meanRr]，疊一個 [freq] Hz、振幅 [amp] 的正弦振盪。
///
/// RR 值會**量化到取樣點**(10ms @100Hz),跟真機一樣 —— 這樣測到的也包含
/// 量化雜訊的影響,不會給出一個現實中拿不到的漂亮結果。
List<HrvRrPoint> synth({
  required double durationSec,
  double meanRr = 850,
  double amp = 40,
  required double freq,
}) {
  const fs = 100;
  final pts = <HrvRrPoint>[];
  int abs = 0;
  double t = 0;
  while (t < durationSec) {
    final rr = meanRr + amp * math.sin(2 * math.pi * freq * t);
    final samples = (rr / 1000 * fs).round();
    if (samples <= 0) break;
    pts.add((
      rr: samples * 1000.0 / fs,
      startAbs: abs,
      endAbs: abs + samples,
    ));
    abs += samples;
    t = abs / fs;
  }
  return pts;
}

void main() {
  group('Lomb-Scargle 頻譜', () {
    test('埋在 HF 帶(0.25Hz)的振盪 → 功率落在 HF', () {
      final s = Max30102VitalsMetrics.spectrum(
        synth(durationSec: 120, freq: 0.25),
      );
      expect(s, isNotNull);
      expect(s!.hf, greaterThan(s.lf * 3),
          reason: '0.25Hz 是呼吸帶,HF 應該遠大於 LF');
      expect(s.hfNu, greaterThan(70), reason: 'HF 正規化占比應該壓倒性');
    });

    test('埋在 LF 帶(0.10Hz)的振盪 → 功率落在 LF', () {
      final s = Max30102VitalsMetrics.spectrum(
        synth(durationSec: 120, freq: 0.10),
      );
      expect(s, isNotNull);
      expect(s!.lf, greaterThan(s.hf * 3),
          reason: '0.10Hz 是 Mayer wave,LF 應該遠大於 HF');
      expect(s.lfHf, greaterThan(3));
    });

    test('★ 總功率 ≈ SDNN²(Parseval)—— 歸一化有沒有做對', () {
      final pts = synth(durationSec: 120, freq: 0.15);
      final s = Max30102VitalsMetrics.spectrum(pts)!;
      final hv = Max30102HrvCalculator.hrvFrom(pts)!;
      final sdnnSq = hv.sdnn * hv.sdnn;
      expect(s.totalPower, closeTo(sdnnSq, sdnnSq * 0.02),
          reason: '三個頻帶涵蓋整個掃描格,加起來就該等於變異數');
    });

    test('拍數不足回 null,不硬算', () {
      expect(Max30102VitalsMetrics.spectrum(synth(durationSec: 3, freq: 0.25)),
          isNull);
    });
  });

  group('★ LF 可用性的誠實回報', () {
    test('30 秒:lfUsable=false,而且只看得到約 1.2 個 LF 週期', () {
      final s = Max30102VitalsMetrics.spectrum(
        synth(durationSec: 30, freq: 0.10),
      )!;
      expect(s.lfUsable, isFalse, reason: '30 秒的 LF 不可信,必須擋掉');
      expect(s.lfCycles, closeTo(1.2, 0.2),
          reason: '0.04Hz 週期 25 秒,30 秒只走 1.2 圈');
      expect(s.lfBins, closeTo(3.3, 0.5), reason: '整條 LF 只跨 3.3 個解析格');
      expect(s.hfUsable, isTrue, reason: 'HF 在 30 秒是勉強可用的');
    });

    test('2 分鐘:lfUsable=true,LF 週期數 ≈ 4.8', () {
      final s = Max30102VitalsMetrics.spectrum(
        synth(durationSec: 120, freq: 0.10),
      )!;
      expect(s.lfUsable, isTrue);
      expect(s.lfCycles, closeTo(4.8, 0.3));
      expect(s.lfBins, closeTo(13.2, 1.0));
    });
  });

  group('Baevsky 壓力指數', () {
    test('心跳越規律(變異越小)→ SI 越高', () {
      final steady = [for (int i = 0; i < 40; i++) 850.0 + (i % 2) * 10];
      final loose = [for (int i = 0; i < 40; i++) 850.0 + (i % 8) * 40];
      final siSteady = Max30102VitalsMetrics.stressIndex(steady)!;
      final siLoose = Max30102VitalsMetrics.stressIndex(loose)!;
      expect(siSteady, greaterThan(siLoose),
          reason: '直方圖又高又窄 = 交感壓制 = SI 高');
    });

    test('所有 RR 完全相同 → 全距為 0 → 回 null 而不是除以零', () {
      expect(Max30102VitalsMetrics.stressIndex(List.filled(20, 850.0)), isNull);
    });

    test('拍數不足回 null', () {
      expect(Max30102VitalsMetrics.stressIndex([850, 860, 870]), isNull);
    });
  });

  group('PNS / SNS / ANS', () {
    test('RMSSD 高、心跳慢 → PNS 高(偏放鬆)', () {
      final relaxed = Max30102HrvCalculator.hrvFrom(
        synth(durationSec: 120, meanRr: 1000, amp: 60, freq: 0.25),
      )!;
      final tense = Max30102HrvCalculator.hrvFrom(
        synth(durationSec: 120, meanRr: 700, amp: 8, freq: 0.25),
      )!;
      expect(Max30102VitalsMetrics.pns(relaxed),
          greaterThan(Max30102VitalsMetrics.pns(tense)));
    });

    test('ansTimeDomain = SNS − PNS,放鬆時為負', () {
      final relaxed = Max30102HrvCalculator.hrvFrom(
        synth(durationSec: 120, meanRr: 1000, amp: 60, freq: 0.25),
      )!;
      final si = Max30102VitalsMetrics.stressIndex(
        [for (final p in synth(durationSec: 120, meanRr: 1000, amp: 60, freq: 0.25)) p.rr],
      );
      final ans = Max30102VitalsMetrics.ansTimeDomain(relaxed, si);
      expect(ans, lessThan(0), reason: '偏副交感 → SNS−PNS 應為負');
      expect(
        ans,
        closeTo(
          Max30102VitalsMetrics.sns(relaxed, si) -
              Max30102VitalsMetrics.pns(relaxed),
          1e-9,
        ),
      );
    });

    test('壓力指數算不出來時 SNS 只用兩項,不崩', () {
      final hv = Max30102HrvCalculator.hrvFrom(
        synth(durationSec: 60, freq: 0.25),
      )!;
      expect(Max30102VitalsMetrics.sns(hv, null), isA<double>());
    });
  });

  group('confidence', () {
    test('沉澱期一律 null —— 數字還沒穩,不該給任何評級', () {
      expect(
        Max30102VitalsMetrics.confidence(
            beats: 100, sqiOk: true, settling: true),
        isNull,
      );
    });

    test('拍數低於 HRV 暖機門檻(9)→ null', () {
      expect(
        Max30102VitalsMetrics.confidence(
            beats: 8, sqiOk: true, settling: false),
        isNull,
      );
    });

    test('拍數夠且 SQI 過 → good;SQI 沒過就降級', () {
      expect(
        Max30102VitalsMetrics.confidence(
            beats: 30, sqiOk: true, settling: false),
        'good',
      );
      expect(
        Max30102VitalsMetrics.confidence(
            beats: 30, sqiOk: false, settling: false),
        'rough',
        reason: '拍數夠但訊號品質沒過 → 不能給 good',
      );
      expect(
        Max30102VitalsMetrics.confidence(
            beats: 10, sqiOk: true, settling: false),
        'very rough',
      );
    });

    test('★ good 的門檻必須在 30 秒視窗內可達 —— 慢心率也要拿得到', () {
      // 30 秒視窗的實際跨度約 28 秒,可達拍數 = 28 × bpm / 60。
      // 舊值 25 拍需要 54 bpm,低於此的人永遠拿不到 good(實測遇過 54 bpm)。
      const spanSec = 28.0;
      int beatsAt(double bpm) => (spanSec * bpm / 60).floor();

      for (final bpm in [45.0, 50.0, 55.0, 70.0]) {
        expect(
          Max30102VitalsMetrics.confidence(
              beats: beatsAt(bpm), sqiOk: true, settling: false),
          'good',
          reason: '$bpm bpm 在 28 秒內收 ${beatsAt(bpm)} 拍,應該拿得到 good',
        );
      }
      // 門檻本身要低於「最慢的合理靜息心率」在滿視窗下的拍數
      expect(Max30102VitalsMetrics.confidenceGoodBeats,
          lessThanOrEqualTo(beatsAt(45)),
          reason: '門檻若高於 45bpm 的可達拍數,那類使用者就被永久排除了');
    });

    test('視窗太短(10 秒)時降級 —— 那是正確行為,不是 bug', () {
      // 10 秒 @70bpm 約 11 拍
      expect(
        Max30102VitalsMetrics.confidence(
            beats: 11, sqiOk: true, settling: false),
        'very rough',
      );
    });
  });

  group('波形訊噪比 snr_db', () {
    List<int> wave(double bpm, double noiseAmp, {int seconds = 20}) {
      final rnd = math.Random(42);
      const fs = 100;
      final f0 = bpm / 60;
      return [
        for (int i = 0; i < fs * seconds; i++)
          (100000 +
                  1000 * math.sin(2 * math.pi * f0 * i / fs) +
                  noiseAmp * (rnd.nextDouble() - 0.5))
              .round(),
      ];
    }

    test('乾淨正弦 → SNR 高', () {
      final db = Max30102VitalsMetrics.snrDb(wave(72, 0), 72)!;
      expect(db, greaterThan(20), reason: '沒有雜訊時能量全在基頻上');
    });

    test('加雜訊 → SNR 下降', () {
      final clean = Max30102VitalsMetrics.snrDb(wave(72, 0), 72)!;
      final noisy = Max30102VitalsMetrics.snrDb(wave(72, 4000), 72)!;
      expect(noisy, lessThan(clean));
    });

    test('資料不足 5 秒 → null', () {
      expect(Max30102VitalsMetrics.snrDb(wave(72, 0, seconds: 3), 72), isNull);
    });

    test('沒有 bpm → null(定位不到基頻)', () {
      expect(Max30102VitalsMetrics.snrDb(wave(72, 0), null), isNull);
    });
  });

  group('★ 整合方(aquivio-vitals)公式對齊', () {
    // 這幾條是逐字對照 aquivio-vitals 的 core.py::derived_scores() 寫的。
    // 對方的 prompt(deepseek.ts)把這些欄位印成 `X/100`,判斷門檻也是照
    // 那個尺度校準的,所以數值必須一致 —— 差一個尺度,LLM 的判讀就整個反了。

    test('pns = RMSSD 的對數縮放:10ms→0、80ms→100', () {
      expect(Max30102VitalsMetrics.pnsScore(10), closeTo(0, 0.01));
      expect(Max30102VitalsMetrics.pnsScore(80), closeTo(100, 0.01));
      // 官方範例:rmssd 52 → pns 79
      expect(Max30102VitalsMetrics.pnsScore(52), closeTo(79.3, 0.2));
      // 超出兩端要夾住,不能給負值或 >100
      expect(Max30102VitalsMetrics.pnsScore(5), 0);
      expect(Max30102VitalsMetrics.pnsScore(200), 100);
    });

    test('ans = LF/HF 的 log2 縮放:0.25→0、1→50、4→100', () {
      expect(Max30102VitalsMetrics.ansScore(0.25), closeTo(0, 0.01));
      expect(Max30102VitalsMetrics.ansScore(1.0), closeTo(50, 0.01));
      expect(Max30102VitalsMetrics.ansScore(4.0), closeTo(100, 0.01));
      // **越大越偏交感** —— 方向不能反
      expect(Max30102VitalsMetrics.ansScore(2.0)!,
          greaterThan(Max30102VitalsMetrics.ansScore(0.5)!));
    });

    test('stress = 0.6×(100−pns) + 0.4×ans,任一為 null 就 null', () {
      // 官方範例:pns 79.3 + ans 59.5 → stress 36
      expect(Max30102VitalsMetrics.stressScore(79.3, 59.5), closeTo(36.2, 0.2));
      expect(Max30102VitalsMetrics.stressScore(null, 50), isNull);
      expect(Max30102VitalsMetrics.stressScore(50, null), isNull,
          reason: 'ans 算不出來時他們也不出 stress,行為要一致');
    });

    test('activity = (心率−60)/80', () {
      expect(Max30102VitalsMetrics.activityScore(60), 0);
      expect(Max30102VitalsMetrics.activityScore(140), 100);
      expect(Max30102VitalsMetrics.activityScore(84), closeTo(30, 0.01));
      expect(Max30102VitalsMetrics.activityScore(50), 0, reason: '低於基準夾成 0');
    });

    test('confidence 改看 SNR:≥6 good、≥1 rough、其餘 very rough', () {
      expect(Max30102VitalsMetrics.confidenceFromSnr(8.0), 'good');
      expect(Max30102VitalsMetrics.confidenceFromSnr(6.0), 'good');
      expect(Max30102VitalsMetrics.confidenceFromSnr(3.0), 'rough');
      expect(Max30102VitalsMetrics.confidenceFromSnr(1.0), 'rough');
      expect(Max30102VitalsMetrics.confidenceFromSnr(0.5), 'very rough');
      expect(Max30102VitalsMetrics.confidenceFromSnr(null), isNull);
    });

    test('lf/hf 的單位換算:他們 = 我們(ms²) × 1.024e-3', () {
      final s = Max30102VitalsMetrics.spectrum(
        synth(durationSec: 120, freq: 0.10),
      )!;
      expect(s.lfAquivio, closeTo(s.lf * 1.024e-3, 1e-9));
      expect(s.hfAquivio, closeTo(s.hf * 1.024e-3, 1e-9));
      // 比值不受縮放影響 —— 這正是 lf_hf 可以直接互比的原因
      expect(s.lfAquivio / s.hfAquivio, closeTo(s.lfHf, 1e-9));
    });
  });

  group('★ toStrapiJson 的欄位契約', () {
    VitalsMetrics build(double seconds) {
      final pts = synth(durationSec: seconds, freq: 0.10);
      return Max30102VitalsMetrics.compute(
        pts: pts,
        hv: Max30102HrvCalculator.hrvFrom(pts),
        sqiOk: true,
        settling: false,
        bpm: 70,
      );
    }

    test('★ 30 秒也照送 lf_hf,但附上可信度', () {
      final j = build(30).toStrapiJson();
      // 攝影機端(aquivio-vitals)同樣是 30 秒視窗且照樣送 —— 我們送 null
      // 只會讓同一個欄位在兩台裝置上行為不一致。
      expect(j['lf_hf'], isNotNull, reason: '數字照送,誠實靠標註不靠藏');
      expect(j['lf_reliable'], isFalse, reason: '但要講明它不可信');
      expect((j['lf_cycles'] as double), lessThan(4.0));
      expect(j['window_sec'], isNotNull);
    });

    test('2 分鐘:lf_reliable 轉為 true', () {
      final j = build(120).toStrapiJson();
      expect(j['lf_hf'], isNotNull);
      expect(j['lf_reliable'], isTrue);
    });

    test('★ ans 現在有值,且照 aquivio 公式由 lf_hf 導出', () {
      final m = build(120);
      final j = m.toStrapiJson();
      expect(j['ans'], isNotNull);
      expect(j['ans'],
          closeTo(Max30102VitalsMetrics.ansScore(m.lfHf)!, 1e-9));
      // 我們自己那套時域值改放在不同名字下,不會撞名
      expect(j['ans_max30102'], isNotNull);
      expect(j['ans'], isNot(equals(j['ans_max30102'])));
    });

    test('★ lf/hf 用他們的單位,我們的 ms² 另外標名', () {
      final j = build(120).toStrapiJson();
      expect(j['lf'], isNotNull);
      expect(j['lf_ms2'], isNotNull);
      expect(j['lf'], closeTo((j['lf_ms2'] as double) * 1.024e-3, 1e-9),
          reason: '同名欄位必須是同一個單位,否則比 null 還危險');
      expect((j['lf_ms2'] as double), greaterThan(j['lf'] as double));
    });

    test('四個 0~100 分數都在範圍內', () {
      final j = build(120).toStrapiJson();
      for (final k in ['pns', 'ans', 'stress', 'activity']) {
        final v = j[k] as double?;
        expect(v, isNotNull, reason: '$k 應該算得出來');
        expect(v!, inInclusiveRange(0, 100), reason: '$k 必須夾在 0~100');
      }
    });

    test('sqi 是 1/0 的二元值', () {
      expect(build(30).sqi, 1);
    });
  });
}
