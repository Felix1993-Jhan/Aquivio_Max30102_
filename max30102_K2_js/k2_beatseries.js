// ============================================================================
// Max30102BeatSeries — RR/NN 序列的「過濾器」（有狀態，唯一真相來源）
// ============================================================================
// 【由 Dart 版 k2_beatseries.dart 轉譯,行為完全一致】
//
// 把「谷 → RR → 生理閘門 → 誤拍過濾(_rrAccept) → search-back 補漏 → 累積 NN 序列」
// 收成一個盒子。HRV / HR 都從它取。
//
// 邊界(盒子不擁有這些,只透過「回讀 / 回傳」互動):
//   · irAt(回呼):search-back 要回讀原始 IR 波形時才問一筆(-1=已捲出緩衝)。
//   · feed() 回傳 { rejects, recovered, logs }:這一輪「剔了哪些 / 補回哪些 / log」,
//     由 controller 去施作。盒子不碰 UI。
//   · config(參考):讀 hrMin/hrMax、searchBackEnabled/promRatio/bandLowHz。
// ============================================================================

const { Max30102Config } = require('./k2_config');
const { Max30102HrvCalculator } = require('./k2_hrv_calculator');
const { Max30102Signal } = require('./k2_signal');

/** clamp:對應 Dart num.clamp(lo, hi)。 */
function clamp(x, lo, hi) { return x < lo ? lo : (x > hi ? hi : x); }

class Max30102BeatSeries {
  /// @param {{config, irAt:(absPos:number)=>number, maxBeats?:number}} o
  ///   config:可調參數(運行中可改;持參考安全)。
  ///   irAt:search-back 回讀原始 IR — 給絕對樣本位置,回該筆 IR 值;已捲出緩衝回 -1。
  ///   maxBeats:NN 序列上限(拍數),預設 300。
  constructor({ config, irAt, maxBeats = 300 }) {
    this.config = config;
    this.irAt = irAt;
    this.maxBeats = maxBeats;

    // ── 狀態:唯一一條 NN 序列（平行陣列同步）──
    this._rr = []; // RR(ms)
    this._recovered = []; // 該拍是否為 search-back 補回
    this._startAbs = []; // 每筆起谷絕對位置
    this._endAbs = []; // 每筆終谷絕對位置
    this._lastTroughAbs = -1; // 上一個已轉成 RR 的波谷絕對位置
  }

  // ── 對外讀取（getter；不重算，直接遞出存好的狀態）──
  get rrHistory() { return this._rr; }
  get rrStartAbs() { return this._startAbs; }
  get rrEndAbs() { return this._endAbs; }
  get rrRecovered() { return this._recovered; }

  /// 組成 HrvRrSample 清單餵給純計算模組。
  get samples() {
    const out = [];
    for (let i = 0; i < this._rr.length; i++) {
      out.push({
        rr: this._rr[i],
        startAbs: this._startAbs[i],
        endAbs: this._endAbs[i],
        recovered: this._recovered[i],
      });
    }
    return out;
  }

  /// 乾淨 RR + 起/終谷(含補漏拍)。給 tachogram 折線用。clean 開關關 → 全收。
  rrCleanPts() {
    return Max30102HrvCalculator.clean(this.samples, {
      includeRecovered: true,
      apply: this.config.cleanEnabled,
    });
  }

  /// 乾淨 RR 值(含補漏拍)。
  rrClean() { return this.rrCleanPts().map((e) => e.rr); }

  /// clean() 顯示時剔掉的離群拍(透明化)。clean 關 → 空。
  cleanRejects() {
    return Max30102HrvCalculator.cleanRejects(this.samples, {
      includeRecovered: true,
      apply: this.config.cleanEnabled,
    });
  }

  /// H1(A 階段):疑似異位拍(早搏)—— 純標記,不影響任何 HRV 數字。
  ectopicPts() { return Max30102HrvCalculator.ectopics(this.samples); }

  /// HRV 統計(含補漏拍)。null=拍數不足。
  hrvStats() {
    return Max30102HrvCalculator.stats(this.samples, {
      includeRecovered: true,
      apply: this.config.cleanEnabled,
    });
  }

  /// HRV 統計(排除補漏拍;給「補漏拍 開/關」對照)。
  hrvStatsNoSearchBack() {
    return Max30102HrvCalculator.stats(this.samples, {
      includeRecovered: false,
      apply: this.config.cleanEnabled,
    });
  }

  /// (B 階) 顯示用 HR:取「最近 lastN 拍」的中位 RR → 60000/中位。
  ///   不足 2 拍回 null(交由呼叫端凍結)。與 HRV 同一條 NN 序列。
  hrRecent(lastN) {
    if (this._rr.length < 2) return null;
    const take = this._rr.length < lastN ? this._rr.length : lastN;
    const recent = this._rr.slice(this._rr.length - take).sort((a, b) => a - b);
    const med = recent[Math.trunc(recent.length / 2)];
    return med > 0 ? 60000.0 / med : null;
  }

  /// 全清（重新量測 / 清波形）。
  reset() {
    this._rr.length = 0;
    this._recovered.length = 0;
    this._startAbs.length = 0;
    this._endAbs.length = 0;
    this._lastTroughAbs = -1;
  }

  /// 只斷「連續性基準」,不清歷史（手指離開 → 下一 RR 不要跨斷層）。
  markDiscontinuity() { this._lastTroughAbs = -1; }

  /// 把「比上次更新」的波谷轉成 RR,累積進序列。
  /// 整輪 sqiOk=false → 該輪新谷「消化不記」(記一筆 SQI差 篩除)。
  /// 回傳 { rejects, recovered, logs }。
  feed(peakAbsNew, sqiOk) {
    const fs = Max30102Config.samplingRateHz;
    const rejects = [];
    const recovered = [];
    const logs = [];

    for (const abs of peakAbsNew) {
      if (abs <= this._lastTroughAbs) continue; // 已處理過
      // H2:預設「量完就把量尺起點往前移」。只有「過短側被剔」例外(偽谷不推進基準)。
      let advance = true;
      if (this._lastTroughAbs >= 0 && sqiOk) {
        const rr = (abs - this._lastTroughAbs) * 1000.0 / fs; // ms
        // ── search-back 補漏拍 ──
        if (this.config.searchBackEnabled &&
          this._rr.length + 1 >= Max30102HrvCalculator.minBeatsForHrv) {
          const med = this._recentMedianRr();
          if (med > 0 && rr > 1.6 * med) {
            const rec = this._searchBackFill(this._lastTroughAbs, abs, med);
            if (rec.length > 0) {
              let prev = this._lastTroughAbs;
              for (const t of [...rec, abs]) {
                // 整段 gap 都靠補漏拍才存在 → 全標 recovered
                this._push((t - prev) * 1000.0 / fs, {
                  recovered: true, startAbs: prev, endAbs: t,
                });
                prev = t;
              }
              recovered.push(...rec);
              this._lastTroughAbs = abs;
              logs.push(`🔁 補漏拍：gap ${rr.toFixed(0)}ms 補回 ${rec.length} 拍`);
              continue;
            }
          }
        }
        // 生理閘門 + 誤拍過濾。剔除時分「短側(偽谷/多抓)」與「長側(疑似漏拍)」。
        const rrMinMs = 60000.0 / this.config.hrMax; // 最快心跳 → 最短 RR
        const rrMaxMs = 60000.0 / this.config.hrMin; // 最慢心跳 → 最長 RR
        if (rr < rrMinMs) {
          rejects.push({ absIndex: abs, rr, reason: '生理閘門' });
          advance = false; // 過短=偽谷/多抓 → 基準不推進
        } else if (rr > rrMaxMs) {
          rejects.push({ absIndex: abs, rr, reason: '生理閘門' });
          // 過長=疑似漏拍 → advance 維持 true，resync
        } else if (!this._rrAccept(rr)) {
          rejects.push({ absIndex: abs, rr, reason: '誤拍>40%' });
          const med = this._recentRrMedian();
          if (med > 0 && rr < med) advance = false; // 短側=偽谷 → 基準不推進
        } else {
          this._push(rr, { startAbs: this._lastTroughAbs, endAbs: abs });
        }
      } else if (this._lastTroughAbs >= 0 && !sqiOk) {
        // 整輪 SQI 差 → 這個谷消化不記,回報一筆篩除供研究
        rejects.push({
          absIndex: abs,
          rr: (abs - this._lastTroughAbs) * 1000.0 / fs,
          reason: 'SQI差',
        });
      }
      // H2:偽谷(短側剔)不推進量尺;正常拍/漏拍(長側)/初始/SQI差 照舊推進 resync。
      if (advance) this._lastTroughAbs = abs;
    }
    return { rejects, recovered, logs };
  }

  /// 推一筆 RR（與 recovered/起谷/終谷 同步），維持上限 maxBeats。
  _push(rr, { recovered = false, startAbs, endAbs }) {
    this._rr.push(rr);
    this._recovered.push(recovered);
    this._startAbs.push(startAbs);
    this._endAbs.push(endAbs);
    while (this._rr.length > this.maxBeats) {
      this._rr.shift();
      this._recovered.shift();
      this._startAbs.shift();
      this._endAbs.shift();
    }
  }

  /// **照時間裁** —— 丟掉「終谷早於 minEndAbs」的舊拍。
  /// 由控制層每輪呼叫,把池子維持在 config.dataHistoryMs(預設 30 秒)之內。
  trimOlderThan(minEndAbs) {
    let drop = 0;
    while (drop < this._endAbs.length && this._endAbs[drop] < minEndAbs) drop++;
    if (drop <= 0) return;
    this._rr.splice(0, drop);
    this._recovered.splice(0, drop);
    this._startAbs.splice(0, drop);
    this._endAbs.splice(0, drop);
  }

  /// 最近 9 拍「乾淨(非補漏拍)」RR 的中位數(0=乾淨拍不足)。給 search-back 判 gap。
  _recentMedianRr() {
    const clean = [];
    for (let i = 0; i < this._rr.length; i++) {
      if (!this._recovered[i]) clean.push(this._rr[i]);
    }
    if (clean.length < 4) return 0; // 乾淨拍不足 → 不啟動補漏拍
    const recent = clean.slice(Math.max(0, clean.length - 9));
    const s = [...recent].sort((a, b) => a - b);
    return s[Math.trunc(s.length / 2)];
  }

  /// 誤拍過濾:新 RR 與「最近 9 拍中位數」相差 > 40% → 視為漏拍/多抓,不納入。
  _rrAccept(rr) {
    const med = this._recentRrMedian();
    if (med <= 0) return true; // 起步 <3 拍或基準無效 → 全收(HRV 靠暖機把關)
    return Math.abs(rr - med) / med <= 0.40;
  }

  /// 誤拍過濾用的「近 9 拍中位數」(0 = 拍數不足<3 或基準無效)。
  _recentRrMedian() {
    if (this._rr.length < 3) return 0; // 基準不足
    const recent = this._rr.slice(Math.max(0, this._rr.length - 9));
    const sorted = [...recent].sort((a, b) => a - b);
    const med = sorted[Math.trunc(sorted.length / 2)];
    return med > 0 ? med : 0;
  }

  /// search-back:在 [prevAbs, curAbs] 這段(疑似漏拍 gap) 用放寬門檻找回真實波谷。
  /// 回傳補回的波谷絕對位置(遞增);找不到或切出的 RR 不合理 → 回空(不造假)。
  _searchBackFill(prevAbs, curAbs, medRr) {
    const fs = Max30102Config.samplingRateHz;
    const cap = this.config.dataHistorySamples; // gap 不可能超過核心保留的長度
    const n = curAbs - prevAbs + 1;
    if (n < 6 || n > cap) return [];
    const seg = new Array(n).fill(0);
    for (let i = 0; i < n; i++) {
      const v = this.irAt(prevAbs + i);
      if (v < 0) return []; // 已捲出緩衝,放棄
      seg[i] = v;
    }
    // 去趨勢 → 把谷翻成峰(base − seg),用放寬的 prominence 門檻找
    const base = Max30102Signal.movingAverage(seg, Math.round(fs / this.config.bandLowHz));
    const neg = new Array(n);
    for (let i = 0; i < n; i++) neg[i] = base[i] - seg[i];
    const minDist = clamp(Math.round((medRr * 0.5) * fs / 1000), 3, n);
    const relax = clamp(this.config.promRatio * 0.4, 0.05, 0.5);
    const found = Max30102Signal.findProminentPeaks(neg, minDist, relax);
    // 只收「嚴格落在 gap 內(避開兩端)」的谷
    const margin = Math.round((medRr * 0.4) * fs / 1000);
    const recovered = [];
    for (const k of found) {
      if (k > margin && k < n - margin) recovered.push(prevAbs + k);
    }
    recovered.sort((a, b) => a - b);
    if (recovered.length === 0) return [];
    // 補回數上限:gap ≈ N×median 最多只能有 N−1 個漏拍;抓到更多 = 誤抓 → 整批不採用。
    const rrMs = (curAbs - prevAbs) * 1000.0 / fs;
    const maxRecover = Math.round(rrMs / medRr) - 1;
    if (maxRecover < 1 || recovered.length > maxRecover) return [];
    // 驗證:插入後每段 RR 都要落在 [0.6,1.5]×med,否則整批不採用(寧缺勿假)
    const pts = [prevAbs, ...recovered, curAbs];
    for (let i = 1; i < pts.length; i++) {
      const seg2 = (pts[i] - pts[i - 1]) * 1000.0 / fs;
      if (seg2 < 0.6 * medRr || seg2 > 1.5 * medRr) return [];
    }
    return recovered;
  }
}

module.exports = { Max30102BeatSeries };
