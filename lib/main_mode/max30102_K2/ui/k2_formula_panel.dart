// ============================================================================
// 公式帶入面板 —— 送給 LLM 的那幾個欄位，逐一列出「公式 → 代入數值 → 結果」
// ============================================================================
//
// 只讀 [VitalsMetrics]，**不自己算任何一個送出去的數字**：
//   · 每一列的 [K2FormulaRow.value] 就是 `toStrapiJson()` 裡同名欄位的值
//     （測試釘住兩者相等）
//   · 代入那一欄是把同一批中間量攤開給人看，例如 SDNN 的 Σ 由
//     `SDNN² × (N − 1)` 反推 —— 與核心算出來的數字是同一份
//
// 所以這個面板不會和左側欄、② 投票表、實際送出的 JSON 對不上。
//
// 更新頻率跟著頁面走：
//   · 滾動模式 —— 頁面每秒重算 metrics，這裡就每秒更新
//   · 定長模式 —— metrics 是凍結窗算好的那一份，收滿後就停在量測結束那一刻
// ============================================================================

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../shared/services/localization_service.dart';
import '../k2_hrv_calculator.dart';
import '../k2_vitals_metrics.dart';
import 'k2_field_help.dart';

/// 一條附註：翻譯 key + 參數（翻譯留給畫面層做，資料層保持可測）。
typedef K2FormulaNote = ({String key, Map<String, dynamic> params});

/// 一個欄位的公式列。
class K2FormulaRow {
  const K2FormulaRow({
    required this.api,
    required this.inputs,
    required this.formula,
    required this.sub,
    required this.value,
    required this.result,
    this.notes = const [],
  });

  /// 送出時的欄位名（`toStrapiJson()` 的 key）。
  final String api;

  /// 這一列由哪些參數帶入（例如 pns ← rmssd）。
  final List<String> inputs;

  /// 公式本體。只用符號，不需要翻譯。
  final String formula;

  /// 代入數值後的式子。null = 沒有可代入的值。
  final String? sub;

  /// 與 `toStrapiJson()[api]` **完全相同**的值（double / String / null）。
  final Object? value;

  /// 顯示用的結果（已四捨五入、帶單位）。
  final String result;

  /// 附註：撞邊、資料不足的原因、名詞說明。
  final List<K2FormulaNote> notes;

  /// 這一列是不是**真的印進 LLM 提示詞**的欄位。
  /// false = 算它們用的中間量，畫面上用淡色區分。
  bool get llm => k2LlmFields.contains(api);
}

/// 對方提示詞實際印出的 8 個欄位（k2-recommend-prompts.ts:364-369）。
/// 其餘的列（lf_ms2 / hf_ms2 / lf / hf / snr_db）是算它們用的中間量。
const k2LlmFields = {
  'mean_hr',
  'sdnn',
  'rmssd',
  'lf_hf',
  'pns',
  'ans',
  'stress',
  'confidence',
};

String _f(double? v, int digits) => v == null ? '—' : v.toStringAsFixed(digits);

/// 由 [m] 組出所有公式列，照計算的依賴順序排。
///
/// [beats] 是這一段的拍數（RR 個數 + 1），只用在「拍數不足」的說明上 ——
/// HRV 還沒算出來時 [VitalsMetrics.hrv] 是 null，拍數得從外面給。
List<K2FormulaRow> k2FormulaRows(VitalsMetrics m, {required int beats}) {
  final hv = m.hrv;
  final spec = m.spectrum;
  final naBeats = <K2FormulaNote>[
    (
      key: 'k2_fx_na_beats',
      params: {'min': Max30102HrvCalculator.minBeatsForHrv, 'n': beats},
    ),
  ];
  K2FormulaNote naDep(String dep) =>
      (key: 'k2_fx_na_dep', params: {'dep': dep});
  K2FormulaNote clampNote(double raw, double v) =>
      (key: 'k2_fx_note_clamp', params: {'raw': _f(raw, 1), 'v': _f(v, 1)});

  final rows = <K2FormulaRow>[];

  // ── mean_hr ──────────────────────────────────────────────────────
  rows.add(
    K2FormulaRow(
      api: 'mean_hr',
      inputs: const ['RR'],
      formula: '60000 / mean(RR)',
      sub: hv == null ? null : '60000 / ${_f(hv.meanRr, 1)} ms',
      value: m.meanHr,
      result: hv == null ? '—' : '${_f(m.meanHr, 1)} bpm',
      notes: hv == null ? naBeats : const [],
    ),
  );

  // ── sdnn ─────────────────────────────────────────────────────────
  // 核心用樣本標準差（N − 1）。Σ 由 SDNN² × (N − 1) 反推，與核心同一份。
  if (hv != null) {
    final n = hv.beats - 1; // RR 間隔數
    final varSum = hv.sdnn * hv.sdnn * (n - 1);
    rows.add(
      K2FormulaRow(
        api: 'sdnn',
        inputs: const ['RR'],
        formula: '√( Σ(RRᵢ − mean)² / (N − 1) )',
        sub: 'N = $n → √( ${_f(varSum, 0)} / ${n - 1} )',
        value: m.sdnn,
        result: '${_f(m.sdnn, 1)} ms',
        notes: const [(key: 'k2_fx_note_sdnn', params: {})],
      ),
    );
  } else {
    rows.add(
      K2FormulaRow(
        api: 'sdnn',
        inputs: const ['RR'],
        formula: '√( Σ(RRᵢ − mean)² / (N − 1) )',
        sub: null,
        value: m.sdnn,
        result: '—',
        notes: naBeats,
      ),
    );
  }

  // ── rmssd ────────────────────────────────────────────────────────
  // 分母只算「時間上相鄰」的兩拍（中間沒有漏拍），所以 P 可能小於 N − 1。
  if (hv != null) {
    final sucSq = hv.rmssd * hv.rmssd * hv.pairs;
    rows.add(
      K2FormulaRow(
        api: 'rmssd',
        inputs: const ['RR'],
        formula: '√( Σ(RRᵢ₊₁ − RRᵢ)² / P )',
        sub: hv.pairs > 0
            ? 'P = ${hv.pairs} → √( ${_f(sucSq, 0)} / ${hv.pairs} )'
            : 'P = 0',
        value: m.rmssd,
        result: '${_f(m.rmssd, 1)} ms',
        notes: [
          (
            key: 'k2_fx_note_rmssd',
            params: {'pairs': hv.pairs, 'total': hv.totalPairs},
          ),
        ],
      ),
    );
  } else {
    rows.add(
      K2FormulaRow(
        api: 'rmssd',
        inputs: const ['RR'],
        formula: '√( Σ(RRᵢ₊₁ − RRᵢ)² / P )',
        sub: null,
        value: m.rmssd,
        result: '—',
        notes: naBeats,
      ),
    );
  }

  // ── lf_ms2 / hf_ms2 ← RR ────────────────────────────────────────
  // 頻帶功率 = 該頻帶內 Lomb-Scargle 週期圖的積分 × k。
  // k 把整條頻譜的積分縮放成 RR 的變異數(= SDNN²),所以三個頻帶加起來
  // 對得上 SDNN² —— 附註把這筆帳攤開,可以直接跟上面的 sdnn 列對。
  // 這兩個**不送給 LLM**,它們只是 lf_hf 的分子分母。
  const naSpec = <K2FormulaNote>[(key: 'k2_fx_na_spec', params: {})];
  String band(double lo, double hi) =>
      'k · Σ P(f)·Δf ,  $lo ≤ f < ${hi.toStringAsFixed(2)} Hz';
  final sdnn = m.sdnn;
  rows.add(
    K2FormulaRow(
      api: 'lf_ms2',
      inputs: const ['RR'],
      formula: band(HrvBands.lfLow, HrvBands.lfHigh),
      sub: spec == null
          ? null
          : 'LFnu = LF / (LF + HF) = ${_f(spec.lfNu, 1)} %',
      value: spec?.lf,
      result: spec == null ? '—' : '${_f(spec.lf, 1)} ms²',
      notes: spec == null
          ? naSpec
          : [
              (
                key: 'k2_fx_note_power',
                params: {
                  'vlf': _f(spec.vlf, 1),
                  'lf': _f(spec.lf, 1),
                  'hf': _f(spec.hf, 1),
                  'total': _f(spec.totalPower, 1),
                  's2': _f(sdnn == null ? null : sdnn * sdnn, 1),
                },
              ),
              (
                key: 'k2_fx_note_lfhf',
                params: {
                  'span': _f(spec.spanSeconds, 1),
                  'cyc': _f(spec.lfCycles, 1),
                },
              ),
              (key: 'k2_fx_note_not_sent', params: {'api': 'lf'}),
            ],
    ),
  );
  rows.add(
    K2FormulaRow(
      api: 'hf_ms2',
      inputs: const ['RR'],
      formula: band(HrvBands.hfLow, HrvBands.hfHigh),
      sub: spec == null
          ? null
          : 'HFnu = HF / (LF + HF) = ${_f(spec.hfNu, 1)} %',
      value: spec?.hf,
      result: spec == null ? '—' : '${_f(spec.hf, 1)} ms²',
      notes: spec == null
          ? naSpec
          : [
              (key: 'k2_fx_note_hf_cyc', params: {'cyc': _f(spec.hfCycles, 1)}),
              (key: 'k2_fx_note_not_sent', params: {'api': 'hf'}),
            ],
    ),
  );

  // ── lf / hf ← lf_ms2 / hf_ms2:換成對方(aquivio-vitals)的單位 ──────
  // 這兩個才是 JSON 裡 `lf` / `hf` 送出的值(左側欄 LF (lf) / HF (hf) 那兩格)。
  //   × 1e-6 :ms² → s²(對方的 RR 用秒)
  //   × 1024 :對方的 Welch 頻譜直接加總各格、沒乘格寬 Δf = 4 / 4096 Hz,
  //            等於多乘了 1/Δf = 1024
  // 係數本身寫在核心(_aquivioScale),這裡只顯示;值一律取核心算好的那一份。
  const scaleText = '× 1e-6 × 1024';
  rows.add(
    K2FormulaRow(
      api: 'lf',
      inputs: const ['lf_ms2'],
      formula: 'lf_ms2 $scaleText',
      sub: spec == null ? null : '${_f(spec.lf, 1)} $scaleText',
      value: spec?.lfAquivio,
      result: spec == null ? '—' : _f(spec.lfAquivio, 3),
      notes: spec == null
          ? naSpec
          : const [(key: 'k2_fx_note_aquivio', params: {})],
    ),
  );
  rows.add(
    K2FormulaRow(
      api: 'hf',
      inputs: const ['hf_ms2'],
      formula: 'hf_ms2 $scaleText',
      sub: spec == null ? null : '${_f(spec.hf, 1)} $scaleText',
      value: spec?.hfAquivio,
      result: spec == null ? '—' : _f(spec.hfAquivio, 3),
      notes: spec == null
          ? naSpec
          : const [(key: 'k2_fx_note_aquivio_hf', params: {})],
    ),
  );

  // ── lf_hf ← lf_ms2, hf_ms2 ──────────────────────────────────────
  rows.add(
    K2FormulaRow(
      api: 'lf_hf',
      inputs: const ['lf_ms2', 'hf_ms2'],
      formula: 'LF / HF',
      sub: spec == null
          ? null
          : '${_f(spec.lf, 1)} ms² / ${_f(spec.hf, 1)} ms²',
      value: m.lfHf,
      result: spec == null ? '—' : _f(m.lfHf, 2),
      notes: spec == null ? naSpec : const [],
    ),
  );

  // ── pns ← rmssd ─────────────────────────────────────────────────
  final pns = m.pnsScore;
  final rmssd = m.rmssd;
  final pnsDen = math.log(80) / math.ln10 - 1.0;
  if (pns != null && rmssd != null) {
    final raw = (math.log(rmssd) / math.ln10 - 1.0) / pnsDen * 100;
    rows.add(
      K2FormulaRow(
        api: 'pns',
        inputs: const ['rmssd'],
        formula: 'clamp( (log₁₀ RMSSD − 1) / (log₁₀ 80 − 1) ) × 100',
        sub:
            '(log₁₀ ${_f(rmssd, 1)} − 1) / ${_f(pnsDen, 4)} × 100 = ${_f(raw, 1)}',
        value: pns,
        result: _f(pns, 1),
        notes: (raw < 0 || raw > 100) ? [clampNote(raw, pns)] : const [],
      ),
    );
  } else {
    rows.add(
      K2FormulaRow(
        api: 'pns',
        inputs: const ['rmssd'],
        formula: 'clamp( (log₁₀ RMSSD − 1) / (log₁₀ 80 − 1) ) × 100',
        sub: null,
        value: pns,
        result: '—',
        notes: [
          (hv != null && hv.pairs == 0)
              ? (key: 'k2_fx_na_pairs', params: <String, dynamic>{})
              : naDep('rmssd'),
        ],
      ),
    );
  }

  // ── ans ← lf_hf ─────────────────────────────────────────────────
  final ans = m.ansScore;
  final lfHf = m.lfHf;
  if (ans != null && lfHf != null) {
    final raw = (0.5 + (math.log(lfHf) / math.ln2) / 4.0) * 100;
    rows.add(
      K2FormulaRow(
        api: 'ans',
        inputs: const ['lf_hf'],
        formula: 'clamp( 0.5 + log₂(LF/HF) / 4 ) × 100',
        sub: '(0.5 + log₂ ${_f(lfHf, 2)} / 4) × 100 = ${_f(raw, 1)}',
        value: ans,
        result: _f(ans, 1),
        notes: (raw < 0 || raw > 100) ? [clampNote(raw, ans)] : const [],
      ),
    );
  } else {
    rows.add(
      K2FormulaRow(
        api: 'ans',
        inputs: const ['lf_hf'],
        formula: 'clamp( 0.5 + log₂(LF/HF) / 4 ) × 100',
        sub: null,
        value: ans,
        result: '—',
        notes: [naDep('lf_hf')],
      ),
    );
  }

  // ── stress ← pns, ans ───────────────────────────────────────────
  final stress = m.stressScore;
  if (stress != null && pns != null && ans != null) {
    final a = 0.6 * (100 - pns);
    final b = 0.4 * ans;
    rows.add(
      K2FormulaRow(
        api: 'stress',
        inputs: const ['pns', 'ans'],
        formula: 'clamp( 0.6 × (100 − PNS) + 0.4 × ANS )',
        sub:
            '0.6 × (100 − ${_f(pns, 1)}) + 0.4 × ${_f(ans, 1)}'
            ' = ${_f(a, 1)} + ${_f(b, 1)}',
        value: stress,
        result: _f(stress, 1),
      ),
    );
  } else {
    rows.add(
      K2FormulaRow(
        api: 'stress',
        inputs: const ['pns', 'ans'],
        formula: 'clamp( 0.6 × (100 − PNS) + 0.4 × ANS )',
        sub: null,
        value: stress,
        result: '—',
        notes: [naDep('pns / ans')],
      ),
    );
  }

  // ── snr_db ← IR 波形 ────────────────────────────────────────────
  // 訊號 / 雜訊兩個功率只活在核心的 snrDb() 內部，沒有導出 ——
  // 要攤開就得改交接核心，所以這一列只列結果。
  final snr = m.snrDb;
  rows.add(
    K2FormulaRow(
      api: 'snr_db',
      inputs: const ['IR', 'bpm'],
      formula: '10 · log₁₀( P_signal / P_noise )',
      sub: null,
      value: snr,
      result: snr == null ? '—' : '${_f(snr, 2)} dB',
      notes: [
        snr == null
            ? (key: 'k2_fx_na_snr', params: <String, dynamic>{})
            : (
                key: 'k2_fx_note_snr',
                params: <String, dynamic>{
                  'hw': Max30102VitalsMetrics.snrPeakHalfwidthHz,
                  'lo': Max30102VitalsMetrics.snrBandLoHz,
                  'hi': Max30102VitalsMetrics.snrBandHiHz,
                },
              ),
      ],
    ),
  );

  // ── confidence ← snr_db ─────────────────────────────────────────
  final good = _f(Max30102VitalsMetrics.snrGoodDb, 0);
  final rough = _f(Max30102VitalsMetrics.snrRoughDb, 0);
  final conf = m.confidenceBySnr;
  rows.add(
    K2FormulaRow(
      api: 'confidence',
      inputs: const ['snr_db'],
      formula:
          '≥ $good dB → good · ≥ $rough dB → rough · < $rough dB → very rough',
      sub: snr == null ? null : 'snr_db = ${_f(snr, 2)} dB',
      value: conf,
      result: conf ?? '—',
      notes: [
        snr == null
            ? naDep('snr_db')
            : (key: 'k2_fx_note_conf', params: <String, dynamic>{}),
      ],
    ),
  );

  return rows;
}

/// 公式帶入面板（全寬）。
class K2FormulaPanel extends StatelessWidget {
  const K2FormulaPanel({
    super.key,
    required this.metrics,
    required this.beats,
    required this.fixedMode,
    required this.seconds,
    this.listenable,
    this.liveRows,
  });

  final VitalsMetrics metrics;
  final int beats;
  final bool fixedMode;
  final int seconds;

  /// 「?」說明視窗開著時要聽的通知來源,與 [liveRows] 一起給。
  /// 不給的話視窗顯示的是按下那一刻的快照。
  final Listenable? listenable;

  /// 重算目前的公式列(視窗每次收到通知就呼叫)。回 null = 現在沒資料,
  /// 視窗停在上一份,不會清空。
  final List<K2FormulaRow>? Function()? liveRows;

  static const _mono = 'Consolas';
  static const double _wField = 108; // 欄位名 + 「?」
  static const double _wInputs = 96;
  static const double _wResult = 96;

  @override
  Widget build(BuildContext context) {
    final rows = k2FormulaRows(metrics, beats: beats);
    final grey = Colors.grey.shade600;
    final head = TextStyle(
      fontSize: 10.5,
      color: grey,
      fontWeight: FontWeight.bold,
    );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                tr('k2_fx_title'),
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${fixedMode ? tr('k2_fx_fixed') : trParams('k2_fx_rolling', {'sec': seconds})}'
                  '　·　${tr('k2_fx_round')}'
                  '　·　${tr('k2_fx_legend')}',
                  style: TextStyle(fontSize: 10.5, color: grey),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // ── 欄名 ──
          Row(
            children: [
              SizedBox(
                width: _wField,
                child: Text(tr('k2_fx_col_field'), style: head),
              ),
              SizedBox(
                width: _wInputs,
                child: Text(tr('k2_fx_col_inputs'), style: head),
              ),
              Expanded(
                flex: 5,
                child: Text(tr('k2_fx_col_formula'), style: head),
              ),
              const SizedBox(width: 8),
              Expanded(flex: 5, child: Text(tr('k2_fx_col_sub'), style: head)),
              SizedBox(
                width: _wResult,
                child: Text(
                  tr('k2_fx_col_result'),
                  style: head,
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
          const Divider(height: 8),
          for (final r in rows) _row(context, r),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, K2FormulaRow r) {
    final grey = Colors.grey.shade600;
    final na = r.value == null;
    // 中間量(不在 LLM 提示詞裡)整列用淡色、結果不加粗 ——
    // 一眼就分得出哪 8 列是 LLM 真正看到的。
    final faint = r.llm ? null : Colors.grey.shade400;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: _wField,
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        r.api,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: _mono,
                          fontSize: 12,
                          fontWeight: r.llm
                              ? FontWeight.bold
                              : FontWeight.normal,
                          color: faint,
                        ),
                      ),
                    ),
                    // 「?」→ 這個欄位的說明視窗(外框同推薦飲品視窗)
                    InkWell(
                      onTap: () => showK2FieldHelp(
                        context,
                        r,
                        listenable: listenable,
                        liveRows: liveRows,
                      ),
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: Icon(
                          Icons.help_outline,
                          size: 14,
                          color: faint ?? Colors.teal.shade600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: _wInputs,
                child: Text(
                  '← ${r.inputs.join(', ')}',
                  style: TextStyle(
                    fontFamily: _mono,
                    fontSize: 11,
                    color: faint ?? Colors.blueGrey.shade400,
                  ),
                ),
              ),
              Expanded(
                flex: 5,
                child: Text(
                  r.formula,
                  style: TextStyle(
                    fontFamily: _mono,
                    fontSize: 11.5,
                    color: faint,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 5,
                child: Text(
                  r.sub ?? '—',
                  style: TextStyle(
                    fontFamily: _mono,
                    fontSize: 11.5,
                    color:
                        faint ?? (r.sub == null ? grey : Colors.teal.shade700),
                  ),
                ),
              ),
              SizedBox(
                width: _wResult,
                child: Text(
                  '= ${r.result}',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontFamily: _mono,
                    fontSize: 12,
                    fontWeight: r.llm ? FontWeight.bold : FontWeight.normal,
                    color: faint ?? (na ? grey : null),
                  ),
                ),
              ),
            ],
          ),
          for (final n in r.notes)
            Padding(
              padding: const EdgeInsets.only(left: _wField + _wInputs, top: 1),
              child: Text(
                n.params.isEmpty ? tr(n.key) : trParams(n.key, n.params),
                style: TextStyle(fontSize: 10.5, color: faint ?? grey),
              ),
            ),
        ],
      ),
    );
  }
}
