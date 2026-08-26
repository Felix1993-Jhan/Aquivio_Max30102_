// 煙霧測試:非交接檔,驗證轉譯後能載入 + 跑出結果。可刪。
const {
  Max30102K2, Max30102Protocol, Max30102RxParser,
  Max30102Config, Max30102SettingLimits, Max30102Signal,
} = require('./index');

let fail = 0;
function ok(cond, msg) { console.log((cond ? '✅' : '❌') + ' ' + msg); if (!cond) fail++; }

// 1) 協定:建 QUERY_FIFO,CS 應通過;主板 CS 比擴充板大 1
const q30 = Max30102Protocol.buildQueryFifo(0x30);
const q31 = Max30102Protocol.buildQueryFifo(0x31);
ok(Max30102Protocol.verifyCs(q30), '主板 QUERY CS 通過');
ok(Max30102Protocol.verifyCs(q31), '擴充板 QUERY CS 通過');
ok(q30[8] - q31[8] === 1, `CS 主板(${q30[8]}) = 擴充板(${q31[8]}) + 1`);
ok(Max30102Protocol.hex(q31) === '40 71 31 09 00 00 00 00 15', 'QUERY 擴充板 hex 正確: ' + Max30102Protocol.hex(q31));

// 2) 協定往返:組一個 FIFO 回應封包(2 組樣本),用 parser 解回來
function buildFifoResponse(board, samples) {
  const body = [0x40, 0x71, board, 0x09, 0x00, samples.length * 6];
  for (const s of samples) {
    body.push(s.red & 0xFF, (s.red >> 8) & 0xFF, (s.red >> 16) & 0x03);
    body.push(s.ir & 0xFF, (s.ir >> 8) & 0xFF, (s.ir >> 16) & 0x03);
  }
  const sum = body.reduce((a, b) => a + b, 0);
  body.push((0x100 - (sum & 0xFF)) & 0xFF);
  return Uint8Array.from(body);
}
const resp = buildFifoResponse(0x31, [{ red: 12345, ir: 90000 }, { red: 12346, ir: 90010 }]);
const decoded = Max30102Protocol.decodeFifoResponse(resp);
ok(decoded.length === 2 && decoded[0].ir === 90000 && decoded[1].ir === 90010,
  `decodeFifoResponse 拆回 2 組: ir=${decoded.map((s) => s.ir)}`);

let parsed = null;
const parser = new Max30102RxParser();
parser.onPacket = (p) => { parsed = p; };
parser.feed(resp);
ok(parsed && parsed.length === resp.length, 'RxParser 收到完整封包');

// 3) 設定監督:hrMax 寫反應被夾
const badCfg = new Max30102Config({ hrMin: 240, hrMax: 30 });
const issues = Max30102SettingLimits.enforce(badCfg);
ok(badCfg.hrMax > badCfg.hrMin, `enforce 修正 hrMax>hrMin (hrMin=${badCfg.hrMin}, hrMax=${badCfg.hrMax})`);
ok(issues.length > 0, `enforce 回報 ${issues.length} 個問題`);

// 4) 端到端:餵合成 75bpm PPG,應跑出接近 75 的心率
const k2 = new Max30102K2();
const fs = 100;
const bpmTrue = 75;
const period = (60 / bpmTrue) * fs; // 80 樣本/拍
let phase = 0;
let lastComputedBpm = null, lastHrv = null, sawSettling = false, sawFinger = false;
// 餵 45 秒,每批 10 筆(模擬 100ms 輪詢)
for (let batch = 0; batch < 450; batch++) {
  const red = [], ir = [];
  for (let i = 0; i < 10; i++) {
    // 谷在相位低點:用 -cos 讓每個週期有明確谷;振幅 ~1500
    const ac = -Math.cos(2 * Math.PI * phase / period) * 1500;
    ir.push(Math.round(90000 + ac));
    red.push(Math.round(12000 + ac * 0.5));
    phase++;
  }
  const r = k2.feedSamples(red, ir);
  if (r.computed) {
    if (r.computed.settling) sawSettling = true;
    if (r.computed.fingerPresent) sawFinger = true;
    if (r.computed.bpm != null) lastComputedBpm = r.computed.bpm;
    if (r.computed.hrv != null) lastHrv = r.computed.hrv;
  }
}
ok(sawSettling, '過程中出現過 settling 狀態');
ok(sawFinger, '偵測到手指');
ok(lastComputedBpm != null, `算出心率: ${lastComputedBpm && lastComputedBpm.toFixed(1)} bpm`);
ok(lastComputedBpm != null && Math.abs(lastComputedBpm - bpmTrue) < 8,
  `心率接近真值 75 (誤差 ${lastComputedBpm != null ? Math.abs(lastComputedBpm - bpmTrue).toFixed(1) : 'N/A'})`);
ok(lastHrv != null, `算出 HRV: rmssd=${lastHrv ? lastHrv.rmssd.toFixed(1) : 'null'} sdnn=${lastHrv ? lastHrv.sdnn.toFixed(1) : 'null'} beats=${lastHrv ? lastHrv.beats : 'null'}`);
ok(k2.totalSamples === 4500, `totalSamples 精確計數: ${k2.totalSamples}`);

// 5) Signal 單元:median 數值排序(JS 陷阱驗證)
ok(Max30102Signal.median([3, 1, 2, 100, 5]) === 3, 'median 數值排序正確(非字典序)');

console.log(fail === 0 ? '\n🎉 全部通過' : `\n⚠️ ${fail} 項失敗`);
process.exit(fail === 0 ? 0 : 1);
