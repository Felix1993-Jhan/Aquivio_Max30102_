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

  group('★ toStrapiJson 的誠實性規則', () {
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

    test('30 秒:lf_hf 必須是 null,不能給假數字', () {
      final j = build(30).toStrapiJson();
      expect(j['lf_hf'], isNull, reason: '30 秒測不到 LF,寧可缺欄位');
      expect(j['sdnn'], isNotNull, reason: '但時域的量照給');
      expect(j['rmssd'], isNotNull);
      expect(j['ln_rmssd'], isNotNull);
      expect(j['pns'], isNotNull);
    });

    test('2 分鐘:lf_hf 有值', () {
      expect(build(120).toStrapiJson()['lf_hf'], isNotNull);
    });

    test('ans 恆為 null —— 定義與對方不同,未經同意不塞進去', () {
      expect(build(30).toStrapiJson()['ans'], isNull);
      expect(build(120).toStrapiJson()['ans'], isNull,
          reason: '就算視窗夠長也不填:我們的是時域替代值,定義不一樣');
      expect(build(120).ansTimeDomain, isNotNull,
          reason: '但值本身要算得出來,給 UI/實驗用');
    });

    test('sqi 是 1/0 的二元值', () {
      expect(build(30).sqi, 1);
    });
  });
}
