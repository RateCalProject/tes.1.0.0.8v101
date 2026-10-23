/* ===== 風の芽経済組：国土（2Dの地図） =====
   - 企業 →「国土」で開く（index.html から MapApp.open）。地形はチャンク（64×64マス）ごとにサーバーから読む。遠くから見るときは overview.png
   - 地形はなめらかに描く（マスの中心の値をなめらかにつないで、水と陸の境目を 0.5 で切る）。道路・線路はなめらかな曲線
   - 道具：見る（住所など）・土地（買う・売る・建物）・線路・道路（点をおいて曲線をひく・直す）・駅・車庫・こわす
   - 車両・系統・ダイヤ・お金・管理は、下の「≡」から
   - サーバーの関数：mp_boot・mp_chunk_get・mp_area・mp_poll・mp_tile・mp_land_*・mp_seg_*・mp_sta_*・mp_dep_*・mp_bld・mp_car_*・mp_form_*・mp_route_*・mp_train_*・mp_dia・mp_ledger_page・mp_admin_* */
(function () {
'use strict';
const PAL = window.MapPal;
const CS = 64, B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
const B64I = (() => { const m = new Int8Array(128); for (let i = 0; i < 64; i++) m[B64.charCodeAt(i)] = i; return m; })();
const edec = l => l <= 7 ? -187.5 + l * 25 : l <= 32 ? (l - 8) * 4 + 2 : l <= 48 ? 112.5 + (l - 33) * 25 : 575 + (l - 49) * 150;
const EDEC = Float32Array.from({ length: 64 }, (_, i) => edec(i));
const clamp = (v, a, b) => v < a ? a : v > b ? b : v;
const now = () => performance.now();
const T = s => (typeof tr === 'function' ? tr(s) : s);
const SEP = () => (window.I18N && !/^zh/.test(I18N.lang) ? ' ' : '');   // 訳した文をつなぐとき（日本語・中国語は空白なし）
const X = n => fmt(n) + ' X';

/* ---------- 状態 ---------- */
const S = {
  open: false, root: null, wrap: null, cv: null, ctx: null, W: 0, H: 0, dpr: 1,
  cam: { x: 0, y: 0, z: 3 }, dirty: true,
  boot: null, as: 'me', admin: false,
  chunks: new Map(), pend: new Set(), chunkQ: [], chunkBusy: 0,
  cho: new Map(), choPend: new Set(), choQ: [], choBusy: 0,   // 町字（チャンクごと：k・kp・kq）
  cells: new Map(), cellBusy: 0, ver: 0, pollT: 0,
  ov: null, ovInfo: null,
  layer: { zone: false, own: true, label: true },
  b25: true,   // 建物を 2.5D（高さのある見えかた）で描く。false なら 2D（上から見たまま）
  tool: 'look', toolState: null,
  sel: null,          // えらんだもの（{kind, id, ...}）
  hover: null,
  routeHi: null,      // 地図でめだたせる系統
};
window.MP_STATE = S;   // テスト用

/* ---------- カメラ ---------- */
const sx = x => (x - S.cam.x) * S.cam.z + S.W / 2;
const sy = y => (y - S.cam.y) * S.cam.z + S.H / 2;
const wx = px => (px - S.W / 2) / S.cam.z + S.cam.x;
const wy = py => (py - S.H / 2) / S.cam.z + S.cam.y;
function view() { return { x0: wx(0), y0: wy(0), x1: wx(S.W), y1: wy(S.H) }; }
function setCam(x, y, z) {
  S.cam.z = clamp(z, 0.18, 64);
  const w = S.boot && S.boot.world;
  if (w && w.cx1 >= w.cx0) { S.cam.x = clamp(x, w.cx0 * CS, (w.cx1 + 1) * CS); S.cam.y = clamp(y, w.cy0 * CS, (w.cy1 + 1) * CS); }
  else { S.cam.x = x; S.cam.y = y; }
  S.dirty = true; saveCam();
}
function saveCam() { try { localStorage.setItem('mp_cam', JSON.stringify([Math.round(S.cam.x * 10) / 10, Math.round(S.cam.y * 10) / 10, Math.round(S.cam.z * 100) / 100])); } catch (e) {} }
function loadCam() { try { const c = JSON.parse(localStorage.getItem('mp_cam')); if (Array.isArray(c) && c.length === 3 && c.every(Number.isFinite)) { S.cam.x = c[0]; S.cam.y = c[1]; S.cam.z = c[2]; } } catch (e) {} }

/* ---------- チャンク（地形） ---------- */
const ckey = (cx, cy) => cx + ',' + cy;
function inWorld(cx, cy) { const w = S.boot && S.boot.world; return w && cx >= w.cx0 && cx <= w.cx1 && cy >= w.cy0 && cy <= w.cy1; }
// マスの地形（読んでいなければ null）。ない（深い海の）チャンクは D
function tileAt(x, y) {
  const cx = Math.floor(x / CS), cy = Math.floor(y / CS), c = S.chunks.get(ckey(cx, cy));
  if (!c) return null;
  if (c.sea) return { t: 'D', e: -190, z: '-' };
  const k = (y - cy * CS) * CS + (x - cx * CS);
  return { t: c.t[k], e: EDEC[B64I[c.e.charCodeAt(k)]], z: c.zo && c.zo.has(k) ? c.zo.get(k) : c.z[k], a: c.ap[B64I[c.a.charCodeAt(k)]] };
}
function needChunks() {
  if (S.cam.z < 1.2) return;
  const v = view(), cx0 = Math.floor(v.x0 / CS) - 1, cy0 = Math.floor(v.y0 / CS) - 1, cx1 = Math.floor(v.x1 / CS) + 1, cy1 = Math.floor(v.y1 / CS) + 1;
  const want = [];
  for (let cy = cy0; cy <= cy1; cy++) for (let cx = cx0; cx <= cx1; cx++) {
    const k = ckey(cx, cy);
    if (!inWorld(cx, cy) || S.chunks.has(k) || S.pend.has(k)) continue;
    want.push([cx, cy, (cx * CS + 32 - S.cam.x) ** 2 + (cy * CS + 32 - S.cam.y) ** 2]);
  }
  want.sort((a, b) => a[2] - b[2]);
  for (const [cx, cy] of want) { S.pend.add(ckey(cx, cy)); S.chunkQ.push([cx, cy]); }
  pumpChunks();
}
async function pumpChunks() {
  while (S.chunkBusy < 2 && S.chunkQ.length) {
    const batch = S.chunkQ.splice(0, 32), keys = [];
    for (const [cx, cy] of batch) keys.push(cx, cy);
    S.chunkBusy++;
    call('mp_chunk_get', { p_keys: keys }).then(rows => {
      const got = new Set();
      for (const c of rows) {
        const k = ckey(c.cx, c.cy); got.add(k);
        S.chunks.set(k, { cx: c.cx, cy: c.cy, t: c.t, e: c.e, z: c.z, a: c.a, ap: c.ap, apx: c.apx || [], zo: zoMap(c), lo: null, hi: null, zc: null, bnd: null, used: now() });
      }
      for (const [cx, cy] of batch) {
        const k = ckey(cx, cy); S.pend.delete(k);
        if (!got.has(k)) S.chunks.set(k, { cx, cy, sea: true, used: now() });
        // となりの絵をつくりなおす（境目をなめらかに）。境界線も
        for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1], [1, 1], [-1, -1], [1, -1], [-1, 1]]) { const n = S.chunks.get(ckey(cx + dx, cy + dy)); if (n && !n.sea) { n.hi = null; n.bnd = null; } }
      }
      S.dirty = true;
    }).catch(e => { for (const [cx, cy] of batch) S.pend.delete(ckey(cx, cy)); console.warn(e); })
      .finally(() => { S.chunkBusy--; pumpChunks(); });
  }
}
/* ---------- 町字（境界線と名前）：近いときだけ読む ---------- */
function needCho() {
  if (S.cam.z < 2.5) return;
  const v = view(), cx0 = Math.floor(v.x0 / CS), cy0 = Math.floor(v.y0 / CS), cx1 = Math.floor(v.x1 / CS), cy1 = Math.floor(v.y1 / CS);
  const want = [];
  for (let cy = cy0; cy <= cy1; cy++) for (let cx = cx0; cx <= cx1; cx++) {
    const k = ckey(cx, cy), c = S.chunks.get(k);
    if (!c || c.sea || S.cho.has(k) || S.choPend.has(k)) continue;
    want.push([cx, cy, (cx * CS + 32 - S.cam.x) ** 2 + (cy * CS + 32 - S.cam.y) ** 2]);
  }
  want.sort((a, b) => a[2] - b[2]);
  for (const [cx, cy] of want) { S.choPend.add(ckey(cx, cy)); S.choQ.push([cx, cy]); }
  pumpCho();
}
function pumpCho() {
  while (S.choBusy < 2 && S.choQ.length) {
    const batch = S.choQ.splice(0, 16), keys = [];
    for (const [cx, cy] of batch) keys.push(cx, cy);
    S.choBusy++;
    call('mp_cho_get', { p_keys: keys }).then(rows => {
      const got = new Set();
      for (const c of rows) { const k = ckey(c.cx, c.cy); got.add(k); S.cho.set(k, { k: c.k, kp: c.kp, kq: c.kq }); }
      for (const [cx, cy] of batch) {
        const k = ckey(cx, cy); S.choPend.delete(k);
        if (!got.has(k)) S.cho.set(k, { none: true });
        for (const [dx, dy] of [[0, 0], [-1, 0], [0, -1]]) { const n = S.chunks.get(ckey(cx + dx, cy + dy)); if (n) n.bnd = null; }
      }
      S.dirty = true;
    }).catch(e => { for (const [cx, cy] of batch) S.choPend.delete(ckey(cx, cy)); console.warn(e); })
      .finally(() => { S.choBusy--; pumpCho(); });
  }
}
// マスの区域・町字（境界線用）。i, j はチャンクの中（はみ出したらとなりのチャンク）
function bndTile(c, i, j) {
  let cc = c, ii = i, jj = j;
  if (i >= CS || j >= CS) { cc = S.chunks.get(ckey(c.cx + (i >= CS ? 1 : 0), c.cy + (j >= CS ? 1 : 0))); ii = i % CS; jj = j % CS; if (!cc) return null; }
  if (cc.sea) return { sea: true };
  const k = jj * CS + ii, ai = B64I[cc.a.charCodeAt(k)], t = cc.t[k];
  const ch = S.cho.get(ckey(cc.cx, cc.cy));
  let cho = null, dist = null;
  if (ch && !ch.none) { const ix = B64I[ch.k.charCodeAt(2 * k)] * 64 + B64I[ch.k.charCodeAt(2 * k + 1)]; cho = ch.kp[ix] || null; dist = ch.kq[ix] || null; }
  const ax = cc.apx[ai] || [];
  return { sea: t === 'S' || t === 'D', area: cc.ap[ai], muni: ax[0] || '', pref: ax[1] || '', cho, dist, choOk: !!ch };
}
// 境界線（チャンクごと）：県・市町村・区・町（大字）・丁目（字）。マスの辺で、ちがうところに線
const BND_LV = ['pref', 'muni', 'ward', 'dist', 'sub'];
function chunkBnd(c) {
  const out = { pref: [], muni: [], ward: [], dist: [], sub: [] };
  const lv = (a, b) => {
    if (!a || !b || (a.sea && b.sea)) return null;
    if (a.sea || b.sea) return null;
    if (a.area !== b.area) return a.pref !== b.pref ? 'pref' : a.muni !== b.muni ? 'muni' : 'ward';
    if (!a.choOk || !b.choOk || !a.cho || !b.cho || a.cho === b.cho) return null;
    return a.dist !== b.dist ? 'dist' : 'sub';
  };
  const x0 = c.cx * CS, y0 = c.cy * CS;
  // たての辺（i と i+1 のあいだ）：同じ種類が続くところはつなぐ
  for (let i = 0; i < CS; i++) {
    let run = null, rs = 0;
    for (let j = 0; j <= CS; j++) {
      const l = j < CS ? lv(bndTile(c, i, j), bndTile(c, i + 1, j)) : null;
      if (l !== run) { if (run) out[run].push(x0 + i + 1, y0 + rs, x0 + i + 1, y0 + j); run = l; rs = j; }
    }
  }
  // よこの辺（j と j+1 のあいだ）
  for (let j = 0; j < CS; j++) {
    let run = null, rs = 0;
    for (let i = 0; i <= CS; i++) {
      const l = i < CS ? lv(bndTile(c, i, j), bndTile(c, i, j + 1)) : null;
      if (l !== run) { if (run) out[run].push(x0 + rs, y0 + j + 1, x0 + i, y0 + j + 1); run = l; rs = i; }
    }
  }
  return out;
}
function zoMap(c) {
  if (!c.zo || !c.zo.length) return null;
  const m = new Map();
  for (const [x, y, z] of c.zo) m.set((y - c.cy * CS) * CS + (x - c.cx * CS), z);
  return m;
}
// 古いチャンクの絵をすてる（メモリ）
function trimChunks() {
  const hi = [...S.chunks.values()].filter(c => c.hi);
  if (hi.length > 160) { hi.sort((a, b) => a.used - b.used); for (const c of hi.slice(0, hi.length - 160)) c.hi = null; }
  if (S.chunks.size > 2600) {
    const all = [...S.chunks.entries()].sort((a, b) => a[1].used - b[1].used);
    for (const [k] of all.slice(0, S.chunks.size - 2200)) S.chunks.delete(k);
  }
  if (S.cho.size > 900) for (const k of [...S.cho.keys()]) if (!S.chunks.has(k)) S.cho.delete(k);
}
// 1マス1点の絵（遠いとき）
function chunkLo(c) {
  const cv = document.createElement('canvas'); cv.width = cv.height = CS;
  const g = cv.getContext('2d'), im = g.createImageData(CS, CS), d = im.data;
  for (let j = 0; j < CS; j++) for (let i = 0; i < CS; i++) {
    const k = j * CS + i, t = c.t[k], e = EDEC[B64I[c.e.charCodeAt(k)]], z = c.zo && c.zo.has(k) ? c.zo.get(k) : c.z[k];
    const kn = Math.max(0, j - 1) * CS + Math.max(0, i - 1), en = EDEC[B64I[c.e.charCodeAt(kn)]];
    const col = PAL.tileColor(t, e, z, (e - en) / 1.4);
    d[k * 4] = col[0]; d[k * 4 + 1] = col[1]; d[k * 4 + 2] = col[2]; d[k * 4 + 3] = 255;
  }
  g.putImageData(im, 0, 0); return cv;
}
// なめらかな絵（近いとき）：1マスを Q 点に。海・湖かどうかを（3×3 でならしてから）なめらかにつないで 0.5 で切る
//   川はここでは陸として描き、上から川の線（worldgen の川のまん中の線）を描く
const Q = 4;
function chunkHi(c) {
  const N = CS, M = N + 2, M2 = N + 4, size = N * Q;
  const raw = new Float32Array(M2 * M2), Rr = new Float32Array(M2 * M2), Rg = new Float32Array(M2 * M2), Rb = new Float32Array(M2 * M2), Re = new Float32Array(M2 * M2);
  const Wt = new Float32Array(M * M), Et = new Float32Array(M * M), Cr = new Float32Array(M * M), Cg = new Float32Array(M * M), Cb = new Float32Array(M * M), Lw = new Uint8Array(M * M);
  const x0 = c.cx * CS, y0 = c.cy * CS;
  const own = (i, j) => { const ii = clamp(i, 0, N - 1), jj = clamp(j, 0, N - 1), k = jj * N + ii; return { t: c.t[k], e: EDEC[B64I[c.e.charCodeAt(k)]], z: c.zo && c.zo.has(k) ? c.zo.get(k) : c.z[k] }; };
  const get = (i, j) => (i >= 0 && j >= 0 && i < N && j < N) ? own(i, j) : (tileAt(x0 + i, y0 + j) || own(i, j));
  for (let j = -2; j <= N + 1; j++) for (let i = -2; i <= N + 1; i++) {
    const q = get(i, j), k2 = (j + 2) * M2 + (i + 2);
    raw[k2] = q.t === 'D' || q.t === 'S' || q.t === 'L' ? 1 : 0;
    let t = q.t;
    if (t === 'R') t = q.e > 300 ? 'H' : 'P';                                   // 川のマスは陸の色（川は線で描く）
    const col = PAL.tileColor(t, q.e, q.t === 'R' ? '-' : q.z, 0);
    Rr[k2] = col[0]; Rg[k2] = col[1]; Rb[k2] = col[2]; Re[k2] = Math.max(0, q.e);
  }
  // 3×3 でならす（海岸がなめらかに・色の境目もやわらかく。色は水どうし・陸どうしだけでまぜる）
  const KW = [1, 2, 1, 2, 4, 2, 1, 2, 1];
  for (let j = 0; j < M; j++) for (let i = 0; i < M; i++) {
    const c0 = (j + 1) * M2 + (i + 1), self = raw[c0];
    let w = 0, sr = 0, sg = 0, sb = 0, sw = 0, n = 0, se = 0;
    for (let b = -1; b <= 1; b++) for (let a = -1; a <= 1; a++) {
      const k2 = c0 + b * M2 + a, kw = KW[n++];
      w += kw * raw[k2]; se += kw * Re[k2];
      if (raw[k2] === self) { sw += kw; sr += kw * Rr[k2]; sg += kw * Rg[k2]; sb += kw * Rb[k2]; }
    }
    const k = j * M + i;
    Wt[k] = w / 16; Lw[k] = self; Cr[k] = sr / sw; Cg[k] = sg / sw; Cb[k] = sb / sw; Et[k] = se / 16;
  }
  const cv = document.createElement('canvas'); cv.width = cv.height = size;
  const g = cv.getContext('2d'), im = g.createImageData(size, size), d = im.data;
  for (let py = 0; py < size; py++) {
    const v = (py + 0.5) / Q - 0.5, j0 = Math.floor(v), fy = v - j0;
    for (let px = 0; px < size; px++) {
      const u = (px + 0.5) / Q - 0.5, i0 = Math.floor(u), fx = u - i0;
      const k00 = (j0 + 1) * M + (i0 + 1), k10 = k00 + 1, k01 = k00 + M, k11 = k01 + 1;
      const a00 = (1 - fx) * (1 - fy), a10 = fx * (1 - fy), a01 = (1 - fx) * fy, a11 = fx * fy;
      const w = Wt[k00] * a00 + Wt[k10] * a10 + Wt[k01] * a01 + Wt[k11] * a11;
      const water = w >= 0.5;
      // 同じ側（水か陸か）のマスだけで色をまぜる
      let s = 0, r = 0, gg = 0, b = 0;
      const add = (k, a) => { if ((Lw[k] > 0) === water && a > 0) { s += a; r += Cr[k] * a; gg += Cg[k] * a; b += Cb[k] * a; } };
      add(k00, a00); add(k10, a10); add(k01, a01); add(k11, a11);
      if (s <= 0) { if (water) { r = 112; gg = 170; b = 220; } else { r = Cr[k00]; gg = Cg[k00]; b = Cb[k00]; } s = 1; }
      else { r /= s; gg /= s; b /= s; }
      if (!water) {
        const ex = (Et[k10] - Et[k00]) * (1 - fy) + (Et[k11] - Et[k01]) * fy, ey = (Et[k01] - Et[k00]) * (1 - fx) + (Et[k11] - Et[k10]) * fx;
        const sh = 1 + clamp(-(ex + ey) * 0.012, -0.3, 0.3);
        r *= sh; gg *= sh; b *= sh;
        if (w > 0.4) { const f = (w - 0.4) / 0.1 * 0.2; r = r * (1 - f) + 120 * f; gg = gg * (1 - f) + 140 * f; b = b * (1 - f) + 150 * f; }   // 岸のふち
      } else if (w < 0.6) { const f = (0.6 - w) / 0.1 * 0.18; r = r * (1 - f) + 240 * f; gg = gg * (1 - f) + 248 * f; b = b * (1 - f) + 255 * f; }      // 水ぎわ
      const o = (py * size + px) * 4;
      d[o] = r; d[o + 1] = gg; d[o + 2] = b; d[o + 3] = 255;
    }
  }
  g.putImageData(im, 0, 0); return cv;
}
/* ---------- 川（worldgen.js の川のまん中の線から。256マスごとにまとめて計算） ---------- */
let WG = null;
const RIV = new Map();
function riversCell(i, j) {
  const k = i + ',' + j; let r = RIV.get(k); if (r) return r;
  r = [];
  if (!WG && window.MapGen) WG = MapGen.world();
  if (WG) {
    const x0 = i * 256 - 3, y0 = j * 256 - 3, x1 = (i + 1) * 256 + 3, y1 = (j + 1) * 256 + 3, SQ = Math.SQRT1_2;
    const vs = [(x0 - y0) * SQ, (x1 - y0) * SQ, (x0 - y1) * SQ, (x1 - y1) * SQ], us = [(x0 + y0) * SQ, (x1 + y0) * SQ, (x0 + y1) * SQ, (x1 + y1) * SQ];
    const vmin = Math.min(...vs), vmax = Math.max(...vs), umin = Math.min(...us), umax = Math.max(...us);
    for (let kk = Math.floor(vmin / WG.RS) - 4; kk <= Math.ceil(vmax / WG.RS) + 4; kk++) {
      const main = WG.river(kk);
      for (const rv of [main, ...main.tribs]) {
        const sA = Math.max(rv.s0 - 4, rv.cu - umax - 2), sB = Math.min(rv.s1, rv.cu - umin + 2);
        if (sB <= sA) continue;
        let cur = null;
        for (let s2 = Math.floor(sA); s2 <= sB + 1; s2 += 1) {
          const ss = Math.min(s2, sB), v = WG.riverV(rv, ss), u = rv.cu - ss, x = (u + v) * SQ, y = (u - v) * SQ;
          if (x >= x0 && x <= x1 && y >= y0 && y <= y1) {
            if (!cur) { cur = { pts: [], w: [] }; r.push(cur); }
            cur.pts.push(x + 0.5, y + 0.5); cur.w.push(WG.riverW(rv, ss) + 0.45);
          } else cur = null;
          if (ss >= sB) break;
        }
      }
    }
  }
  RIV.set(k, r);
  if (RIV.size > 400) RIV.delete(RIV.keys().next().value);
  return r;
}
// 用途地域の層
function chunkZone(c) {
  const cv = document.createElement('canvas'); cv.width = cv.height = CS;
  const g = cv.getContext('2d'), im = g.createImageData(CS, CS), d = im.data;
  for (let k = 0; k < CS * CS; k++) {
    const z = c.zo && c.zo.has(k) ? c.zo.get(k) : c.z[k], col = PAL.ZC[z];
    if (!col) continue;
    d[k * 4] = col[0]; d[k * 4 + 1] = col[1]; d[k * 4 + 2] = col[2]; d[k * 4 + 3] = 120;
  }
  g.putImageData(im, 0, 0); return cv;
}

/* ---------- 地図の上のもの（道路・線路・駅など）：範囲（セル）ごとに読む ---------- */
// ズームで細かさ（lod）とセルの大きさを決める
function lodOf(z) { return z < 2 ? [2, 1024] : z < 7 ? [1, 384] : [0, 96]; }
function needCells() {
  const [lod, cs] = lodOf(S.cam.z), v = view();
  const i0 = Math.floor(v.x0 / cs), j0 = Math.floor(v.y0 / cs), i1 = Math.floor(v.x1 / cs), j1 = Math.floor(v.y1 / cs);
  const want = [];
  for (let j = j0; j <= j1; j++) for (let i = i0; i <= i1; i++) {
    const k = lod + ':' + i + ',' + j, c = S.cells.get(k);
    if (c && (c.busy || !c.stale)) { if (c) c.used = now(); continue; }
    want.push([k, i, j, ((i + 0.5) * cs - S.cam.x) ** 2 + ((j + 0.5) * cs - S.cam.y) ** 2]);
  }
  want.sort((a, b) => a[3] - b[3]);
  for (const [k, i, j] of want) {
    if (S.cellBusy >= 3) break;
    const old = S.cells.get(k);
    const c = old || { lod, i, j, cs, data: null };
    c.busy = true; c.stale = false; c.used = now(); S.cells.set(k, c);
    S.cellBusy++;
    call('mp_area', { p_x0: i * cs, p_y0: j * cs, p_x1: (i + 1) * cs, p_y1: (j + 1) * cs, p_lod: lod })
      .then(d => { prepArea(d); c.data = d; if (d.ver > S.ver && !S.ver) S.ver = d.ver; S.dirty = true; })
      .catch(e => { c.stale = true; console.warn(e); })
      .finally(() => { c.busy = false; S.cellBusy--; if (S.open) needCells(); });
  }
  if (S.cells.size > 500) {
    const all = [...S.cells.entries()].filter(e => !e[1].busy).sort((a, b) => a[1].used - b[1].used);
    for (const [k] of all.slice(0, S.cells.size - 400)) S.cells.delete(k);
  }
}
// 線を描きやすく（点をマスの小数に）
function prepSeg(s) {
  const p = s.p, n = p.length / 2, P = new Float32Array(p.length);
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (let i = 0; i < p.length; i += 2) { const x = p[i] / 100, y = p[i + 1] / 100; P[i] = x; P[i + 1] = y; if (x < x0) x0 = x; if (y < y0) y0 = y; if (x > x1) x1 = x; if (y > y1) y1 = y; }
  s.P = P; s.bb = [x0, y0, x1, y1]; s.np = n;
  return s;
}
// 読んだものを描きやすく
function prepArea(d) {
  for (const s of d.segs) prepSeg(s);
  for (const s of d.stas) { s.fx = s.x / 100; s.fy = s.y / 100; }
  for (const s of d.deps) { s.fx = s.x / 100; s.fy = s.y / 100; }
  for (const n of d.nodes) { n.fx = n.x / 100; n.fy = n.y / 100; }
  d.parcels = (d.parcels || []).map(prepParcel);
  d.blds = (d.blds || []).map(prepBld);
  d.chos = d.chos || [];
}
// 筆：[id, [y, x0, x1, …], 1 他人・2 自分, 売り出し, 建物, 地番, 持ち主] → 区画の塗りと外まわり（マスの単位の Path2D）・まん中・大きさ
function prepParcel(a) {
  const p = { id: a[0], own: a[2], sale: a[3], bld: a[4], ban: a[5], okey: a[6], n: 0, cells: new Set(), x0: Infinity, y0: Infinity, x1: -Infinity, y1: -Infinity, sx: 0, sy: 0 };
  const r = a[1] || [], fill = new Path2D(), edge = new Path2D();
  for (let i = 0; i + 2 < r.length; i += 3) {
    const y = r[i], xa = r[i + 1], xb = r[i + 2];
    fill.rect(xa / 5, y / 5, (xb - xa + 1) / 5, 0.2);
    for (let x = xa; x <= xb; x++) { p.cells.add(x + ',' + y); p.n++; p.sx += x; p.sy += y; }
    p.x0 = Math.min(p.x0, xa); p.x1 = Math.max(p.x1, xb); p.y0 = Math.min(p.y0, y); p.y1 = Math.max(p.y1, y);
  }
  for (const key of p.cells) {
    const [x, y] = key.split(',').map(Number);
    if (!p.cells.has((x - 1) + ',' + y)) { edge.moveTo(x / 5, y / 5); edge.lineTo(x / 5, (y + 1) / 5); }
    if (!p.cells.has((x + 1) + ',' + y)) { edge.moveTo((x + 1) / 5, y / 5); edge.lineTo((x + 1) / 5, (y + 1) / 5); }
    if (!p.cells.has(x + ',' + (y - 1))) { edge.moveTo(x / 5, y / 5); edge.lineTo((x + 1) / 5, y / 5); }
    if (!p.cells.has(x + ',' + (y + 1))) { edge.moveTo(x / 5, (y + 1) / 5); edge.lineTo((x + 1) / 5, (y + 1) / 5); }
  }
  p.fill = fill; p.edge = edge;
  // 地番を書くところ：まん中にいちばん近い区画
  const mx = p.sx / Math.max(1, p.n), my = p.sy / Math.max(1, p.n); let bd = Infinity;
  for (const key of p.cells) { const [x, y] = key.split(',').map(Number), d = (x - mx) ** 2 + (y - my) ** 2; if (d < bd) { bd = d; p.lx = (x + 0.5) / 5; p.ly = (y + 0.5) / 5; } }
  p.bb = [p.x0 / 5, p.y0 / 5, (p.x1 + 1) / 5, (p.y1 + 1) / 5];
  return p;
}
// 見えているセルのもの（id でまとめる）
function visibleItems() {
  const [lod, cs] = lodOf(S.cam.z), v = view();
  const i0 = Math.floor(v.x0 / cs), j0 = Math.floor(v.y0 / cs), i1 = Math.floor(v.x1 / cs), j1 = Math.floor(v.y1 / cs);
  const segs = new Map(), stas = new Map(), deps = new Map(), nodes = new Map(), parcels = new Map(), places = new Map(), chos = new Map(), blds = new Map(), names = {};
  const take = d => {
    for (const s of d.segs) segs.set(s.id, s);
    for (const s of d.stas) stas.set(s.id, s);
    for (const s of d.deps) deps.set(s.id, s);
    for (const n of d.nodes) nodes.set(n.id, n);
    for (const p of d.parcels) parcels.set(p.id, p);
    for (const b of (d.blds || [])) blds.set(b.id, b);
    for (const p of d.places) places.set(p.id, p);
    for (const c of d.chos) chos.set(c[0], c);
    Object.assign(names, d.names);
  };
  for (let j = j0; j <= j1; j++) for (let i = i0; i <= i1; i++) {
    let c = S.cells.get(lod + ':' + i + ',' + j);
    if (c && c.data) { take(c.data); continue; }
    // まだ読めていないところは、ほかの細かさのものを使う
    for (const [l2, cs2] of [[0, 96], [1, 384], [2, 1024]]) {
      if (l2 === lod) continue;
      const a0 = Math.floor(i * cs / cs2), b0 = Math.floor(j * cs / cs2), a1 = Math.floor(((i + 1) * cs - 1) / cs2), b1 = Math.floor(((j + 1) * cs - 1) / cs2);
      let any = false;
      for (let b = b0; b <= b1; b++) for (let a = a0; a <= a1; a++) { const c2 = S.cells.get(l2 + ':' + a + ',' + b); if (c2 && c2.data) { take(c2.data); any = true; } }
      if (any) break;
    }
  }
  return { segs, stas, deps, nodes, parcels, places, chos, blds, names };
}
// 変わったもの（ほかの人の工事など）。15秒ごと
async function poll() {
  if (!S.open || document.hidden) return;
  try {
    const r = await call('mp_poll', { p_since: S.ver });
    if (r.reload) { for (const c of S.cells.values()) c.stale = true; S.ver = r.ver; S.dirty = true; needCells(); return; }
    for (const ch of r.ch || []) {
      if (ch.k === 'zone') { // 用途地域：チャンクを読みなおす
        if (ch.b) for (let cy = Math.floor(ch.b[1] / CS); cy <= Math.floor(ch.b[3] / CS); cy++) for (let cx = Math.floor(ch.b[0] / CS); cx <= Math.floor(ch.b[2] / CS); cx++) S.chunks.delete(ckey(cx, cy));
      }
      if (ch.k === 'route') { if (S.onRoute) S.onRoute(); continue; }
      if (ch.k === 'cho') {   // 町字の合併・分割：町字のデータを読みなおす
        if (ch.b) for (let cy = Math.floor(ch.b[1] / CS) - 1; cy <= Math.floor(ch.b[3] / CS) + 1; cy++) for (let cx = Math.floor(ch.b[0] / CS) - 1; cx <= Math.floor(ch.b[2] / CS) + 1; cx++) { S.cho.delete(ckey(cx, cy)); const n = S.chunks.get(ckey(cx, cy)); if (n) n.bnd = null; }
      }
      const b = ch.b;
      for (const c of S.cells.values()) {
        if (!b) { c.stale = true; continue; }
        const x0 = c.i * c.cs, y0 = c.j * c.cs, x1 = x0 + c.cs, y1 = y0 + c.cs;
        if (b[0] <= x1 + 2 && b[2] >= x0 - 2 && b[1] <= y1 + 2 && b[3] >= y0 - 2) c.stale = true;
      }
    }
    S.ver = r.ver; S.dirty = true; needCells(); needChunks();
  } catch (e) { console.warn(e); }
}
// 自分の工事のあと：その範囲を読みなおす
function refreshBox(x0, y0, x1, y1) {
  for (const c of S.cells.values()) {
    const a0 = c.i * c.cs, b0 = c.j * c.cs;
    if (x0 <= a0 + c.cs + 2 && x1 >= a0 - 2 && y0 <= b0 + c.cs + 2 && y1 >= b0 - 2) c.stale = true;
  }
  S.dirty = true; needCells();
}

/* ---------- 描く ---------- */
const RS = {
  exp: { fill: '#62bb83', edge: '#2f7d4f', min: 2.6 }, nat: { fill: '#f4ad62', edge: '#b4672b', min: 2.2 }, pref: { fill: '#f8dc7a', edge: '#b39a40', min: 1.7 },
  city: { fill: '#ffffff', edge: '#b9b3a7', min: 1.1 }, priv: { fill: '#f7f2e6', edge: '#a39c8c', min: 1.0 }, lane: { fill: '#ffffff', edge: '#cfc9be', min: 0.7 }
};
const ROAD_ORDER = ['lane', 'city', 'priv', 'pref', 'nat'];
const DEP_SIZE = { rail: { S: [5, 2], M: [7, 3], L: [10, 4] }, bus: { S: [3, 2], M: [5, 3] } };
function pathSeg(g, s, off) {
  const P = s.P, n = s.np;
  g.beginPath();
  if (!off) {
    g.moveTo(sx(P[0]), sy(P[1]));
    for (let i = 1; i < n; i++) g.lineTo(sx(P[2 * i]), sy(P[2 * i + 1]));
    return;
  }
  // 横にずらした線（車線・複線）
  for (let i = 0; i < n; i++) {
    const a = Math.max(0, i - 1), b = Math.min(n - 1, i + 1);
    let dx = P[2 * b] - P[2 * a], dy = P[2 * b + 1] - P[2 * a + 1]; const L = Math.hypot(dx, dy) || 1; dx /= L; dy /= L;
    const x = P[2 * i] - dy * off, y = P[2 * i + 1] + dx * off;
    if (i) g.lineTo(sx(x), sy(y)); else g.moveTo(sx(x), sy(y));
  }
}
function segVisible(s, v) { const b = s.bb; return b[2] >= v.x0 - 1 && b[0] <= v.x1 + 1 && b[3] >= v.y0 - 1 && b[1] <= v.y1 + 1; }
function render() {
  const g = S.ctx, z = S.cam.z, v = view();
  g.setTransform(S.dpr, 0, 0, S.dpr, 0, 0);
  g.fillStyle = 'rgb(70,128,186)'; g.fillRect(0, 0, S.W, S.H);
  // 遠くから見た絵（いつも下に）
  if (S.ov && S.ovInfo) {
    const o = S.ovInfo;
    g.imageSmoothingEnabled = true;
    g.drawImage(S.ov, sx(o.x0), sy(o.y0), (o.x1 - o.x0) * z, (o.y1 - o.y0) * z);
  }
  // チャンク
  if (z >= 1.2) {
    const cx0 = Math.floor(v.x0 / CS), cy0 = Math.floor(v.y0 / CS), cx1 = Math.floor(v.x1 / CS), cy1 = Math.floor(v.y1 / CS);
    const hi = z >= 3; let made = 0;
    for (let cy = cy0; cy <= cy1; cy++) for (let cx = cx0; cx <= cx1; cx++) {
      const c = S.chunks.get(ckey(cx, cy)); if (!c || c.sea) continue;
      c.used = now();
      let img = null;
      if (hi) { if (!c.hi && made < 6) { c.hi = chunkHi(c); made++; } img = c.hi || c.lo || (c.lo = chunkLo(c)); }
      else img = c.lo || (c.lo = chunkLo(c));
      g.imageSmoothingEnabled = !hi || img !== c.hi ? z < 3 : true;
      g.drawImage(img, Math.floor(sx(cx * CS)), Math.floor(sy(cy * CS)), Math.ceil(CS * z) + 1, Math.ceil(CS * z) + 1);
      if (S.layer.zone) { if (!c.zc) c.zc = chunkZone(c); g.imageSmoothingEnabled = false; g.drawImage(c.zc, sx(cx * CS), sy(cy * CS), CS * z, CS * z); }
    }
    if (made >= 6) S.dirty = true;   // 次のフレームで続きを
  }
  // 川（線で）
  if (z >= 1.2 && window.MapGen) {
    const i0 = Math.floor(v.x0 / 256), j0 = Math.floor(v.y0 / 256), i1 = Math.floor(v.x1 / 256), j1 = Math.floor(v.y1 / 256);
    g.lineCap = 'round'; g.lineJoin = 'round';
    for (const pass of [0, 1]) for (let j = j0; j <= j1; j++) for (let i = i0; i <= i1; i++) for (const rv of riversCell(i, j)) {
      const P = rv.pts, n = P.length / 2;
      for (let a = 0; a < n - 1; a += 6) {
        const b = Math.min(n - 1, a + 6), w = rv.w[a];
        g.beginPath(); g.moveTo(sx(P[2 * a]), sy(P[2 * a + 1]));
        for (let k = a + 1; k <= b; k++) g.lineTo(sx(P[2 * k]), sy(P[2 * k + 1]));
        g.strokeStyle = pass ? 'rgb(100,166,226)' : 'rgba(150,175,150,.9)'; g.lineWidth = Math.max(pass ? 1.4 : 2.6, w * z + (pass ? 0 : Math.max(1.5, 0.12 * z))); g.stroke();
      }
    }
  }
  const it = visibleItems(); S.vis = it;
  // 土地（筆）：持ち主の色・建物・売り出し・地番
  if (S.layer.own && z >= 4) drawParcels(g, it, z, v);
  // 道路（ふち → なか）
  const segs = [...it.segs.values()].filter(s => segVisible(s, v));
  const roads = segs.filter(s => s.k === 'road'), rails = segs.filter(s => s.k === 'rail');
  g.lineCap = 'round'; g.lineJoin = 'round';
  const wpx = s => Math.max(RS[s.c] ? (s.art && s.c === 'city' ? 1.4 : RS[s.c].min) : 1, s.w * z);
  // とても近いときは、アスファルトの色に白い線（車線）。ふちは歩道
  const asph = z >= 20;
  for (const pass of [0, 1]) for (const cls of ROAD_ORDER) for (const s of roads) {
    if (s.c !== cls) continue;
    const st = RS[cls], w = wpx(s);
    g.strokeStyle = pass ? (asph ? (cls === 'lane' ? '#9a9a96' : '#86868a') : st.fill) : (asph ? '#d9d5cc' : st.edge);
    g.lineWidth = pass ? w : w + (asph ? Math.max(2, 0.1 * z) : w > 2.5 ? 2 : 1.2);
    pathSeg(g, s); g.stroke();
  }
  // 車線の線（近いとき）
  if (asph) for (const s of roads) {
    if (s.c === 'exp' || !s.l) continue;
    laneMarks(g, s, z);
  }
  // 線路
  for (const s of rails) drawRail(g, s, z);
  // 高速（高架なので上に）
  for (const pass of [0, 1]) for (const s of roads) {
    if (s.c !== 'exp') continue;
    const st = RS.exp, w = wpx(s);
    g.strokeStyle = pass ? (asph ? '#7b7f86' : st.fill) : st.edge; g.lineWidth = pass ? w : w + 2; pathSeg(g, s); g.stroke();
  }
  if (asph) for (const s of roads) if (s.c === 'exp' && s.l) laneMarks(g, s, z);
  // 建物（形・高さ）
  if (z >= 4) drawBlds(g, it, z, v);
  // 境界線（県・市区町村・町字）
  if (z >= 1.2) drawBounds(g, z, v);
  // 系統（めだたせる）
  if (S.routeHi) drawRouteHi(g, z, it);
  // 車庫・駅
  for (const d of it.deps.values()) drawDepot(g, d, z);
  for (const s of it.stas.values()) drawStation(g, s, z);
  // えらんだもの
  if (S.sel && S.sel.kind === 'seg') { const s = it.segs.get(S.sel.id); if (s) { g.strokeStyle = 'rgba(220,40,60,.75)'; g.lineWidth = Math.max(4, s.w * z + 4); pathSeg(g, s); g.stroke(); } }
  if (S.sel && S.sel.kind === 'cell') {
    const p = S.sel.parcel && it.parcels.get(S.sel.parcel);
    if (p) { worldT(g); g.strokeStyle = '#d23'; g.lineWidth = 3 / z; g.stroke(p.edge); screenT(g); }
    else { const w = z / 5; g.strokeStyle = '#d23'; g.lineWidth = 2; g.strokeRect(sx(S.sel.x / 5), sy(S.sel.y / 5), Math.max(3, w), Math.max(3, w)); }
  }
  // IC・JCT
  if (z >= 2.2) for (const n of it.nodes.values()) {
    if (!n.n || (n.nk !== 'ic' && n.nk !== 'jct')) continue;
    const x = sx(n.fx), y = sy(n.fy); if (x < -40 || y < -20 || x > S.W + 40 || y > S.H + 20) continue;
    g.fillStyle = n.nk === 'jct' ? '#7a2fa8' : '#1f7a46'; g.beginPath(); g.arc(x, y, 4, 0, 6.3); g.fill();
    if (z >= 3.5) label(g, n.n, x + 6, y - 6, { size: 11, color: n.nk === 'jct' ? '#5a1f80' : '#145a33', bg: 'rgba(255,255,255,.85)', left: true });
  }
  // 地名
  if (S.layer.label) drawPlaces(g, it, z);
  // 道具の上がき
  if (S.drawTool) S.drawTool(g, z);
  // 方位と縮尺
  drawScale(g, z);
}
// 地図の座標（マス）で描くとき・画面にもどすとき
function worldT(g) { const z = S.cam.z; g.setTransform(S.dpr * z, 0, 0, S.dpr * z, S.dpr * (S.W / 2 - S.cam.x * z), S.dpr * (S.H / 2 - S.cam.y * z)); }
function screenT(g) { g.setTransform(S.dpr, 0, 0, S.dpr, 0, 0); }
function drawParcels(g, it, z, v) {
  const vis = [...it.parcels.values()].filter(p => p.bb[2] >= v.x0 && p.bb[0] <= v.x1 && p.bb[3] >= v.y0 && p.bb[1] <= v.y1);
  if (!vis.length) return;
  worldT(g);
  const mark = S.toolState && S.toolState.marks;   // 合筆でえらんでいる筆
  for (const p of vis) {
    g.fillStyle = p.own === 3 ? 'rgba(110,110,110,.16)' : p.own === 2 ? 'rgba(40,110,220,.24)' : 'rgba(230,120,30,.2)';
    g.fill(p.fill);
  }
  if (z >= 12) {
    for (const p of vis) {
      g.strokeStyle = p.own === 3 ? 'rgba(90,90,90,.7)' : p.own === 2 ? 'rgba(30,80,170,.85)' : 'rgba(180,90,20,.75)';
      g.lineWidth = 1.2 / z; g.stroke(p.edge);
      if (p.sale != null) { g.strokeStyle = '#d23'; g.setLineDash([4 / z, 3 / z]); g.lineWidth = 2 / z; g.stroke(p.edge); g.setLineDash([]); }
    }
  }
  if (mark && mark.size) for (const p of vis) if (mark.has(p.id)) { g.strokeStyle = '#ff9800'; g.lineWidth = 3.5 / z; g.stroke(p.edge); }
  screenT(g);
  if (z >= 36) for (const p of vis) label(g, p.ban, sx(p.lx), sy(p.ly), { size: 10, color: p.own === 3 ? '#444' : p.own === 2 ? '#1a3f8a' : '#7a4416' });
}
// 境界線：県（太い一点鎖線）・市区町村（鎖線）・区（破線）・町／大字（点線）・丁目／字（細い点線）
const BND_ST = { pref: { w: 3.2, c: 'rgba(80,40,110,.85)', d: [12, 4, 2, 4], z: 1.2 }, muni: { w: 2.2, c: 'rgba(90,50,120,.75)', d: [9, 4], z: 1.2 },
                 ward: { w: 1.6, c: 'rgba(90,50,120,.6)', d: [5, 4], z: 2 }, dist: { w: 1.1, c: 'rgba(100,70,130,.5)', d: [3, 3], z: 4 }, sub: { w: 0.9, c: 'rgba(100,70,130,.38)', d: [2, 3], z: 10 } };
function drawBounds(g, z, v) {
  const cx0 = Math.floor(v.x0 / CS), cy0 = Math.floor(v.y0 / CS), cx1 = Math.floor(v.x1 / CS), cy1 = Math.floor(v.y1 / CS);
  const chs = [];
  for (let cy = cy0; cy <= cy1; cy++) for (let cx = cx0; cx <= cx1; cx++) { const c = S.chunks.get(ckey(cx, cy)); if (c && !c.sea) { if (!c.bnd) c.bnd = chunkBnd(c); chs.push(c); } }
  worldT(g); g.lineCap = 'butt';
  for (const lv of ['sub', 'dist', 'ward', 'muni', 'pref']) {
    const st = BND_ST[lv]; if (z < st.z) continue;
    g.beginPath();
    for (const c of chs) { const a = c.bnd[lv]; for (let i = 0; i < a.length; i += 4) { g.moveTo(a[i], a[i + 1]); g.lineTo(a[i + 2], a[i + 3]); } }
    if (lv === 'pref' || lv === 'muni') { g.strokeStyle = 'rgba(255,255,255,.55)'; g.lineWidth = (st.w + 2) / z; g.setLineDash([]); g.stroke(); }
    g.strokeStyle = st.c; g.lineWidth = st.w / z; g.setLineDash(st.d.map(d => d / z)); g.stroke();
  }
  g.setLineDash([]); g.lineCap = 'round'; screenT(g);
}
function laneMarks(g, s, z) {
  const w = s.w * z; if (w < 9) return;
  const lanes = s.l, cw = Math.max(0.1, s.w - 0.1), lw = cw / (2 * lanes);
  g.lineCap = 'butt';
  // 中央線：片側2車線以上は黄色の実線2本（国道・県道）／白の実線。1車線は白の破線
  if (lanes >= 2) {
    g.setLineDash([]); g.strokeStyle = s.c === 'nat' || s.c === 'pref' ? '#e2b83a' : '#ffffff'; g.lineWidth = Math.max(1, z * 0.012);
    pathSeg(g, s, 0.012); g.stroke(); pathSeg(g, s, -0.012); g.stroke();
  } else { g.setLineDash([z * 0.12, z * 0.1]); g.strokeStyle = '#ffffff'; g.lineWidth = Math.max(1, z * 0.01); pathSeg(g, s); g.stroke(); }
  // 車線の境（白の破線）
  if (lanes >= 2) {
    g.setLineDash([z * 0.1, z * 0.12]); g.strokeStyle = 'rgba(255,255,255,.9)'; g.lineWidth = Math.max(1, z * 0.008);
    for (let k = 1; k < lanes; k++) for (const sgn of [1, -1]) { pathSeg(g, s, sgn * k * lw); g.stroke(); }
  }
  g.setLineDash([]); g.lineCap = 'round';
}
function drawRail(g, s, z) {
  const mine = s.mine;
  const w = Math.max(1.8, (s.dbl ? 0.34 : 0.22) * z);
  g.lineCap = 'butt';
  if (z >= 10 && s.dbl) {
    for (const off of [0.09, -0.09]) {
      g.strokeStyle = '#4a4a4a'; g.lineWidth = Math.max(1.5, 0.12 * z); g.setLineDash([]); pathSeg(g, s, off); g.stroke();
      g.strokeStyle = '#ffffff'; g.lineWidth = Math.max(1, 0.07 * z); g.setLineDash([z * 0.5, z * 0.5]); pathSeg(g, s, off); g.stroke();
    }
  } else {
    if (mine) { g.strokeStyle = 'rgba(40,110,220,.5)'; g.lineWidth = w + 4; g.setLineDash([]); pathSeg(g, s); g.stroke(); }
    g.strokeStyle = '#3f3f3f'; g.lineWidth = w; g.setLineDash([]); pathSeg(g, s); g.stroke();
    if (z >= 1.5) { g.strokeStyle = '#ffffff'; g.lineWidth = Math.max(1, w - 2); g.setLineDash([Math.max(4, z * 0.5), Math.max(4, z * 0.5)]); pathSeg(g, s); g.stroke(); }
  }
  if (z >= 10 && !s.el) { /* 非電化：そのまま */ }
  g.setLineDash([]); g.lineCap = 'round';
  if (mine && z >= 10 && s.dbl) { g.strokeStyle = 'rgba(40,110,220,.35)'; g.lineWidth = 0.5 * z + 4; pathSeg(g, s); g.stroke(); }
}
function drawStation(g, s, z) {
  const x = sx(s.fx), y = sy(s.fy);
  if (x < -80 || y < -40 || x > S.W + 80 || y > S.H + 40) return;
  if (s.k === 'bus') {
    if (z < 5) return;
    const r = Math.max(3.5, 0.18 * z);
    g.fillStyle = '#2a7de1'; g.strokeStyle = '#fff'; g.lineWidth = 1.5; g.beginPath(); g.arc(x, y, r, 0, 6.3); g.fill(); g.stroke();
    if (r >= 7) { g.fillStyle = '#fff'; g.font = `bold ${Math.round(r * 1.2)}px sans-serif`; g.textAlign = 'center'; g.textBaseline = 'middle'; g.fillText('B', x, y + 0.5); }
    if (z >= 9) label(g, s.n, x, y - r - 8, { size: 11, color: '#164f99', bg: 'rgba(255,255,255,.85)' });
    return;
  }
  const L = Math.max(10, s.pl / 50 * z), Wd = Math.max(5, (0.22 * Math.max(1, s.tr) + 0.18) * z);
  g.save(); g.translate(x, y); g.rotate(s.a);
  g.fillStyle = '#ffffff'; g.strokeStyle = s.mine ? '#1f5fbf' : '#333'; g.lineWidth = 1.6;
  g.fillRect(-L / 2, -Wd / 2, L, Wd); g.strokeRect(-L / 2, -Wd / 2, L, Wd);
  if (z >= 12) { g.strokeStyle = '#999'; g.lineWidth = 1; for (let k = 1; k < s.tr; k++) { const yy = -Wd / 2 + Wd * k / s.tr; g.beginPath(); g.moveTo(-L / 2, yy); g.lineTo(L / 2, yy); g.stroke(); } }
  g.restore();
  if (z >= 1.6) label(g, s.n, x, y - Wd / 2 - 10, { size: z >= 6 ? 13 : 11, bold: true, color: '#111', bg: 'rgba(255,255,255,.9)', border: s.mine ? '#1f5fbf' : '#555' });
}
// 車庫の大きさ：[長さ, はば, 線からのあき, 留置線の数]（マス）。'T400x6' は線路をなぞったもの（400m・6本）
function depDim(k, sz) {
  const m = /^T(\d+)x(\d+)$/.exec(sz || '');
  if (m && k === 'rail') { const l = Number(m[1]), n = Number(m[2]); return [l / 50, (n * 5 + 10) / 50, 0.25, n]; }
  const s = (DEP_SIZE[k] || DEP_SIZE.rail)[sz] || [5, 2];
  return [s[0], s[1], 0.9, Math.round(s[1] / 0.35)];
}
function depPoly(d) {
  const [lt, wt, gap] = depDim(d.k, d.sz);
  const c = Math.cos(d.a), s = Math.sin(d.a), nx = -s * d.side, ny = c * d.side;
  const pts = [];
  for (const [a, b] of [[-lt / 2, gap], [lt / 2, gap], [lt / 2, gap + wt], [-lt / 2, gap + wt]]) pts.push([d.fx + c * a + nx * b, d.fy + s * a + ny * b]);
  return pts;
}
function drawDepot(g, d, z) {
  if (z < 2) return;
  const P = depPoly(d);
  g.beginPath(); P.forEach((p, i) => i ? g.lineTo(sx(p[0]), sy(p[1])) : g.moveTo(sx(p[0]), sy(p[1]))); g.closePath();
  g.fillStyle = d.k === 'rail' ? 'rgba(170,160,150,.85)' : 'rgba(150,170,190,.85)'; g.fill();
  g.strokeStyle = d.mine ? '#1f5fbf' : '#555'; g.lineWidth = 1.5; g.stroke();
  if (z >= 6 && d.k === 'rail') {   // 留置線
    g.strokeStyle = 'rgba(60,60,60,.7)'; g.lineWidth = 1;
    const n = depDim('rail', d.sz)[3] + 1;
    for (let k = 1; k < n; k++) {
      const f = k / n, a = P[0], b = P[1], c2 = P[3], e2 = P[2];
      g.beginPath(); g.moveTo(sx(a[0] + (c2[0] - a[0]) * f), sy(a[1] + (c2[1] - a[1]) * f)); g.lineTo(sx(b[0] + (e2[0] - b[0]) * f), sy(b[1] + (e2[1] - b[1]) * f)); g.stroke();
    }
  }
  if (z >= 4) { const cx = (P[0][0] + P[2][0]) / 2, cy = (P[0][1] + P[2][1]) / 2; label(g, d.n, sx(cx), sy(cy), { size: 11, color: '#222', bg: 'rgba(255,255,255,.8)' }); }
}
function drawRouteHi(g, z, it) {
  const R = S.routeHi; if (!R || !R.legs) return;
  g.strokeStyle = R.color || '#d23'; g.globalAlpha = 0.75; g.lineWidth = Math.max(5, 0.5 * z); g.lineCap = 'round';
  for (const leg of R.legs) for (const [sid, s0, s1] of leg.g || []) {
    const s = it.segs.get(sid); if (!s) continue;
    const pts = subPts(s, Math.min(s0, s1), Math.max(s0, s1));
    g.beginPath(); pts.forEach((p, i) => i ? g.lineTo(sx(p[0]), sy(p[1])) : g.moveTo(sx(p[0]), sy(p[1]))); g.stroke();
  }
  g.globalAlpha = 1;
}
// 線の一部の点（はじめから s0〜s1 マス）
function subPts(s, s0, s1) {
  const P = s.P, out = []; let acc = 0;
  for (let i = 0; i + 1 < s.np; i++) {
    const ax = P[2 * i], ay = P[2 * i + 1], bx = P[2 * i + 2], by = P[2 * i + 3], d = Math.hypot(bx - ax, by - ay);
    if (acc + d >= s0 && acc <= s1) {
      const t0 = clamp((s0 - acc) / (d || 1), 0, 1), t1 = clamp((s1 - acc) / (d || 1), 0, 1);
      if (!out.length) out.push([ax + (bx - ax) * t0, ay + (by - ay) * t0]);
      out.push([ax + (bx - ax) * t1, ay + (by - ay) * t1]);
    }
    acc += d;
  }
  return out;
}
// 文字（白いふちどり・ほかの文字と重ならないように）
let LBL = [];
function label(g, text, x, y, o) {
  o = o || {};
  const size = o.size || 12;
  g.font = `${o.bold ? 'bold ' : ''}${size}px system-ui, -apple-system, "Hiragino Sans", "Noto Sans JP", sans-serif`;
  const w = g.measureText(text).width, h = size + 4;
  const x0 = o.left ? x : x - w / 2 - 3, y0 = y - h / 2;
  for (const b of LBL) if (x0 < b[2] && x0 + w + 6 > b[0] && y0 < b[3] && y0 + h > b[1]) return false;
  LBL.push([x0, y0, x0 + w + 6, y0 + h]);
  if (o.bg) { g.fillStyle = o.bg; roundRect(g, x0, y0, w + 6, h, 4); g.fill(); if (o.border) { g.strokeStyle = o.border; g.lineWidth = 1; g.stroke(); } }
  else { g.lineWidth = 3; g.strokeStyle = 'rgba(255,255,255,.9)'; g.textAlign = 'left'; g.textBaseline = 'middle'; g.strokeText(text, x0 + 3, y); }
  g.fillStyle = o.color || '#222'; g.textAlign = 'left'; g.textBaseline = 'middle'; g.fillText(text, x0 + 3, y + 0.5);
  return true;
}
function roundRect(g, x, y, w, h, r) { g.beginPath(); g.moveTo(x + r, y); g.arcTo(x + w, y, x + w, y + h, r); g.arcTo(x + w, y + h, x, y + h, r); g.arcTo(x, y + h, x, y, r); g.arcTo(x, y, x + w, y, r); g.closePath(); }
function drawPlaces(g, it, z) {
  // 町字（町・大字は近いとき、丁目・字はもっと近いとき）
  if (z >= 5) {
    const cs = [...it.chos.values()].filter(c => (c[1] === 'cho' || c[1] === 'oaza') ? z >= 5 && z < 40 : z >= 14);
    cs.sort((a, b) => (a[1] === 'cho' || a[1] === 'oaza' ? 0 : 1) - (b[1] === 'cho' || b[1] === 'oaza' ? 0 : 1));
    for (const c of cs) {
      const x = sx(c[3] + 0.5), y = sy(c[4] + 0.5);
      if (x < -60 || y < -30 || x > S.W + 60 || y > S.H + 30) continue;
      if (c[1] === 'cho' || c[1] === 'oaza') label(g, c[2], x, y, { size: 12, bold: true, color: '#5a4a6a' });
      else label(g, c[1] === 'aza' ? '字' + c[2] : c[2], x, y, { size: 10, color: '#6a5a7a' });
    }
  }
  const ps = [...it.places.values()];
  const show = p => p.k === 'pref' ? z < 0.6 : p.k === 'muni' ? (z >= 0.3 && z < 12 && (z > 1.2 || (p.pop || 0) > 150000 || p.t === '市')) : p.k === 'ward' ? z >= 1.2 && z < 14 : p.k === 'river' ? z >= 2.5 : false;
  const rank = p => p.k === 'pref' ? 0 : p.k === 'muni' ? 1 + (p.pop > 500000 ? 0 : 1) : p.k === 'ward' ? 3 : p.k === 'river' ? 4 : 5;
  ps.filter(show).sort((a, b) => rank(a) - rank(b) || (b.pop || 0) - (a.pop || 0)).forEach(p => {
    const x = sx(p.x + 0.5), y = sy(p.y + 0.5);
    if (x < -60 || y < -30 || x > S.W + 60 || y > S.H + 30) return;
    if (p.k === 'pref') label(g, p.n + (p.t || '県'), x, y, { size: 18, bold: true, color: '#3a3a3a' });   // 瑠璃府は「府」
    else if (p.k === 'muni') label(g, p.n + (p.t || ''), x, y, { size: p.pop > 500000 ? 16 : 13, bold: true, color: '#2b2b2b' });
    else if (p.k === 'ward') label(g, p.n + '区', x, y, { size: 13, bold: true, color: '#5a4a6a' });
    else if (p.k === 'river') label(g, p.n, x, y, { size: 12, color: '#1e5ea8' });
    else label(g, p.n, x, y, { size: 11, color: '#555' });
  });
}
function drawScale(g, z) {
  // 縮尺（100m・500m・1km・5km・10km…）
  const opts = [50, 100, 250, 500, 1000, 2500, 5000, 10000, 25000, 50000];
  let m = opts[0]; for (const o of opts) if (o / 50 * z <= 120) m = o;
  const w = m / 50 * z, x = 12, y = S.H - 14;
  g.fillStyle = 'rgba(255,255,255,.8)'; g.fillRect(x - 4, y - 16, w + 8, 20);
  g.strokeStyle = '#222'; g.lineWidth = 2; g.beginPath(); g.moveTo(x, y - 6); g.lineTo(x, y); g.lineTo(x + w, y); g.lineTo(x + w, y - 6); g.stroke();
  g.fillStyle = '#222'; g.font = '11px system-ui, sans-serif'; g.textAlign = 'left'; g.textBaseline = 'alphabetic';
  g.fillText(m >= 1000 ? m / 1000 + 'km' : m + 'm', x + 4, y - 4);
}
function frame() {
  if (!S.open) return;
  if (S.dirty) {
    S.dirty = false; LBL = [];
    try { render(); } catch (e) { console.error(e); }
    needChunks(); needCells(); needCho(); trimChunks();
  }
  requestAnimationFrame(frame);
}

/* ---------- 画面（ボタン・下のシート） ---------- */
const CSS = `
.mp-wrap{position:relative;height:calc(100dvh - 210px);min-height:440px;border-radius:12px;overflow:hidden;background:#4680ba;touch-action:none;user-select:none;-webkit-user-select:none}
.mp-wrap.mp-full{position:fixed;inset:0;height:auto;border-radius:0;z-index:25}
.mp-cv{position:absolute;inset:0;width:100%;height:100%;display:block;cursor:grab}
.mp-top{position:absolute;left:8px;right:56px;top:8px;display:flex;gap:6px;align-items:center;flex-wrap:wrap;pointer-events:none}
.mp-top>*{pointer-events:auto}
.mp-top select{max-width:38%}
.mp-top select,.mp-top button,.mp-zoom button,.mp-tools button{border:1px solid rgba(0,0,0,.18);background:rgba(255,255,255,.94);color:#222;border-radius:10px;font-weight:700;font-size:13px;padding:7px 10px;box-shadow:0 1px 3px rgba(0,0,0,.15)}
.mp-top button.on{background:#1f5fbf;color:#fff;border-color:#1f5fbf}
.mp-top .mp-addr{background:rgba(255,255,255,.94);border-radius:10px;padding:6px 10px;font-size:12px;font-weight:700;color:#333;max-width:60%;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;box-shadow:0 1px 3px rgba(0,0,0,.15)}
.mp-zoom{position:absolute;right:8px;top:8px;display:flex;flex-direction:column;gap:6px}
.mp-zoom button{width:40px;height:40px;padding:0;font-size:18px}
.mp-tools{position:absolute;left:0;right:0;bottom:0;display:flex;gap:4px;padding:6px 6px calc(6px + env(safe-area-inset-bottom));overflow-x:auto;background:linear-gradient(transparent,rgba(0,0,0,.18))}
.mp-tools button{flex:none;padding:8px 11px}
.mp-tools button.on{background:#1f5fbf;color:#fff;border-color:#1f5fbf}
.mp-hint{position:absolute;left:50%;top:52px;transform:translateX(-50%);background:rgba(20,20,20,.78);color:#fff;font-size:12px;font-weight:700;border-radius:10px;padding:6px 10px;max-width:86%;text-align:center;pointer-events:none}
.mp-sheet{position:absolute;left:6px;right:6px;bottom:56px;max-height:44%;overflow:auto;background:var(--panel,#fff);color:var(--ink,#222);border-radius:14px;box-shadow:0 4px 18px rgba(0,0,0,.28);padding:12px 12px 10px;font-size:14px}
.mp-sheet h4{margin:0 0 6px;font-size:16px}
.mp-sheet .mp-x{float:right;border:0;background:none;font-size:20px;line-height:1;color:var(--muted,#777);padding:0 2px}
.mp-kv{display:grid;grid-template-columns:auto 1fr;gap:3px 10px;font-size:13px;margin:6px 0}
.mp-kv b{color:var(--muted,#666);font-weight:600}
.mp-row{display:flex;gap:6px;flex-wrap:wrap;align-items:center;margin-top:8px}
.mp-row .btn{flex:1 1 auto}
.mp-seg{display:inline-flex;border:1px solid var(--line,#ccc);border-radius:10px;overflow:hidden}
.mp-seg button{border:0;background:var(--bg,#f4f4f4);padding:6px 10px;font-weight:700;font-size:13px;color:inherit}
.mp-seg button.on{background:#1f5fbf;color:#fff}
.mp-cost{font-weight:800;font-size:15px}
.mp-warn{color:#c33;font-size:12px;font-weight:700}
.mp-tag,.mp-item .mp-tag{display:inline-block;border:1px solid #7b4fd8;color:#7b4fd8;border-radius:6px;padding:0 5px;font-size:11px;font-weight:700}
.mp-list{display:flex;flex-direction:column;gap:6px;margin:6px 0}
.mp-item{border:1px solid var(--line,#ddd);border-radius:10px;padding:8px 10px;background:var(--panel,#fff)}
.mp-item small{color:var(--muted,#777)}
.mp-cars{display:flex;flex-wrap:wrap;gap:4px;margin:4px 0}
.mp-car{border:1px solid var(--line,#ccc);border-radius:7px;padding:4px 7px;font-size:12px;font-weight:700;background:var(--bg,#f6f6f6);cursor:pointer}
.mp-car.on{background:#1f5fbf;color:#fff;border-color:#1f5fbf}
.mp-car.busy{opacity:.55}
.mp-car .n{display:block;font-size:10px;font-weight:600;opacity:.8}
.mp-spd{width:100%;height:56px;display:block;margin:4px 0 2px;border:1px solid var(--line,#ddd);border-radius:8px;background:#fff}
.mp-dia{width:100%;height:360px;border:1px solid var(--line,#ddd);border-radius:10px;background:#fff;touch-action:pan-x pan-y}
.mp-tt{width:100%;border-collapse:collapse;font-size:12px}
.mp-tt th,.mp-tt td{border-top:1px solid var(--line,#ddd);padding:4px 3px;text-align:center;white-space:nowrap;font-variant-numeric:tabular-nums}
.mp-tt th{font-size:11px;color:var(--muted,#666)}
.mp-tt td.st{text-align:left;font-weight:700}
.mp-scroll{overflow-x:auto}
.mp-inp{width:100%;box-sizing:border-box;font-size:15px;padding:8px 10px;border:1px solid var(--line,#ccc);border-radius:9px;background:var(--bg,#fff);color:inherit}
.mp-num{width:90px}
.mp-floor{border-top:1px solid var(--line,#ddd);padding:2px 0}
.mp-floor summary{cursor:pointer;padding:5px 0;font-size:13px}
.mp-urow{display:flex;flex-wrap:wrap;gap:3px 10px;align-items:center;font-size:12.5px;padding:5px 0;border-top:1px dashed var(--line,#e6e6e6)}
.mp-urow .st{flex:1 1 120px}
.mp-urow .rt{font-variant-numeric:tabular-nums;font-weight:700}
.mp-urow .btn{padding:3px 9px;font-size:12px}
`;
function el(html) { const d = document.createElement('div'); d.innerHTML = html.trim(); return d.firstChild; }
function build(root) {
  if (!document.getElementById('mpCss')) { const st = document.createElement('style'); st.id = 'mpCss'; st.textContent = CSS; document.head.appendChild(st); }
  root.innerHTML = `<div class="mp-wrap" id="mpWrap">
    <canvas class="mp-cv"></canvas>
    <div class="mp-top">
      <select class="mp-as" title="だれの名前で"></select>
      <button data-lay="zone">用途地域</button><button data-lay="own" class="on">持ち主</button><button data-b25 title="建物の見えかた（2D・2.5D）"></button>
      <span class="mp-addr" translate="no" hidden></span>
    </div>
    <div class="mp-zoom"><button data-full title="大きく">⤢</button><button data-zin>＋</button><button data-zout>－</button><button data-home title="瑠璃市役所">⌂</button></div>
    <div class="mp-hint" hidden></div>
    <div class="mp-sheet" hidden></div>
    <div class="mp-tools">
      <button data-tool="look" class="on">👆 見る</button><button data-tool="land">▦ 土地</button><button data-tool="rail">🚃 線路</button>
      <button data-tool="road">🛣 道路</button><button data-tool="sta">🚉 駅・バス停</button><button data-tool="dep">🏭 車庫</button>
      <button data-tool="del">✖ こわす</button><button data-menu>≡ 車両・系統・ダイヤ</button>
    </div></div>`;
  S.wrap = root.querySelector('#mpWrap'); S.cv = S.wrap.querySelector('canvas'); S.ctx = S.cv.getContext('2d');
  S.sheet = S.wrap.querySelector('.mp-sheet'); S.hint = S.wrap.querySelector('.mp-hint'); S.addr = S.wrap.querySelector('.mp-addr');
  const asSel = S.wrap.querySelector('.mp-as');
  asSel.innerHTML = S.boot.as.map(a => `<option value="${esc(a.as)}">${a.as === 'me' ? '👤' : a.as === 'gov' ? '🏛' : '🏢'} ${esc(asLabel(a))}</option>`).join('');
  try { const sv = localStorage.getItem('mp_as'); if (sv && S.boot.as.some(a => a.as === sv)) S.as = sv; } catch (e) {}
  asSel.value = S.as;
  asSel.onchange = () => { S.as = asSel.value; try { localStorage.setItem('mp_as', S.as); } catch (e) {} for (const c of S.cells.values()) c.stale = true; S.dirty = true; if (S.onAs) S.onAs(); };
  S.wrap.querySelectorAll('[data-lay]').forEach(b => b.onclick = () => { const k = b.dataset.lay; S.layer[k] = !S.layer[k]; b.classList.toggle('on', S.layer[k]); S.dirty = true; });
  // 建物の見えかた：2.5D（高さ・壁）と 2D（上から見たまま）。この端末におぼえる
  try { const v = localStorage.getItem('mp_b25'); if (v != null) S.b25 = v !== '0'; } catch (e) {}
  const b25 = S.wrap.querySelector('[data-b25]'), b25L = () => { b25.textContent = S.b25 ? '🏢 2.5D' : '🏢 2D'; };
  b25L(); b25.onclick = () => { S.b25 = !S.b25; b25L(); try { localStorage.setItem('mp_b25', S.b25 ? '1' : '0'); } catch (e) {} S.dirty = true; };
  S.wrap.querySelector('[data-full]').onclick = () => { S.wrap.classList.toggle('mp-full'); resize(); };
  S.wrap.querySelector('[data-zin]').onclick = () => zoomAt(S.W / 2, S.H / 2, 1.6);
  S.wrap.querySelector('[data-zout]').onclick = () => zoomAt(S.W / 2, S.H / 2, 1 / 1.6);
  S.wrap.querySelector('[data-home]').onclick = () => setCam(HOME[0], HOME[1], 6);
  S.wrap.querySelectorAll('[data-tool]').forEach(b => b.onclick = () => setTool(b.dataset.tool));
  S.wrap.querySelector('[data-menu]').onclick = () => openMenu();
  bindInput();
  new ResizeObserver(resize).observe(S.wrap);
  resize();
}
function resize() {
  if (!S.wrap) return;
  const r = S.wrap.getBoundingClientRect(); S.dpr = Math.min(2, window.devicePixelRatio || 1);
  S.W = Math.max(1, r.width); S.H = Math.max(1, r.height);
  S.cv.width = Math.round(S.W * S.dpr); S.cv.height = Math.round(S.H * S.dpr); S.dirty = true;
}
function hint(t) { S.hint.hidden = !t; S.hint.textContent = t ? T(t) : ''; }
function sheet(html, bind) {
  if (!html) { S.sheet.hidden = true; S.sheet.innerHTML = ''; return null; }
  S.sheet.hidden = false; S.sheet.innerHTML = `<button class="mp-x" data-close>×</button>` + html;
  S.sheet.querySelector('[data-close]').onclick = () => { sheet(null); if (S.onSheetClose) { const f = S.onSheetClose; S.onSheetClose = null; f(); } };
  if (bind) bind(S.sheet);
  busyGuard(S.sheet);
  return S.sheet;
}
// 押したボタンは、その仕事（サーバーへの送信など）が終わるまで押せない（2回押しで2つできないように）
function busyGuard(root) {
  root.querySelectorAll('button').forEach(b => {
    const f = b.onclick; if (!f || f.guarded) return;
    const g = function (ev) {
      if (b.dataset.busy) return;
      const r = f.call(this, ev);
      if (r && typeof r.then === 'function') {
        b.dataset.busy = '1'; b.disabled = true;
        r.finally(() => { delete b.dataset.busy; if (b.isConnected) b.disabled = false; });
      }
      return r;
    };
    g.guarded = true; b.onclick = g;
  });
}
const asLabel = a => String((a && a.name) || '').replace(/（自分）$/, '');   // 自分は 👤 で見分ける（名前だけ出す）
const asName = () => asLabel(S.boot.as.find(a => a.as === S.as));
// サーバーの「つくる・変える」。同じものがまだ送信中なら、もう一度は送らない（2回押し）
const INFLIGHT = new Set();
async function api(fn, args, okMsg) {
  const key = args && args.p_dry !== true ? fn + JSON.stringify(args) : null;
  if (key && INFLIGHT.has(key)) return null;
  if (key) INFLIGHT.add(key);
  try { const r = await call(fn, args); if (okMsg) toast(okMsg); return r; }
  catch (e) { toast(e.message); return null; }
  finally { if (key) INFLIGHT.delete(key); }
}
// 他人の土地：見つもりの need（許可のいる筆）を出す。持ち主への申請ボタンつき
const LRS = { wait: '返事まち', ok: '許可', no: 'ことわり' };
function needH(need) {
  if (!need || !need.length) return '';
  return `<div class="mp-need"><p class="mp-warn" style="margin:4px 0">他人の土地を使います。持ち主に申請して許可をもらうか、持ち主が貸出料を決めているときだけ、つくれます</p>
    ${need.map(p => `<div class="small">・<span translate="no">${esc(p.label)}</span>（<span>${esc(p.owner)}</span>・<span>${p.n}区画</span>）${p.wait ? ' <b>申請中</b>' : p.no ? ' <span class="mp-warn">ことわられました</span>' : ''}</div>`).join('')}
    ${need.some(p => !p.wait) ? `<div class="mp-row"><button class="btn" data-lreq>持ち主に申請する（${esc(asName())}）</button></div>` : ''}</div>`;
}
function needBind(s, need, after) {
  const b = s.querySelector('[data-lreq]'); if (!b || !need) return;
  b.onclick = async () => {
    const msg = prompt(T('持ち主へのひとこと（なくてもよい）'), ''); if (msg == null) return;
    const r = await api('mp_land_req', { p_parcels: need.filter(p => !p.wait).map(p => p.id), p_msg: msg, p_as: S.as }, '申請しました。返事がきたら通知がとどきます');
    if (r && after) after();
  };
}
const hasNeed = q => !!(q && q.need && q.need.length);

/* ---------- 指・マウス ---------- */
function zoomAt(px, py, f) {
  const x = wx(px), y = wy(py), z = clamp(S.cam.z * f, 0.18, 64);
  setCam(x - (px - S.W / 2) / z, y - (py - S.H / 2) / z, z);
}
function bindInput() {
  const cv = S.cv, P = new Map();
  let drag = null, pinch = null, downAt = 0, moved = false, lp = null;
  const pos = e => { const r = cv.getBoundingClientRect(); return [e.clientX - r.left, e.clientY - r.top]; };
  cv.addEventListener('pointerdown', e => {
    cv.setPointerCapture(e.pointerId); const p = pos(e); P.set(e.pointerId, p);
    if (P.size === 1) {
      downAt = now(); moved = false;
      // 道具が点をつかむ（線の点を動かす）
      if (S.grab && S.grab(p[0], p[1])) { drag = { tool: true }; return; }
      drag = { x: p[0], y: p[1], cx: S.cam.x, cy: S.cam.y };
      clearTimeout(lp); lp = setTimeout(() => { if (!moved && P.size === 1 && S.onLong) S.onLong(wx(p[0]), wy(p[1]), p[0], p[1]); }, 550);
    } else if (P.size === 2) {
      clearTimeout(lp); drag = null;
      const [a, b] = [...P.values()];
      pinch = { d: Math.hypot(a[0] - b[0], a[1] - b[1]), mx: (a[0] + b[0]) / 2, my: (a[1] + b[1]) / 2, z: S.cam.z, wx: wx((a[0] + b[0]) / 2), wy: wy((a[1] + b[1]) / 2) };
    }
  });
  cv.addEventListener('pointermove', e => {
    const p = pos(e);
    if (!P.has(e.pointerId)) { if (S.onHover) S.onHover(wx(p[0]), wy(p[1])); return; }
    P.set(e.pointerId, p);
    if (pinch && P.size >= 2) {
      const [a, b] = [...P.values()], d = Math.hypot(a[0] - b[0], a[1] - b[1]), mx = (a[0] + b[0]) / 2, my = (a[1] + b[1]) / 2;
      const z = clamp(pinch.z * d / Math.max(10, pinch.d), 0.18, 64);
      setCam(pinch.wx - (mx - S.W / 2) / z, pinch.wy - (my - S.H / 2) / z, z); moved = true; return;
    }
    if (!drag) return;
    if (drag.tool) { moved = true; if (S.grabMove) S.grabMove(wx(p[0]), wy(p[1])); return; }
    if (Math.hypot(p[0] - drag.x, p[1] - drag.y) > 6) moved = true;
    if (moved) setCam(drag.cx - (p[0] - drag.x) / S.cam.z, drag.cy - (p[1] - drag.y) / S.cam.z, S.cam.z);
  });
  const up = e => {
    const p = pos(e); P.delete(e.pointerId); clearTimeout(lp);
    if (P.size < 2) pinch = null;
    if (drag && drag.tool) { drag = null; if (S.grabEnd) S.grabEnd(); return; }
    if (drag && !moved && now() - downAt < 500 && e.type === 'pointerup') onTap(wx(p[0]), wy(p[1]), p[0], p[1]);
    if (P.size === 0) drag = null;
  };
  cv.addEventListener('pointerup', up); cv.addEventListener('pointercancel', up);
  cv.addEventListener('wheel', e => { e.preventDefault(); const p = pos(e); zoomAt(p[0], p[1], Math.exp(-e.deltaY * (e.ctrlKey ? 0.01 : 0.0022))); }, { passive: false });
  cv.addEventListener('contextmenu', e => e.preventDefault());
}

/* ---------- いちばん近いもの ---------- */
function nearSeg(x, y, rpx, pred) {
  const it = S.vis; if (!it) return null;
  let best = null; const r = rpx / S.cam.z;
  for (const s of it.segs.values()) {
    if (pred && !pred(s)) continue;
    const b = s.bb; if (x < b[0] - r || x > b[2] + r || y < b[1] - r || y > b[3] + r) continue;
    const P = s.P; let acc = 0;
    for (let i = 0; i + 1 < s.np; i++) {
      const ax = P[2 * i], ay = P[2 * i + 1], bx = P[2 * i + 2], by = P[2 * i + 3], dx = bx - ax, dy = by - ay, L2 = dx * dx + dy * dy, L = Math.sqrt(L2);
      let t = L2 ? ((x - ax) * dx + (y - ay) * dy) / L2 : 0; t = clamp(t, 0, 1);
      const qx = ax + dx * t, qy = ay + dy * t, d = Math.hypot(x - qx, y - qy);
      if (d <= r + s.w / 2 && (!best || d < best.d)) best = { s, d, x: qx, y: qy, at: acc + L * t, ang: Math.atan2(dy, dx) };
      acc += L;
    }
  }
  return best;
}
// 線 s の上で、(x, y) にいちばん近いところ
function projSeg(s, x, y) {
  const P = s.P; let acc = 0, best = null;
  for (let i = 0; i + 1 < s.np; i++) {
    const ax = P[2 * i], ay = P[2 * i + 1], bx = P[2 * i + 2], by = P[2 * i + 3], dx = bx - ax, dy = by - ay, L2 = dx * dx + dy * dy, L = Math.sqrt(L2);
    const t = L2 ? clamp(((x - ax) * dx + (y - ay) * dy) / L2, 0, 1) : 0, qx = ax + dx * t, qy = ay + dy * t, d = Math.hypot(x - qx, y - qy);
    if (!best || d < best.d) best = { s, d, x: qx, y: qy, at: acc + L * t, ang: Math.atan2(dy, dx) };
    acc += L;
  }
  return best;
}
function nearSta(x, y, rpx) {
  const it = S.vis; if (!it) return null; let best = null;
  for (const s of it.stas.values()) { const d = Math.hypot(s.fx - x, s.fy - y) * S.cam.z; if (d < rpx + (s.k === 'rail' ? s.pl / 100 * S.cam.z : 0) && (!best || d < best.d)) best = { s, d }; }
  return best;
}
function nearDep(x, y) {
  const it = S.vis; if (!it) return null;
  for (const d of it.deps.values()) { const P = depPoly(d); if (inPoly(x, y, P)) return d; }
  return null;
}
function inPoly(x, y, P) { let c = false; for (let i = 0, j = P.length - 1; i < P.length; j = i++) { if (((P[i][1] > y) !== (P[j][1] > y)) && (x < (P[j][0] - P[i][0]) * (y - P[i][1]) / (P[j][1] - P[i][1]) + P[i][0])) c = !c; } return c; }
function nearNode(x, y, rpx, pred) {
  const it = S.vis; if (!it) return null; let best = null;
  for (const n of it.nodes.values()) { if (pred && !pred(n)) continue; const d = Math.hypot(n.fx - x, n.fy - y) * S.cam.z; if (d < rpx && (!best || d < best.d)) best = { n, d }; }
  return best;
}

/* ---------- 道具 ---------- */
const TOOL_HINT = {
  look: '', land: '土地：2か所タップして四角くえらびます（区画は10m四方）',
  rail: '線路：タップして点をおきます。線路のはしから始めると延長、まん中から始めると分岐。点はドラッグで動かせます', road: '道路：タップして点をおきます。道路のはし・まん中から始めると、つながります。点はドラッグで動かせます',
  sta: '駅：ホームの起点をタップ（自分の線路の上）。バス停は道路の上をタップ', dep: '車両基地：自分の線路の上で起点をタップ（バスの営業所は道路の横をタップ）', del: 'こわす：自分の線・駅・車庫・建物をタップ'
};
function setTool(t) {
  if (S.toolEnd) { const f = S.toolEnd; S.toolEnd = null; f(); }
  S.tool = t; S.drawTool = null; S.toolState = null; S.addr.hidden = true; S.grab = S.grabMove = S.grabEnd = null; S.onLong = null; S.sel = null; S.routeHi = S.routeHi && S.keepRoute ? S.routeHi : null;
  S.wrap.querySelectorAll('[data-tool]').forEach(b => b.classList.toggle('on', b.dataset.tool === t));
  hint(TOOL_HINT[t] || ''); sheet(null);
  if (t === 'rail' || t === 'road') startDraw(t);
  if (t === 'land') startLand();
  S.dirty = true;
}
function onTap(x, y, px, py) {
  if (S.tapHook) return S.tapHook(x, y, px, py);
  const t = S.tool;
  if (t === 'look') return lookAt(x, y, px, py);
  if (t === 'sta') return staTap(x, y);
  if (t === 'dep') return depTap(x, y);
  if (t === 'del') return delTap(x, y);
}

/* ---- 見る ---- */
async function lookAt(x, y) {
  const st = nearSta(x, y, 14);
  if (st) return showSta(st.s);
  const dp = nearDep(x, y);
  if (dp) return showDep(dp);
  const hb = hitBld(x, y);
  if (hb) { const [bx, by] = hb.cell.split(',').map(Number); return showSpot(bx, by); }
  const sg = nearSeg(x, y, 8);
  if (sg && (S.cam.z >= 3 || sg.s.k === 'rail' || ['exp', 'nat'].includes(sg.s.c))) return showSeg(sg.s, sg);
  return showSpot(Math.floor(x * 5), Math.floor(y * 5));
}
// マスの上にあるもの（「駅：名前」「線路（路線名）・持ち主」など）：種類と名前を分けて出す（種類のことばだけ訳せるように）
function onH(n) {
  n = String(n || '');
  let m = /^(駅|バス停|車庫)：(.*)$/.exec(n);
  if (m) return `<span>${esc(m[1])}</span>：<span>${esc(m[2])}</span>`;
  m = /^(高速道路|国道|県道|府道|都道|道道|市道|私道|線路)(?:（(.*?)）)?(?:・(.*))?$/.exec(n);
  if (m) return `<span>${esc(m[1])}</span>${m[2] ? `（<span>${esc(m[2])}</span>）` : ''}${m[3] ? `・<span>${esc(m[3])}</span>` : ''}`;
  return esc(n);
}
const CLS_NAME = { exp: '高速道路', nat: '国道', pref: '県道', city: '市道', lane: '市道（細い道）', priv: '私道', rail: '線路' };
// ⌂：瑠璃市役所（中里区中央三丁目）のまん中（マス）
const HOME = [-3.1, 2.9];
// 都道府県道の名前：その場所の都道府県（瑠璃府なら府道）
const prefRoad = pref => /府$/.test(pref || '') ? '府道' : /都$/.test(pref || '') ? '都道' : /道$/.test(pref || '') ? '道道' : '県道';
// 線の制限速度のグラフ（よこ：線にそった長さ・たて：速さ。カーブがきついところほど低い）。at：タップしたところ（m）
function spdChart(cv, sp) {
  const dpr = Math.min(2, window.devicePixelRatio || 1), W = cv.clientWidth || 300, H = cv.clientHeight || 56;
  cv.width = W * dpr; cv.height = H * dpr; const g = cv.getContext('2d'); g.setTransform(dpr, 0, 0, dpr, 0, 0); g.clearRect(0, 0, W, H);
  const len = Math.max(1, sp.len), top = Math.max(120, Math.min(300, sp.max || 120)), X = m => 4 + m / len * (W - 8), Y = v => H - 4 - Math.min(v, top) / top * (H - 12);
  let m = 0;
  for (const [d, v] of sp.runs || []) {
    g.fillStyle = v < 60 ? '#e05252' : v < 100 ? '#f0a030' : v < 160 ? '#3a9a5a' : '#8cc8a0';
    g.fillRect(X(m), Y(v), Math.max(1, X(m + d) - X(m)), H - 4 - Y(v)); m += d;
  }
  g.strokeStyle = '#999'; g.lineWidth = 1; g.setLineDash([3, 3]); g.beginPath(); g.moveTo(4, Y(100)); g.lineTo(W - 4, Y(100)); g.stroke(); g.setLineDash([]);
  g.fillStyle = '#666'; g.font = '10px system-ui, sans-serif'; g.textBaseline = 'top'; g.fillText('100 km/h', 6, Math.max(0, Y(100) - 12));
  if (sp.at != null) { g.strokeStyle = '#1f5fbf'; g.lineWidth = 2; g.beginPath(); g.moveTo(X(sp.at), 2); g.lineTo(X(sp.at), H - 2); g.stroke(); }
}
// 駅の発着番線のことば（1番線 下り本線 など）
const TRK_D = { down: '下り', up: '上り', both: '両方' }, TRK_M = { main: '本線', side: '待避線' };
const TRK_L = { 'down:main': n => T(`${n}番線 下り本線`), 'up:main': n => T(`${n}番線 上り本線`), 'both:main': n => T(`${n}番線 上下の本線`),
                'down:side': n => T(`${n}番線 下り待避線`), 'up:side': n => T(`${n}番線 上り待避線`), 'both:side': n => T(`${n}番線 上下の待避線`) };
const trkL = (t, i) => (TRK_L[t.d + ':' + t.m] || (n => T(`${n}番線`)))(i + 1);
async function showSpot(cx, cy) {
  S.sel = { kind: 'cell', x: cx, y: cy }; S.dirty = true;
  const sh = sheet(`<h4>${Math.floor(cx / 5)}, ${Math.floor(cy / 5)}</h4><p class="muted small">しらべています…</p>`);
  const d = await api('mp_spot', { p_x: cx, p_y: cy }); if (!d || S.sheet !== sh || !S.sel || S.sel.x !== cx || S.sel.y !== cy) return;
  if (d.none) return sheet(`<h4>地図の外です</h4>`);
  const P = d.parcel; S.sel.parcel = P ? P.id : null; S.dirty = true;
  const on = (d.on || []).map(o => onH(o.name)).join('<br>');
  sheet(`<h4><span translate="no">${esc(d.addr.text)}</span>${d.addr.ban ? ` <span>${esc(d.addr.ban)}</span>` : ''}</h4>
    <div class="mp-kv"><b>地形</b><span><span>${esc(d.ter)}</span>${d.elev ? `<small>（標高 約${d.elev}m）</small>` : ''}</span><b>地目</b><span>${esc(d.chimoku)}</span>
      <b>用途地域</b><span>${esc(d.zname)}</span><b>人の多さ</b><span>${fmt(d.dens)} 人/km²</span>
      ${d.cval != null ? `<b>地価</b><span>${X(d.cval)}（1区画・100㎡）</span>` : ''}
      ${d.cval0 != null ? `<b>評価額</b><span><span>${X(d.cval0)}（1区画・100㎡）</span><br><small class="muted">税・家賃・使用料は評価額で計算します</small></span>` : ''}
      <b>持ち主</b><span>${P ? `<span>${esc(P.owner)}</span>${P.mine ? '<small>（あなた）</small>' : ''}` : d.pub ? '公衆用道路' : '国'}</span>
      ${P ? `<b>筆</b><span>${esc(P.ban)}・${fmt(P.n * 100)}㎡・地価 ${X(P.val)}</span>` : ''}
      ${P && P.val0 != null ? `<b>筆の評価額</b><span>${X(P.val0)}</span>` : ''}
      ${P && P.sale != null ? `<b>売り出し</b><span>${X(P.sale)}</span>` : ''}
      ${P && !P.gov ? `<b>貸出料</b><span>${P.rent != null ? `<span>1区画・1日 ${X(P.rent)}</span><small>（線路・道路・駅・車庫に、申請なしで使えます）</small>` : '<span>貸していません</span>'}${P.mine ? `<small>・標準 ${X(P.std)}</small>` : ''}</span>` : ''}
      ${P && !P.mine && (P.reqs || []).length ? `<b>申請</b><span>${P.reqs.map(r => `<span>${esc(r.who)}</span>：<b>${esc(LRS[r.st] || r.st)}</b>${r.st === 'ok' ? `<small>（1区画・1日 ${X(r.fee)}）</small>` : ''}`).join('<br>')}</span>` : ''}
      ${P && P.mine && P.nreq ? `<b>申請</b><span><a href="#" data-lreqs>返事まち ${P.nreq}件</a></span>` : ''}
      ${P && P.b ? bldRow(P.b, P.mine) : ''}
      ${on ? `<b>あるもの</b><span>${on}</span>` : ''}
      ${(d.leases || []).length ? `<b>使用料</b><span>${d.leases.map(l => `<span>${esc(l.who)}</span>：<span>1日 ${X(l.fee)}</span>`).join('<br>')}</span>` : ''}
    </div>
    <div class="mp-row">${!P && d.buy ? `<button class="btn main" data-buyhere>ここの土地を買う</button>` : ''}
      ${P && !P.mine && P.sale != null ? `<button class="btn main" data-pbuy>この筆を買う（${X(Math.ceil(P.sale * 1.03))}）</button>` : ''}
      ${!P && !d.buy && d.why ? `<span class="muted small">${esc(d.why)}</span>` : ''}
      ${P && P.b ? `<button class="btn main" data-bopen>${P.gov ? '建物を見る' : '部屋・テナント'}</button>` : ''}
      ${P && P.mine ? `<button class="btn" data-sell>${P.sale != null ? '売り出しをやめる' : '売りに出す'}</button>
        ${P.b ? '' : '<button class="btn" data-bld>建物を建てる</button>'}<button class="btn" data-split>分筆</button><button class="btn" data-merge>合筆</button><button class="btn" data-rent>貸出料</button>` : ''}
      ${P && !P.mine && !P.gov && P.rent == null && S.as !== 'gov' && !(P.reqs || []).some(r => r.as === S.as && r.st !== 'no') ? `<button class="btn" data-lreq1>使う申請（${esc(asName())}）</button>` : ''}</div>`, s => {
    const q = k => s.querySelector(k);
    if (q('[data-rent]')) q('[data-rent]').onclick = () => parcelRent(P, cx, cy);
    if (q('[data-lreqs]')) q('[data-lreqs]').onclick = ev => { ev.preventDefault(); openLandReqs(); };
    if (q('[data-lreq1]')) q('[data-lreq1]').onclick = async () => {
      const msg = prompt(T('持ち主へのひとこと（なくてもよい）。許可されると、この筆を線路・道路・駅・車庫に使えます'), ''); if (msg == null) return;
      if (await api('mp_land_req', { p_parcels: [P.id], p_msg: msg, p_as: S.as }, '申請しました。返事がきたら通知がとどきます')) showSpot(cx, cy);
    };
    if (q('[data-buyhere]')) q('[data-buyhere]').onclick = () => { setTool('land'); S.toolState.a = [cx, cy]; landSheet(); S.dirty = true; };
    if (q('[data-pbuy]')) q('[data-pbuy]').onclick = () => parcelBuy(P);
    if (q('[data-sell]')) q('[data-sell]').onclick = () => parcelSell(P);
    if (q('[data-bld]')) q('[data-bld]').onclick = () => bldStart(P);
    if (q('[data-bopen]')) q('[data-bopen]').onclick = () => openBld(P.b.id);
    if (q('[data-split]')) q('[data-split]').onclick = () => startSplit(P);
    if (q('[data-merge]')) q('[data-merge]').onclick = () => startMerge(P);
  });
  S.addr.hidden = false; S.addr.textContent = d.addr.text + (d.addr.ban ? ' ' + d.addr.ban : '');
}
function showSeg(s, hit) {
  S.sel = { kind: 'seg', id: s.id }; S.dirty = true;
  const own = s.o === 'gov' ? '国' : (S.vis.names[s.o] || '');
  sheet(`<h4><span data-cls>${esc(CLS_NAME[s.c] || s.c)}</span>${s.n ? `・<span>${esc(s.n)}</span>` : ''}</h4><p class="small muted" data-addr translate="no" style="margin:0"></p>
    <div class="mp-kv"><b>持ち主</b><span><span>${esc(own)}</span>${s.mine && s.o !== 'gov' ? '<small>（あなた）</small>' : ''}</span>
      <b>長さ</b><span>${fmt(Math.round(s.len * 50))} m</span>
      ${s.k === 'road' ? `<b>車線</b><span>${s.l ? '片側' + s.l + '車線' : '中央線なし'}</span>` : `<b>線路</b><span>${s.dbl ? '複線' : '単線'}・${s.el ? '電化' : '非電化'}</span>`}
      <b>制限速度</b><span data-spd><span>${s.v} km/h</span></span></div>
    ${s.k === 'rail' ? '<canvas class="mp-spd" data-spdc hidden></canvas>' : ''}
    ${s.mine ? `<div class="mp-row"><button class="btn" data-edit>形を直す</button><button class="btn" data-split>ここで分ける</button><button class="btn" data-opt>${s.k === 'rail' ? '複線・電化・名前' : '車線・名前'}</button><button class="btn" data-del>こわす</button></div>` : ''}`, sh => {
    const q = k => sh.querySelector(k);
    if (q('[data-edit]')) q('[data-edit]').onclick = () => startEdit(s);
    if (q('[data-split]')) q('[data-split]').onclick = async () => { if (await api('mp_seg_split', { p_id: s.id, p_x: hit.x, p_y: hit.y }, '分けました')) { refreshBox(...s.bb); sheet(null); } };
    if (q('[data-opt]')) q('[data-opt]').onclick = () => segOpts(s);
    if (q('[data-del]')) q('[data-del]').onclick = () => segDel(s);
  });
  const still = () => S.sel && S.sel.kind === 'seg' && S.sel.id === s.id;
  if (hit) addrInto(hit.x, hit.y, still).then(d => {
    if (d && d.addr && s.c === 'pref' && still()) { const e = S.sheet.querySelector('[data-cls]'); if (e) e.textContent = prefRoad(d.addr.pref); }
  });
  api('mp_seg_speed', { p_id: s.id, p_x: hit ? hit.x : null, p_y: hit ? hit.y : null }).then(sp => {
    if (!sp || !still()) return;
    const e = S.sheet.querySelector('[data-spd]');
    if (e) e.innerHTML = s.k === 'rail' ? `${sp.here != null ? `<span>ここ ${sp.here} km/h</span><br>` : ''}<small class="muted">${sp.min === sp.max ? `<span>この線 ${sp.min} km/h</span>` : `<span>この線 ${sp.min}〜${sp.max} km/h</span>`}${sp.rmin && sp.rmin < 99999 ? `<br><span>いちばんきついカーブ 半径 ${fmt(sp.rmin)} m</span>` : ''}</small>` : `<span>${sp.here} km/h</span>`;
    const cv = S.sheet.querySelector('[data-spdc]'); if (cv) { cv.hidden = false; spdChart(cv, sp); }
  });
}
// 住所をシートと上の帯に
async function addrInto(x, y, still) {   // x, y：マス（50m）の座標。その場所の区画（10m）の住所
  const d = await api('mp_spot', { p_x: Math.floor(x * 5), p_y: Math.floor(y * 5) }); if (!d || !d.addr || !still()) return null;
  const e = S.sheet.querySelector('[data-addr]'); if (e) e.textContent = d.addr.text;
  S.addr.hidden = false; S.addr.textContent = d.addr.text;
  return d;
}
function segOpts(s) {
  const st = { dbl: s.dbl, el: s.el, l: s.l, name: s.n || '', q: null, quoting: false, seq: 0 };
  const same = () => st.dbl === s.dbl && st.el === s.el && st.l === s.l;   // 名前だけ
  const quote = async () => {
    const my = ++st.seq; st.quoting = true; draw();
    const q = await api('mp_seg_opts', { p_id: s.id, p_dbl: st.dbl, p_elec: st.el, p_name: st.name, p_dry: true, p_lanes: st.l });
    if (st.seq !== my) return;
    st.quoting = false; st.q = q; draw();
  };
  const changed = () => { st.seq++; st.quoting = false; st.q = null; draw(); };
  const draw = () => {
    const q = st.q;
    sheet(`<h4>${s.k === 'rail' ? '線路' : '道路'}の設定</h4>
      ${s.k === 'rail' ? `<div class="mp-row"><span class="mp-seg"><button data-d="0" class="${!st.dbl ? 'on' : ''}">単線</button><button data-d="1" class="${st.dbl ? 'on' : ''}">複線</button></span>
        <span class="mp-seg"><button data-e="0" class="${!st.el ? 'on' : ''}">非電化</button><button data-e="1" class="${st.el ? 'on' : ''}">電化</button></span></div>`
      : `<div class="mp-row">片側 <span class="mp-seg">${[0, 1, 2, 3].map(n => `<button data-l="${n}" class="${st.l === n ? 'on' : ''}">${n ? n + '車線' : '細い道'}</button>`).join('')}</span></div>`}
      <div class="mp-row"><input class="mp-inp" data-nm placeholder="名前（路線名など）" value="${esc(st.name)}"></div>
      <div class="mp-row">${same() ? '' : q ? `<span class="mp-cost">${q.cost > 0 ? '工事費 ' + X(q.cost) : '工事費なし'}</span>` : st.quoting ? '<span class="muted small">見つもり中…</span>' : '<button class="btn" data-est>見つもる</button><span class="muted small">工事費を出してから、変えられます</span>'}</div>
      ${!same() && q ? needH(q.need) : ''}
      <p class="muted small">もとにもどしても（単線にする・車線をへらす）お金はもどりません</p>
      <div class="mp-row"><button class="btn main" data-ok ${same() || (q && !hasNeed(q)) ? '' : 'disabled'}>この設定にする</button></div>`, sh => {
      needBind(sh, !same() && q && q.need, () => quote());
      sh.querySelectorAll('[data-d]').forEach(b => b.onclick = () => { st.dbl = b.dataset.d === '1'; changed(); });
      sh.querySelectorAll('[data-e]').forEach(b => b.onclick = () => { st.el = b.dataset.e === '1'; changed(); });
      sh.querySelectorAll('[data-l]').forEach(b => b.onclick = () => { st.l = Number(b.dataset.l); changed(); });
      { const es = sh.querySelector('[data-est]'); if (es) es.onclick = () => quote(); }
      sh.querySelector('[data-nm]').onchange = e => { st.name = e.target.value; };
      sh.querySelector('[data-ok]').onclick = async () => {
        st.name = sh.querySelector('[data-nm]').value;
        if (await api('mp_seg_opts', { p_id: s.id, p_dbl: st.dbl, p_elec: st.el, p_name: st.name, p_dry: false, p_lanes: st.l }, '設定を変えました')) { refreshBox(...s.bb); sheet(null); }
      };
    });
  };
  draw();
}
async function segDel(s) {
  if (!confirm(T('この線をこわしますか？（工事費はもどりません）'))) return;
  if (await api('mp_seg_del', { p_id: s.id }, 'こわしました')) { refreshBox(...s.bb); sheet(null); S.sel = null; }
}
function showSta(s) {
  S.sel = { kind: 'sta', id: s.id }; S.dirty = true;
  sheet(`<h4>${s.k === 'rail' ? '🚉 ' : '🚏 '}<span>${esc(s.n)}</span>${s.k === 'rail' ? '<span>駅</span>' : ''}</h4><p class="small muted" data-addr translate="no" style="margin:0"></p>
    <div class="mp-kv"><b>持ち主</b><span><span>${esc(S.vis.names[s.o] || '')}</span>${s.mine ? '<small>（あなた）</small>' : ''}</span>
      ${s.k === 'rail' ? `<b>ホーム</b><span>${s.pl} m・${s.tr}番線まで</span>` : ''}
      ${s.k === 'rail' && s.tk ? `<b>発着番線</b><span>${s.tk.map((t, i) => `<span>${esc(trkL(t, i))}</span>`).join('<br>')}</span>` : ''}
      ${s.k === 'bus' ? `<b>貸し出し</b><span>${s.ln != null ? `<span>ほかの人・会社に貸しています（1系統・1日 ${X(s.ln)}）</span>` : '<span>ほかの人・会社には貸していません</span>'}</span>` : ''}
      <b>系統</b><span>${(s.rt || []).map(r => `<a href="#" data-rt="${r.id}" style="color:${esc(r.c)};font-weight:800">■ ${esc(r.n)}</a>`).join('<br>') || 'なし'}</span></div>
    ${s.mine ? `<div class="mp-row"><button class="btn" data-ren>名前を変える</button>${s.k === 'bus' ? '<button class="btn" data-lend>貸し出し</button>' : '<button class="btn" data-trk>発着番線</button>'}<button class="btn" data-del>こわす</button></div>` : ''}`, sh => {
    sh.querySelectorAll('[data-rt]').forEach(a => a.onclick = ev => { ev.preventDefault(); openDia(Number(a.dataset.rt)); });
    const tk = sh.querySelector('[data-trk]'); if (tk) tk.onclick = () => trkEdit(s);
    const ld = sh.querySelector('[data-lend]'); if (ld) ld.onclick = async () => {
      const v = prompt(T('ほかの人・会社に貸す使用料（1系統・1日・X）。空にすると貸しません（いま使っている系統は、そのまま使えます）'), s.ln != null ? String(s.ln) : '1000');
      if (v == null) return;
      const t = String(v).replace(/[,，\s]/g, ''), n = t === '' ? null : Number(t);
      if (n != null && !(n >= 0)) return toast('数字を入れてください');
      const r = await api('mp_stop_lend', { p_id: s.id, p_lend: n }, n == null ? '貸すのをやめました' : '貸し出します');
      if (r) { s.ln = r.lend; refreshBox(s.fx - 3, s.fy - 3, s.fx + 3, s.fy + 3); showSta(s); }
    };
    const r = sh.querySelector('[data-ren]'); if (r) r.onclick = async () => { const nm = prompt(T('新しい名前'), s.n); if (nm && await api('mp_sta_edit', { p_id: s.id, p_name: nm, p_del: false }, '名前を変えました')) refreshBox(s.fx - 3, s.fy - 3, s.fx + 3, s.fy + 3); };
    const d = sh.querySelector('[data-del]'); if (d) d.onclick = async () => { if (confirm(T('こわしますか？（工事費はもどりません）')) && await api('mp_sta_edit', { p_id: s.id, p_name: null, p_del: true }, 'こわしました')) { refreshBox(s.fx - 3, s.fy - 3, s.fx + 3, s.fy + 3); sheet(null); } };
  });
  addrInto(s.fx, s.fy, () => S.sel && S.sel.kind === 'sta' && S.sel.id === s.id);
}
// 駅の発着番線を決める：番線ごとに 下り・上り・両方／本線・待避線（待避線があると、優先番号の低い列車がそこで待避する）
async function trkEdit(s) {
  const d = await api('mp_sta_trk', { p_sta: s.id }); if (!d) return;
  const cur = d.trk.map(t => ({ ...t }));
  const m = modal(['発着番線', ''], null);
  const draw = () => m.set('発着番線', `<p class="small" style="margin:0"><b>${esc(d.name)}</b>（<span>${d.tracks}番線まで</span>）</p>
      <div class="mp-list">${cur.map((t, i) => `<div class="mp-row small" style="align-items:center;margin-top:4px"><b style="min-width:4.5em">${i + 1}番線</b>
        <span class="mp-seg">${['down', 'up', 'both'].map(k => `<button data-td="${i}:${k}" class="${t.d === k ? 'on' : ''}">${TRK_D[k]}</button>`).join('')}</span>
        <span class="mp-seg">${['main', 'side'].map(k => `<button data-tm="${i}:${k}" class="${t.m === k ? 'on' : ''}">${TRK_M[k]}</button>`).join('')}</span></div>`).join('')}</div>
      <div class="mp-row"><button class="btn main" data-ok>決める</button><button class="btn" data-def>いつもの決まりにもどす</button></div>
      <p class="muted small">列車は、ふだんはその向きの本線に止まります（採時駅で番線を決めた列車は、その番線）。その向きで使える番線が2つ以上ある駅は待避できます。優先番号の大きい列車は待避線で待ち、あとから来る優先番号の小さい列車に先をゆずります</p>`, b => {
    b.querySelectorAll('[data-td]').forEach(x => x.onclick = () => { const [i, k] = x.dataset.td.split(':'); cur[Number(i)].d = k; draw(); });
    b.querySelectorAll('[data-tm]').forEach(x => x.onclick = () => { const [i, k] = x.dataset.tm.split(':'); cur[Number(i)].m = k; draw(); });
    b.querySelector('[data-ok]').onclick = async () => { const r = await api('mp_sta_trk_set', { p_sta: s.id, p_trk: cur }, '決めました'); if (r) { s.tk = r.trk; m.close(); showSta(s); } };
    b.querySelector('[data-def]').onclick = async () => { const r = await api('mp_sta_trk_set', { p_sta: s.id, p_trk: null }, 'もどしました'); if (r) { s.tk = r.trk; m.close(); showSta(s); } };
  });
  draw();
}
function showDep(d) {
  S.sel = { kind: 'dep', id: d.id }; S.dirty = true;
  sheet(`<h4>🏭 ${esc(d.n)}</h4><div class="mp-kv"><b>種類</b><span>${d.k === 'rail' ? '車両基地' : 'バスの営業所'}（${d.sz}）</span><b>入る数</b><span>${d.k === 'rail' ? `${d.cap}両` : `${d.cap}台`}</span></div>
    ${d.mine ? `<div class="mp-row"><button class="btn" data-cars>車両を見る</button><button class="btn" data-ren>名前を変える</button><button class="btn" data-del>こわす</button></div>` : ''}`, sh => {
    const c = sh.querySelector('[data-cars]'); if (c) c.onclick = () => openCars(d.id);
    const r = sh.querySelector('[data-ren]'); if (r) r.onclick = async () => { const nm = prompt(T('新しい名前'), d.n); if (nm && await api('mp_dep_edit', { p_id: d.id, p_name: nm, p_del: false }, '名前を変えました')) refreshBox(d.fx - 8, d.fy - 8, d.fx + 8, d.fy + 8); };
    const x = sh.querySelector('[data-del]'); if (x) x.onclick = async () => { if (confirm(T('こわしますか？（工事費はもどりません）')) && await api('mp_dep_edit', { p_id: d.id, p_name: null, p_del: true }, 'こわしました')) { refreshBox(d.fx - 8, d.fy - 8, d.fx + 8, d.fy + 8); sheet(null); } };
  });
}

/* ---- 土地（区画：10m四方。マスの 1/5） ---- */
const cellAt = (x, y) => [Math.floor(x * 5), Math.floor(y * 5)];
function startLand() {
  S.toolState = { a: null, b: null };
  S.drawTool = (g, z) => {
    const st = S.toolState; if (!st || !st.a) return;
    const b = st.b || st.a, x0 = Math.min(st.a[0], b[0]) / 5, y0 = Math.min(st.a[1], b[1]) / 5, x1 = (Math.max(st.a[0], b[0]) + 1) / 5, y1 = (Math.max(st.a[1], b[1]) + 1) / 5;
    g.fillStyle = 'rgba(30,110,230,.18)'; g.fillRect(sx(x0), sy(y0), (x1 - x0) * z, (y1 - y0) * z);
    g.strokeStyle = '#1f5fbf'; g.lineWidth = 2; g.setLineDash([6, 4]); g.strokeRect(sx(x0), sy(y0), (x1 - x0) * z, (y1 - y0) * z); g.setLineDash([]);
  };
  S.tapHook = (x, y) => {
    if (S.cam.z < 12) { setCam(x, y, 30); hint('区画は10m四方です。近づいてからえらびます'); return; }
    const st = S.toolState, t = cellAt(x, y);
    if (!st.a || st.b) { st.a = t; st.b = null; landSheet(); }
    else { st.b = t; landSheet(); }
    S.dirty = true;
  };
  S.toolEnd = () => { S.tapHook = null; S.toolState = null; };
}
function landRect() {
  const st = S.toolState; if (!st || !st.a) return null;
  const b = st.b || st.a;
  return [Math.min(st.a[0], b[0]), Math.min(st.a[1], b[1]), Math.max(st.a[0], b[0]), Math.max(st.a[1], b[1])];
}
async function landSheet() {
  const r = landRect(); if (!r) return;
  const n = (r[2] - r[0] + 1) * (r[3] - r[1] + 1);
  if (n > 1600) return sheet(`<h4>${fmt(n)}区画</h4><p class="mp-warn">一度にえらべるのは1600区画（400m×400m）までです</p>`);
  sheet(`<h4>${fmt(n)}区画 えらびました</h4><p class="muted small">見つもっています…</p>`);
  const q = await api('mp_land_buy', { p_rect: r, p_as: S.as, p_dry: true });
  const r2 = landRect(); if (!q || !r2 || r2.join() !== r.join()) return;
  const why = q.why || {}, sk = [why.road && `道路 ${why.road}`, why.water && `水の上 ${why.water}`, why.park && `公園 ${why.park}`, why.owned && `持ち主がいる ${why.owned}`, why.other && `そのほか ${why.other}`].filter(Boolean).map(t => `<span>${esc(t)}</span>`).join('・');
  sheet(`<h4>${fmt(n)}区画 えらびました</h4>
    <div class="mp-kv"><b>買える</b><span><span>${fmt(q.n)}区画（${fmt(q.n * 100)}㎡）</span>・<span class="mp-cost">${X(q.total)}</span></span>
      ${q.parcels > 1 ? `<b>筆</b><span>${q.parcels}筆にわかれます（道路・町字でわける）</span>` : ''}
      ${sk ? `<b>買えない</b><span>${sk}</span>` : ''}
      <b>固定資産税</b><span>1日 約${X(q.tax_day)}</span></div>
    <div class="mp-row">${q.n ? `<button class="btn main" data-buy>${esc(asName())}の名義で買う</button>` : ''}</div>
    <p class="muted small">もう一度2か所タップすると、えらびなおせます。道路の部分は国の土地（公衆用道路）なので買えません</p>`, s => {
    const b = s.querySelector('[data-buy]'); if (b) b.onclick = async () => {
      const x = await api('mp_land_buy', { p_rect: r, p_as: S.as, p_dry: false });
      if (x) { toast(T(`${fmt(x.n)}区画（${x.parcels}筆）を買いました（${fmt(x.total)} X）`)); refreshBox(r[0] / 5 - 1, r[1] / 5 - 1, r[2] / 5 + 2, r[3] / 5 + 2); sheet(null); S.toolState.a = S.toolState.b = null; S.dirty = true; }
    };
  });
}
const pBox = P => P.bb ? [P.bb[0] / 5 - 1, P.bb[1] / 5 - 1, P.bb[2] / 5 + 1, P.bb[3] / 5 + 1] : null;
function refreshP(P) { const b = pBox(P); if (b) refreshBox(...b); else for (const c of S.cells.values()) c.stale = true; S.dirty = true; }
async function parcelBuy(P) {
  const q = await api('mp_parcel_buy', { p_id: P.id, p_as: S.as, p_dry: true }); if (!q) return;
  if (!confirm(T(`${P.ban}（${fmt(P.n * 100)}㎡）を ${fmt(q.price)} X ＋ 取得税 ${fmt(q.tax)} X で買います。よろしいですか？`))) return;
  if (await api('mp_parcel_buy', { p_id: P.id, p_as: S.as, p_dry: false }, '買いました')) { refreshP(P); sheet(null); }
}
async function parcelSell(P) {
  let price = null;
  if (P.sale == null) { const v = prompt(T(`${P.ban}（${fmt(P.n * 100)}㎡）の値段（X）`), String(P.val || '')); if (!v) return; price = Number(String(v).replace(/[^\d]/g, '')); if (!price) return; }
  if (await api('mp_parcel_sell', { p_ids: [P.id], p_price: price, p_as: S.as }, price == null ? '売り出しをやめました' : '売りに出しました')) { refreshP(P); sheet(null); }
}
// 貸出料（1区画・1日）：決めておくと、ほかの人・会社が申請なしで線路・道路・駅・車庫に使える。空にすると貸さない
async function parcelRent(P, cx, cy) {
  const v = prompt(T(`${P.ban}の貸出料（1区画・1日・X）。ほかの人・会社が、申請なしで線路・道路・駅・車庫に使えます。空にすると貸しません（標準 ${P.std} X）`), P.rent != null ? String(P.rent) : String(P.std));
  if (v == null) return;
  const t = String(v).replace(/[,，\s]/g, ''), n = t === '' ? null : Number(t);
  if (n != null && !(n >= 0)) return toast('数字を入れてください');
  if (await api('mp_parcel_rent', { p_ids: [P.id], p_rent: n }, n == null ? '貸すのをやめました（つくってあるものは、そのままです）' : '貸出料を決めました')) showSpot(cx, cy);
}
// 分筆：筆の中で2か所タップして四角をえらぶ
function startSplit(P) {
  setTool('look'); S.sel = { kind: 'cell', x: P.bb[0], y: P.bb[1], parcel: P.id };
  S.toolState = { a: null, b: null, split: P };
  hint('分筆：分ける部分を、2か所タップして四角くえらびます');
  S.drawTool = (g, z) => {
    const st = S.toolState; if (!st || !st.a) return;
    const b = st.b || st.a, x0 = Math.min(st.a[0], b[0]) / 5, y0 = Math.min(st.a[1], b[1]) / 5, x1 = (Math.max(st.a[0], b[0]) + 1) / 5, y1 = (Math.max(st.a[1], b[1]) + 1) / 5;
    g.fillStyle = 'rgba(255,152,0,.25)'; g.fillRect(sx(x0), sy(y0), (x1 - x0) * z, (y1 - y0) * z);
    g.strokeStyle = '#e67e00'; g.lineWidth = 2; g.setLineDash([6, 4]); g.strokeRect(sx(x0), sy(y0), (x1 - x0) * z, (y1 - y0) * z); g.setLineDash([]);
  };
  S.tapHook = async (x, y) => {
    const st = S.toolState, t = cellAt(x, y);
    if (!st.a || st.b) { st.a = t; st.b = null; } else st.b = t;
    S.dirty = true;
    const r = landRect(); if (!r) return;
    const q = await api('mp_parcel_split', { p_id: P.id, p_rect: r, p_as: S.as, p_dry: true });
    if (!q) return;
    sheet(`<h4>分筆：${esc(P.ban)}</h4><div class="mp-kv"><b>分ける部分</b><span>${fmt(q.n * 100)}㎡ → ${esc(q.ban)}</span><b>のこる部分</b><span>${fmt(q.rest * 100)}㎡</span></div>
      <div class="mp-row"><button class="btn main" data-ok>分筆する</button></div>`, s => {
      s.querySelector('[data-ok]').onclick = async () => { if (await api('mp_parcel_split', { p_id: P.id, p_rect: r, p_as: S.as, p_dry: false }, '分筆しました')) { refreshP(P); setTool('look'); } };
    });
  };
  S.toolEnd = () => { S.tapHook = null; S.toolState = null; };
  sheet(`<h4>分筆：${esc(P.ban)}</h4><p class="small">分ける部分を、地図で2か所タップしてえらんでください</p>`);
  S.onSheetClose = () => setTool('look');
  S.dirty = true;
}
// 合筆：となりあう自分の筆をタップしてえらぶ
function startMerge(P) {
  setTool('look');
  const marks = new Map([[P.id, P]]);
  S.toolState = { marks };
  hint('合筆：となりの自分の筆をタップしてえらびます（同じ町字・建物なし）');
  const draw = () => sheet(`<h4>合筆</h4><p class="small">${[...marks.values()].map(p => esc(p.ban)).join('・')}（<span>${marks.size}筆</span>）</p>
    <div class="mp-row"><button class="btn main" data-ok ${marks.size >= 2 ? '' : 'disabled'}>合筆する</button></div>`, s => {
    s.querySelector('[data-ok]').onclick = async () => {
      const r = await api('mp_parcel_merge', { p_ids: [...marks.keys()], p_as: S.as, p_dry: false });
      if (r) { toast(T(`合筆しました（${r.ban}・${fmt(r.n * 100)}㎡）`)); for (const p of marks.values()) refreshP(p); setTool('look'); }
    };
  });
  S.tapHook = (x, y) => {
    const [cx, cy] = cellAt(x, y), key = cx + ',' + cy;
    const p = [...(S.vis ? S.vis.parcels.values() : [])].find(q => q.cells.has(key));
    if (!p || p.own !== 2) return toast('自分の筆をタップしてください');
    if (marks.has(p.id) && marks.size > 1) marks.delete(p.id); else marks.set(p.id, p);
    S.dirty = true; draw();
  };
  S.toolEnd = () => { S.tapHook = null; S.toolState = null; };
  S.onSheetClose = () => setTool('look');
  draw(); S.dirty = true;
}

/* ---- 線をひく（線路・道路）：点をおくと、なめらかな曲線（セントリペタル・キャットムル–ロム）になる ---- */
// 点の列 → なめらかな線（0.5マスごとの点）。phA・phB は、はしの向きを決める見えない点
function spline(ctrl, phA, phB) {
  const n = ctrl.length; if (n < 2) return ctrl.slice();
  const Q = [phA || [2 * ctrl[0][0] - ctrl[1][0], 2 * ctrl[0][1] - ctrl[1][1]], ...ctrl, phB || [2 * ctrl[n - 1][0] - ctrl[n - 2][0], 2 * ctrl[n - 1][1] - ctrl[n - 2][1]]];
  const dense = [ctrl[0]];
  const tj = (a, b) => Math.pow(Math.hypot(b[0] - a[0], b[1] - a[1]), 0.5) || 1e-4;
  for (let i = 1; i < Q.length - 2; i++) {
    const p0 = Q[i - 1], p1 = Q[i], p2 = Q[i + 1], p3 = Q[i + 2];
    const t0 = 0, t1 = t0 + tj(p0, p1), t2 = t1 + tj(p1, p2), t3 = t2 + tj(p2, p3);
    const steps = Math.max(6, Math.ceil(Math.hypot(p2[0] - p1[0], p2[1] - p1[1]) * 4));
    for (let k = 1; k <= steps; k++) {
      const t = t1 + (t2 - t1) * k / steps;
      const L = (a, b, ta, tb) => [(tb - t) / (tb - ta) * a[0] + (t - ta) / (tb - ta) * b[0], (tb - t) / (tb - ta) * a[1] + (t - ta) / (tb - ta) * b[1]];
      const A1 = L(p0, p1, t0, t1), A2 = L(p1, p2, t1, t2), A3 = L(p2, p3, t2, t3), B1 = L(A1, A2, t0, t2), B2 = L(A2, A3, t1, t3);
      dense.push(L(B1, B2, t1, t2));
    }
  }
  return resample(dense, 0.5);
}
function resample(P, step) {
  if (P.length < 2) return P.slice();
  const out = [P[0]]; let acc = 0;
  for (let i = 1; i < P.length; i++) {
    let ax = P[i - 1][0], ay = P[i - 1][1]; const bx = P[i][0], by = P[i][1];
    let seg = Math.hypot(bx - ax, by - ay);
    while (acc + seg >= step) { const t = (step - acc) / seg; ax += (bx - ax) * t; ay += (by - ay) * t; out.push([ax, ay]); seg = Math.hypot(bx - ax, by - ay); acc = 0; }
    acc += seg;
  }
  const l = P[P.length - 1], o = out[out.length - 1];
  if (Math.hypot(l[0] - o[0], l[1] - o[1]) > step * 0.3) out.push(l); else out[out.length - 1] = l;
  return out;
}
function minRadius(P) {
  let mr = 1e9; const g = 3;
  for (let i = g; i < P.length - g; i++) {
    const a = P[i - g], b = P[i], c = P[i + g];
    const A = Math.hypot(b[0] - c[0], b[1] - c[1]), B = Math.hypot(a[0] - c[0], a[1] - c[1]), C = Math.hypot(a[0] - b[0], a[1] - b[1]);
    const ar = Math.abs((b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])) / 2;
    if (ar > 1e-6) mr = Math.min(mr, A * B * C / (4 * ar));
  }
  return mr;
}
const toInts = P => P.flatMap(p => [Math.round(p[0] * 100), Math.round(p[1] * 100)]);

/* ---- 直線＋カーブ（A列車ふう）：点は角。角に半径 R の円弧を入れる。はしをつないだときは、その向きから円弧で出る・入る ---- */
const V2 = { sub: (a, b) => [a[0] - b[0], a[1] - b[1]], add: (a, b) => [a[0] + b[0], a[1] + b[1]], mul: (a, k) => [a[0] * k, a[1] * k], len: a => Math.hypot(a[0], a[1]),
             nrm: a => { const l = Math.hypot(a[0], a[1]) || 1; return [a[0] / l, a[1] / l]; }, cross: (a, b) => a[0] * b[1] - a[1] * b[0], dot: (a, b) => a[0] * b[0] + a[1] * b[1],
             rot90: a => [-a[1], a[0]], rotm90: a => [a[1], -a[0]] };
// 円弧の点（中心 c・半径 r・はじめの角度 a0 から da（左回り +）だけ）
function arcPts(c, r, a0, da) {
  const n = Math.max(2, Math.ceil(Math.abs(da) * r / 0.08)), out = [];
  for (let k = 1; k <= n; k++) { const a = a0 + da * k / n; out.push([c[0] + r * Math.cos(a), c[1] + r * Math.sin(a)]); }
  return out;
}
const angOf = v => Math.atan2(v[1], v[0]);
const norm2pi = a => { a %= 2 * Math.PI; return a < 0 ? a + 2 * Math.PI : a; };
// 向き h（単位）で p を出て、円弧（半径 r）で曲がってから、まっすぐ q へ。q が近すぎるときは半径を小さくする
function arcToPoint(p, h, q, r) {
  const d = V2.sub(q, p), cr = V2.cross(h, d), D = V2.len(d);
  if (D < 1e-6) return { pts: [], exit: h, r: 1e9 };
  if (Math.abs(cr) < 1e-6 * D) { if (V2.dot(h, d) > 0) return { pts: [q], exit: h, r: 1e9 }; return null; }
  const left = cr > 0, rmax = D * D / (2 * Math.abs(cr));
  const rr = Math.min(r, rmax * 0.97);
  const nrm = left ? V2.rot90(h) : V2.rotm90(h), c = V2.add(p, V2.mul(nrm, rr));
  const w = V2.sub(q, c), W = V2.len(w); if (W <= rr) return null;
  const lam = Math.sqrt(W * W - rr * rr), ua = angOf(w) + (left ? 1 : -1) * Math.atan2(rr, lam), u = [Math.cos(ua), Math.sin(ua)];
  const t = V2.add(c, V2.mul(left ? V2.rotm90(u) : V2.rot90(u), rr));
  const a0 = angOf(V2.sub(p, c)), a1 = angOf(V2.sub(t, c));
  const da = left ? norm2pi(a1 - a0) : -norm2pi(a0 - a1);
  return { pts: [...arcPts(c, rr, a0, da), q], exit: u, r: rr, t };
}
// 両はしの向きが決まっているとき（点が2つ）：円弧＋直線＋円弧（いちばん短いもの）
function dubins(p0, h0, p1, h1, r) {
  let best = null;
  for (const [s0, s1] of [[1, 1], [-1, -1], [1, -1], [-1, 1]]) {   // 1 左回り・-1 右回り
    const c0 = V2.add(p0, V2.mul(s0 > 0 ? V2.rot90(h0) : V2.rotm90(h0), r)), c1 = V2.add(p1, V2.mul(s1 > 0 ? V2.rot90(h1) : V2.rotm90(h1), r));
    const d = V2.sub(c1, c0), D = V2.len(d); let u, lam;
    if (s0 === s1) { if (D < 1e-6) continue; u = V2.nrm(d); lam = D; }
    else { if (D < 2 * r) continue; lam = Math.sqrt(D * D - 4 * r * r); const ua = angOf(d) + (s0 > 0 ? 1 : -1) * Math.atan2(2 * r, lam); u = [Math.cos(ua), Math.sin(ua)]; }
    const q0 = V2.add(c0, V2.mul(s0 > 0 ? V2.rotm90(u) : V2.rot90(u), r)), q1 = V2.add(c1, V2.mul(s1 > 0 ? V2.rotm90(u) : V2.rot90(u), r));
    const a00 = angOf(V2.sub(p0, c0)), a01 = angOf(V2.sub(q0, c0)), a10 = angOf(V2.sub(q1, c1)), a11 = angOf(V2.sub(p1, c1));
    const da0 = s0 > 0 ? norm2pi(a01 - a00) : -norm2pi(a00 - a01), da1 = s1 > 0 ? norm2pi(a11 - a10) : -norm2pi(a10 - a11);
    const L = r * (Math.abs(da0) + Math.abs(da1)) + lam;
    if (!best || L < best.L) best = { L, pts: [...arcPts(c0, r, a00, da0), q1, ...arcPts(c1, r, a10, da1)] };
  }
  return best ? best.pts : null;
}
// 点の列 → 直線と円弧の線（0.5マスごと）。h0：はじめの向き、h1：おわりの向き（どちらもなくてよい）。r：半径（マス）
function arcGeom(ctrl, h0, h1, r) {
  const n = ctrl.length; if (n < 2) return { pts: ctrl.slice(), ok: true };
  if (n === 2 && h0 && h1) { const d = dubins(ctrl[0], h0, ctrl[1], h1, r); return d ? { pts: resample([ctrl[0], ...d], 0.5), ok: true } : { pts: [ctrl[0], ctrl[1]], ok: false }; }
  let head = [ctrl[0]], Q0 = ctrl[0];
  if (h0) { const a = arcToPoint(ctrl[0], h0, n > 2 || !h1 ? ctrl[1] : ctrl[1], r); if (!a) return { pts: [ctrl[0], ctrl[1]], ok: false }; head = [ctrl[0], ...a.pts.slice(0, -1)]; Q0 = a.t || ctrl[0]; }
  let tail = [ctrl[n - 1]], Qn = ctrl[n - 1];
  if (h1 && n > 2) {
    const b = arcToPoint(ctrl[n - 1], V2.mul(h1, -1), ctrl[n - 2], r); if (!b) return { pts: [ctrl[0], ctrl[n - 1]], ok: false };
    tail = [...b.pts.slice(0, -1)].reverse().concat([ctrl[n - 1]]); Qn = b.t || ctrl[n - 1];
  } else if (h1 && n === 2) {
    const b = arcToPoint(ctrl[1], V2.mul(h1, -1), ctrl[0], r); if (!b) return { pts: [ctrl[0], ctrl[1]], ok: false };
    return { pts: resample([ctrl[0], ...b.pts.slice(0, -1).reverse(), ctrl[1]], 0.5), ok: true };
  }
  const Q = [Q0, ...ctrl.slice(1, n - 1), Qn];
  const out = [...head];
  let cur = Q0;
  for (let i = 1; i < Q.length - 1; i++) {
    const P = Q[i], u = V2.nrm(V2.sub(P, Q[i - 1])), v = V2.nrm(V2.sub(Q[i + 1], P));
    const th = Math.acos(clamp(V2.dot(u, v), -1, 1));
    if (th < 1e-4) continue;
    const availIn = i === 1 ? V2.len(V2.sub(P, Q[0])) : V2.len(V2.sub(P, Q[i - 1])) / 2;
    const availOut = i === Q.length - 2 ? V2.len(V2.sub(Q[i + 1], P)) : V2.len(V2.sub(Q[i + 1], P)) / 2;
    const tt = Math.tan(th / 2), ri = Math.min(r, Math.min(availIn, availOut) / tt), T = ri * tt;
    const S1 = V2.sub(P, V2.mul(u, T)), E1 = V2.add(P, V2.mul(v, T)), left = V2.cross(u, v) > 0;
    const c = V2.add(S1, V2.mul(left ? V2.rot90(u) : V2.rotm90(u), ri));
    const a0 = angOf(V2.sub(S1, c)), a1 = angOf(V2.sub(E1, c)), da = left ? norm2pi(a1 - a0) : -norm2pi(a0 - a1);
    out.push(S1, ...arcPts(c, ri, a0, da)); cur = E1;
  }
  out.push(...tail);
  return { pts: resample(out, 0.5), ok: true };
}
// はしをつなぐ先をさがす（線路は自分の線路、道路はどの道路でも）
function findAttach(kind, x, y) {
  const pred = s => kind === 'rail' ? (s.k === 'rail' && s.mine) : (s.k === 'road' && s.c !== 'exp');
  const it = S.vis; if (!it) return null;
  // 線のはし（点）
  let best = null;
  for (const s of it.segs.values()) {
    if (!pred(s)) continue;
    for (const end of [0, 1]) {
      const i = end ? s.np - 1 : 0, px = s.P[2 * i], py = s.P[2 * i + 1], d = Math.hypot(px - x, py - y) * S.cam.z;
      if (d < 16 && (!best || d < best.d)) {
        const j = end ? s.np - 4 : 3, jj = clamp(j, 0, s.np - 1);
        let dx = s.P[2 * jj] - px, dy = s.P[2 * jj + 1] - py; const L = Math.hypot(dx, dy) || 1;   // 線の中へ入る向き
        best = { d, x: px, y: py, att: { node: end ? s.n1 : s.n0 }, din: [dx / L, dy / L], seg: s };
      }
    }
  }
  if (best) return best;
  const h = nearSeg(x, y, 12, pred);
  if (h) return { d: h.d, x: h.x, y: h.y, att: { seg: h.s.id }, tan: [Math.cos(h.ang), Math.sin(h.ang)], seg: h.s };
  return null;
}
function startDraw(kind) {
  const admin = S.as === 'gov';
  let mode = kind === 'rail' ? 'arc' : 'free', rad = kind === 'rail' ? 400 : 50;
  try { mode = localStorage.getItem('mp_dm_' + kind) || mode; rad = Number(localStorage.getItem('mp_dr_' + kind)) || rad; } catch (e) {}
  const st = S.toolState = { kind, mode, rad, ctrl: [], A: null, B: null, curve: [], quote: null, err: null, opts: { dbl: false, elec: false, lanes: admin ? 2 : 1, cls: admin ? 'nat' : 'priv', name: '' }, qt: 0 };
  S.tapHook = (x, y) => {
    const a = findAttach(kind, x, y);
    if (!st.ctrl.length) { st.ctrl.push(a ? [a.x, a.y] : [x, y]); st.A = a; }
    else {
      if (st.B) st.B = null;   // つないでいたはしは、まん中の点に
      st.ctrl.push(a ? [a.x, a.y] : [x, y]); st.B = a;
    }
    drawUpdate();
  };
  S.grab = (px, py) => {
    const i = st.ctrl.findIndex(p => Math.hypot(sx(p[0]) - px, sy(p[1]) - py) < 18);
    if (i < 0) return false; st.drag = i; return true;
  };
  S.grabMove = (x, y) => {
    const i = st.drag; if (i == null) return;
    if (i === 0 || i === st.ctrl.length - 1) {
      const a = findAttach(kind, x, y);
      st.ctrl[i] = a ? [a.x, a.y] : [x, y];
      if (i === 0) st.A = a; else st.B = a;
    } else st.ctrl[i] = [x, y];
    drawUpdate(true);
  };
  S.grabEnd = () => { st.drag = null; drawUpdate(); };
  S.onLong = (x, y, px, py) => {   // 長押しで点を消す
    const i = st.ctrl.findIndex(p => Math.hypot(sx(p[0]) - px, sy(p[1]) - py) < 18);
    if (i >= 0) { st.ctrl.splice(i, 1); if (i === 0) st.A = null; if (i === st.ctrl.length) st.B = null; drawUpdate(); }
  };
  S.drawTool = (g, z) => drawPreview(g, z, st);
  S.toolEnd = () => { S.tapHook = null; S.toolState = null; };
  drawSheet();
}
// 見えない点（はしの向き）。線路は、つないだ線と同じ向きでなめらかにつながるように（道路は自由な角度でつながる）
function phantoms(st) {
  const c = st.ctrl, n = c.length; if (n < 2 || (st.kind === 'road' && !st.edit)) return [null, null];
  const L0 = Math.hypot(c[1][0] - c[0][0], c[1][1] - c[0][1]), L1 = Math.hypot(c[n - 1][0] - c[n - 2][0], c[n - 1][1] - c[n - 2][1]);
  const dot = (t, a, b) => t[0] * (b[0] - a[0]) + t[1] * (b[1] - a[1]);
  let A = null, B = null;
  if (st.A) {   // 出ていく向き：線のはしなら、その線の続き。線のまん中なら、線にそって次の点のほう
    let t = st.A.din ? [-st.A.din[0], -st.A.din[1]] : st.A.tan.slice();
    if (!st.A.din && dot(t, c[0], c[1]) < 0) t = [-t[0], -t[1]];
    A = [c[1][0] - 2 * t[0] * L0, c[1][1] - 2 * t[1] * L0];
  }
  if (st.B) {   // 着く向き：線のはしなら、その線の中へ入る向き。線のまん中なら、線にそって
    let t = st.B.din ? st.B.din.slice() : st.B.tan.slice();
    if (!st.B.din && dot(t, c[n - 2], c[n - 1]) < 0) t = [-t[0], -t[1]];
    B = [c[n - 2][0] + 2 * t[0] * L1, c[n - 2][1] + 2 * t[1] * L1];
  }
  return [A, B];
}
// はしの向き（直線＋カーブ）：はじめは出ていく向き、おわりは着く向き
function endHeads(st) {
  const c = st.ctrl, n = c.length; let h0 = null, h1 = null;
  if (st.A) { let t = st.A.din ? [-st.A.din[0], -st.A.din[1]] : st.A.tan.slice(); if (!st.A.din && V2.dot(t, V2.sub(c[1], c[0])) < 0) t = [-t[0], -t[1]]; h0 = V2.nrm(t); }
  if (st.B) { let t = st.B.din ? st.B.din.slice() : st.B.tan.slice(); if (!st.B.din && V2.dot(t, V2.sub(c[n - 1], c[n - 2])) < 0) t = [-t[0], -t[1]]; h1 = V2.nrm(t); }
  return [h0, h1];
}
function drawUpdate(fast) {
  const st = S.toolState; if (!st) return;
  if (st.mode === 'arc' && st.ctrl.length >= 2) {
    const [h0, h1] = endHeads(st), g = arcGeom(st.ctrl, h0, h1, st.rad / 50);
    st.curve = g.pts; st.geoBad = !g.ok;
  } else {
    const [A, B] = phantoms(st);
    st.curve = st.ctrl.length >= 2 ? spline(st.ctrl, A, B) : []; st.geoBad = false;
  }
  st.rmin = st.curve.length > 6 ? minRadius(st.curve) : 1e9;
  // 形が変わったら、見つもりはやりなおし（「見つもる」を押す）。送っている見つもりの答えはすてる
  st.quote = null; st.err = null; st.qseq = (st.qseq || 0) + 1; st.quoting = false;
  S.dirty = true;
  drawSheet();
}
// 見つもり（「見つもる」を押したとき）
async function quoteDraw(st) {
  if (S.toolState !== st || st.curve.length < 3 || st.quoting) return;
  const my = st.qseq = (st.qseq || 0) + 1;
  st.quoting = true; drawSheet();
  let q = null, err = null;
  try { q = await call(st.edit ? 'mp_seg_edit' : 'mp_seg_build', drawArgs(st, true)); } catch (e) { err = e.message; }
  if (st.qseq !== my) return;
  st.quoting = false; st.quote = q; st.err = err;
  if (S.toolState === st) drawSheet();
}
function drawArgs(st, dry) {
  if (st.edit) return { p_id: st.edit.id, p_ctl: toInts(st.ctrl), p_pts: toInts(st.curve), p_dry: dry };
  const o = st.opts;
  return { p_kind: st.kind, p_cls: st.kind === 'road' ? o.cls : null, p_ctl: st.mode === 'arc' ? null : toInts(st.ctrl), p_pts: toInts(st.curve),
    p_opts: { dbl: o.dbl, elec: o.elec, name: o.name, lanes: o.lanes }, p_as: S.as, p_from: st.A ? st.A.att : null, p_to: st.B ? st.B.att : null, p_dry: dry };
}
function drawSheet() {
  const st = S.toolState; if (!st) return;
  const o = st.opts, rail = st.kind === 'rail', gov = S.as === 'gov', lenM = st.curve.length > 1 ? Math.round((st.curve.length - 1) * 0.5 * 50) : 0;
  const rminM = Math.round(st.rmin * 50), tight = rail ? st.rmin < 3 : st.rmin < 0.7;
  const q = st.quote;
  sheet(`<h4>${st.edit ? (rail ? '線路の形を直す' : '道路の形を直す') : rail ? '線路をひく' : '道路をひく'}</h4>
    <p class="small" style="margin:0 0 4px"><span>点 ${st.ctrl.length}・長さ 約${fmt(lenM)} m</span>${st.curve.length > 6 ? `<span>・いちばんきついカーブ 半径 ${rminM >= 50000 ? '—' : fmt(rminM) + ' m'}</span>` : ''}${st.A ? '<span>・はじめ：つなぐ</span>' : ''}${st.B ? '<span>・おわり：つなぐ</span>' : ''}</p>
    ${st.edit ? '' : `<div class="mp-row"><span class="mp-seg"><button data-m="arc" class="${st.mode === 'arc' ? 'on' : ''}">直線＋カーブ</button><button data-m="free" class="${st.mode !== 'arc' ? 'on' : ''}">なめらか</button></span>
      ${st.mode === 'arc' ? `<span>カーブの半径</span> <select class="mp-inp" data-rad style="width:auto">${(rail ? [160, 200, 250, 300, 400, 500, 600, 800, 1000, 1500, 2000, 3000] : [15, 20, 30, 50, 80, 100, 150, 200, 300, 500]).map(m => `<option value="${m}" ${st.rad === m ? 'selected' : ''}>${fmt(m)} m</option>`).join('')}</select>` : ''}</div>`}
    ${st.geoBad ? `<p class="mp-warn">この点では、えらんだ半径のカーブでつながりません（点を動かすか、半径を小さく）</p>` : ''}
    ${tight ? `<p class="mp-warn">${rail ? 'カーブがきつすぎます（線路は半径150m以上）' : 'カーブがきつすぎます'}</p>` : ''}
    ${st.edit ? '' : rail ? `<div class="mp-row"><span class="mp-seg"><button data-d="0" class="${!o.dbl ? 'on' : ''}">単線</button><button data-d="1" class="${o.dbl ? 'on' : ''}">複線</button></span>
        <span class="mp-seg"><button data-e="0" class="${!o.elec ? 'on' : ''}">非電化</button><button data-e="1" class="${o.elec ? 'on' : ''}">電化</button></span></div>`
      : `<div class="mp-row">${gov ? `<select class="mp-inp" style="width:auto" data-cls>${[['exp', '高速道路'], ['nat', '国道'], ['pref', '府県道'], ['city', '市道'], ['lane', '細い道']].map(c => `<option value="${c[0]}" ${o.cls === c[0] ? 'selected' : ''}>${c[1]}</option>`).join('')}</select>` : ''}
        片側 <span class="mp-seg">${(gov ? [0, 1, 2, 3] : [0, 1, 2]).map(n => `<button data-l="${n}" class="${o.lanes === n ? 'on' : ''}">${n ? n + '車線' : '細い道'}</button>`).join('')}</span></div>`}
    ${st.edit ? '' : `<div class="mp-row"><input class="mp-inp" data-nm placeholder="${rail ? '路線名（なくてもよい）' : '道路の名前（なくてもよい）'}" value="${esc(o.name)}"></div>`}
    <div class="mp-row">${q ? `<span class="mp-cost">工事費 ${X(q.cost)}</span><span class="small"><span>使用料 1日 ${X(q.lease || 0)}</span>${q.tunnel ? `<span>・トンネル ${q.tunnel}マス</span>` : ''}${q.bridge ? `<span>・橋 ${q.bridge}マス</span>` : ''}${q.vtop != null && q.vtop !== q.vlim ? `<span>・制限速度 ${q.vlim}〜${q.vtop} km/h</span>` : `<span>・制限速度 ${q.vlim} km/h</span>`}</span>`
      : st.err ? `<span class="mp-warn">${esc(st.err)}</span>` : st.quoting ? '<span class="muted small">見つもり中…</span>'
      : st.curve.length > 2 ? `<button class="btn" data-est ${tight || st.geoBad ? 'disabled' : ''}>見つもる</button><span class="muted small">工事費を出してから、つくれます</span>` : st.mode === 'arc' ? '<span class="muted small">地図をタップして角の点をおいてください（2つ以上）。角には、えらんだ半径のカーブが入ります。線路のはしから始めると延長、まん中から始めると分岐です</span>' : '<span class="muted small">地図をタップして点をおいてください（2つ以上）。はしを線の近くにおくと、つながります</span>'}</div>
    ${q ? needH(q.need) : ''}
    <div class="mp-row"><button class="btn" data-undo ${st.ctrl.length ? '' : 'disabled'}>1つもどす</button><button class="btn" data-cancel>キャンセル</button>
      <button class="btn main" data-ok ${q && !tight && !st.geoBad && !hasNeed(q) ? '' : 'disabled'}>${st.edit ? 'この形にする' : `つくる（${esc(asName())}）`}</button></div>
    <p class="muted small" style="margin:6px 0 0">点はドラッグで動かせます。長押しで消せます</p>`, s => {
    s.querySelectorAll('[data-m]').forEach(b => b.onclick = () => { st.mode = b.dataset.m; try { localStorage.setItem('mp_dm_' + st.kind, st.mode); } catch (e) {} drawUpdate(); });
    { const rd = s.querySelector('[data-rad]'); if (rd) rd.onchange = () => { st.rad = Number(rd.value); try { localStorage.setItem('mp_dr_' + st.kind, String(st.rad)); } catch (e) {} drawUpdate(); }; }
    s.querySelectorAll('[data-d]').forEach(b => b.onclick = () => { o.dbl = b.dataset.d === '1'; drawUpdate(); });
    s.querySelectorAll('[data-e]').forEach(b => b.onclick = () => { o.elec = b.dataset.e === '1'; drawUpdate(); });
    s.querySelectorAll('[data-l]').forEach(b => b.onclick = () => { o.lanes = Number(b.dataset.l); drawUpdate(); });
    const cl = s.querySelector('[data-cls]'); if (cl) cl.onchange = () => { o.cls = cl.value; drawUpdate(); };
    const nm = s.querySelector('[data-nm]'); if (nm) nm.onchange = () => { o.name = nm.value; };
    s.querySelector('[data-undo]').onclick = () => { if (st.edit && st.ctrl.length <= 2) return; st.ctrl.pop(); if (!st.edit) st.B = null; if (!st.ctrl.length) st.A = null; drawUpdate(); };
    s.querySelector('[data-cancel]').onclick = () => setTool(st.edit ? 'look' : st.kind);
    { const es = s.querySelector('[data-est]'); if (es) es.onclick = () => quoteDraw(st); }
    needBind(s, q && q.need, () => quoteDraw(st));
    s.querySelector('[data-ok]').onclick = async () => {
      if (nm) o.name = nm.value;
      const r = await api(st.edit ? 'mp_seg_edit' : 'mp_seg_build', drawArgs(st, false));
      if (!r) return;
      toast(`${st.edit ? '直しました' : 'つくりました'}（${fmt(r.cost)} X）`);
      const xs = st.curve.map(p => p[0]), ys = st.curve.map(p => p[1]);
      refreshBox(Math.min(...xs) - 2, Math.min(...ys) - 2, Math.max(...xs) + 2, Math.max(...ys) + 2);
      if (st.edit) refreshBox(...st.edit.bb);
      setTool(st.edit ? 'look' : st.kind);
    };
  });
  S.onSheetClose = () => setTool('look');
}
function drawPreview(g, z, st) {
  if (st.curve.length > 1) {
    const rail = st.kind === 'rail';
    g.lineCap = 'round'; g.lineJoin = 'round';
    g.strokeStyle = st.err ? 'rgba(220,40,40,.85)' : rail ? 'rgba(30,30,30,.85)' : 'rgba(250,250,250,.95)';
    g.lineWidth = Math.max(3, (rail ? 0.34 : 0.18 + 0.13 * st.opts.lanes) * z);
    g.beginPath(); st.curve.forEach((p, i) => i ? g.lineTo(sx(p[0]), sy(p[1])) : g.moveTo(sx(p[0]), sy(p[1]))); g.stroke();
    g.strokeStyle = '#1f5fbf'; g.lineWidth = 2; g.setLineDash([6, 5]); g.stroke(); g.setLineDash([]);
  }
  // 点と、それをつなぐ細い線
  g.strokeStyle = 'rgba(31,95,191,.5)'; g.lineWidth = 1; g.beginPath(); st.ctrl.forEach((p, i) => i ? g.lineTo(sx(p[0]), sy(p[1])) : g.moveTo(sx(p[0]), sy(p[1]))); g.stroke();
  st.ctrl.forEach((p, i) => {
    const end = i === 0 || i === st.ctrl.length - 1, att = (i === 0 && st.A) || (i === st.ctrl.length - 1 && i > 0 && st.B), fixed = st.edit && end;
    g.fillStyle = fixed ? '#888' : att ? '#1fa35a' : '#1f5fbf'; g.strokeStyle = '#fff'; g.lineWidth = 2;
    g.beginPath(); g.arc(sx(p[0]), sy(p[1]), end ? 8 : 6.5, 0, 6.3); g.fill(); g.stroke();
  });
}
// 形を直す：点（ctl があればそれ、なければ線から6マスごと）を動かす。はしは動かせない
function startEdit(s) {
  setTool('look');
  let ctrl;
  if (s.ctl && s.ctl.length >= 4) { ctrl = []; for (let i = 0; i < s.ctl.length; i += 2) ctrl.push([s.ctl[i] / 100, s.ctl[i + 1] / 100]); ctrl[0] = [s.P[0], s.P[1]]; ctrl[ctrl.length - 1] = [s.P[2 * s.np - 2], s.P[2 * s.np - 1]]; }
  else { ctrl = []; const step = 12; for (let i = 0; i < s.np; i += step) ctrl.push([s.P[2 * i], s.P[2 * i + 1]]); const l = [s.P[2 * s.np - 2], s.P[2 * s.np - 1]]; if (ctrl.length < 2 || Math.hypot(ctrl[ctrl.length - 1][0] - l[0], ctrl[ctrl.length - 1][1] - l[1]) > 0.2) ctrl.push(l); }
  // はしの向き：もとの線の向きのまま
  const d0 = [s.P[2] - s.P[0], s.P[3] - s.P[1]], L0 = Math.hypot(...d0) || 1, n = s.np, d1 = [s.P[2 * n - 2] - s.P[2 * n - 4], s.P[2 * n - 1] - s.P[2 * n - 3]], L1 = Math.hypot(...d1) || 1;
  const st = S.toolState = { kind: s.k, edit: s, ctrl, A: { tan: [d0[0] / L0, d0[1] / L0] }, B: { tan: [d1[0] / L1, d1[1] / L1] }, curve: [], quote: null, err: null, opts: { lanes: s.l || 1 }, qt: 0 };
  S.tapHook = (x, y) => {   // 線の近くをタップ：点をふやす（いちばん近い、点と点のあいだに）
    let bi = 1, bd = Infinity;
    for (let i = 0; i + 1 < st.ctrl.length; i++) { const a = st.ctrl[i], b = st.ctrl[i + 1], d = Math.hypot((a[0] + b[0]) / 2 - x, (a[1] + b[1]) / 2 - y); if (d < bd) { bd = d; bi = i + 1; } }
    st.ctrl.splice(bi, 0, [x, y]); drawUpdate();
  };
  S.grab = (px, py) => { const i = st.ctrl.findIndex((p, k) => k > 0 && k < st.ctrl.length - 1 && Math.hypot(sx(p[0]) - px, sy(p[1]) - py) < 18); if (i < 0) return false; st.drag = i; return true; };
  S.grabMove = (x, y) => { if (st.drag != null) { st.ctrl[st.drag] = [x, y]; drawUpdate(true); } };
  S.grabEnd = () => { st.drag = null; drawUpdate(); };
  S.onLong = (x, y, px, py) => { const i = st.ctrl.findIndex((p, k) => k > 0 && k < st.ctrl.length - 1 && Math.hypot(sx(p[0]) - px, sy(p[1]) - py) < 18); if (i > 0) { st.ctrl.splice(i, 1); drawUpdate(); } };
  S.drawTool = (g, z) => drawPreview(g, z, st);
  S.toolEnd = () => { S.tapHook = null; S.toolState = null; };
  hint('点をドラッグで動かす・線の近くをタップで点をふやす・長押しで消す');
  drawUpdate();
}

/* ---- 駅・バス停 ---- */
// 駅・バス停のはじめの名前：近くの町・大字の名前（「町」はとる）
function nearDist(x, y) {
  let best = null, bd = Infinity;
  for (const c of (S.vis ? S.vis.chos.values() : [])) { if (c[1] !== 'cho' && c[1] !== 'oaza') continue; const d = (c[3] + 0.5 - x) ** 2 + (c[4] + 0.5 - y) ** 2; if (d < bd) { bd = d; best = c; } }
  if (!best) return '';
  const n = String(best[2] || '');
  return n.length > 1 && n.endsWith('町') ? n.slice(0, -1) : n;
}
// 線の上の、はじめからの長さ at（マス）のところ
function segPointAt(s, at) {
  const P = s.P; let acc = 0;
  for (let i = 0; i + 1 < s.np; i++) {
    const ax = P[2 * i], ay = P[2 * i + 1], bx = P[2 * i + 2], by = P[2 * i + 3], L = Math.hypot(bx - ax, by - ay);
    if (acc + L >= at || i + 2 === s.np) { const t = L ? clamp((at - acc) / L, 0, 1) : 0; return { x: ax + (bx - ax) * t, y: ay + (by - ay) * t, ang: Math.atan2(by - ay, bx - ax) }; }
    acc += L;
  }
  return { x: P[0], y: P[1], ang: 0 };
}
// 線の a0〜a1 の部分（画面の座標で）
function pathPart(g, s, a0, a1) {
  const P = s.P; let acc = 0, started = false;
  g.beginPath();
  for (let i = 0; i + 1 < s.np; i++) {
    const ax = P[2 * i], ay = P[2 * i + 1], bx = P[2 * i + 2], by = P[2 * i + 3], L = Math.hypot(bx - ax, by - ay);
    const t0 = L ? (a0 - acc) / L : 0, t1 = L ? (a1 - acc) / L : 0;
    if (t1 >= 0 && t0 <= 1) {
      const u0 = clamp(t0, 0, 1), u1 = clamp(t1, 0, 1);
      if (!started) { g.moveTo(sx(ax + (bx - ax) * u0), sy(ay + (by - ay) * u0)); started = true; }
      g.lineTo(sx(ax + (bx - ax) * u1), sy(ay + (by - ay) * u1));
    }
    acc += L;
  }
}
// 起点と終点が、つなぎ目（分かれ道のない点）をはさんだ別々の線のとき：サーバーで1本にして、その線の上の位置にする
//   近くないとき（えらびなおし）は 'far'、つなげないときは 'ng'（理由はサーバーのことばで出す）
async function joinHits(a, b, maxTiles) {
  if (a.s.id === b.s.id) return [a, b];
  if (Math.hypot(a.x - b.x, a.y - b.y) > maxTiles) return 'far';
  hint('線路をつないでいます…');
  const r = await api('mp_seg_join', { p_a: a.s.id, p_b: b.s.id });
  if (!r) return 'ng';
  const s = prepSeg(r);
  refreshBox(s.bb[0] - 2, s.bb[1] - 2, s.bb[2] + 2, s.bb[3] + 2);
  return [projSeg(s, a.x, a.y), projSeg(s, b.x, b.y)];
}
// 駅：ホームの起点と終点をタップ（同じ線路の上。つなぎ目をはさむときは1本にする）。長さは20m単位。バス停は1か所
async function staTap(x, y) {
  const st = S.toolState || (S.toolState = {});
  if (st.busy) return;
  const hr = nearSeg(x, y, 14, s => s.k === 'rail' && s.mine);
  if (hr) {
    let why = null;
    if (st.a && !st.done && st.a.s.id !== hr.s.id) {
      st.busy = true; const j = await joinHits(st.a, hr, 8.6); st.busy = false;
      if (S.toolState !== st || S.tool !== 'sta') return;
      if (Array.isArray(j)) { st.a = j[0]; st.b = j[1]; st.done = true; hint(''); return staSheet('rail', j[0], j[1]); }
      why = j;
    }
    if (!st.a || st.a.s.id !== hr.s.id || st.done) {
      if (why === 'far') toast(T('同じ線路の上で終点をタップしてください（起点をえらびなおしました）'));
      S.toolState = { a: hr }; sheet(null);
      hint('駅：ホームの終点をタップしてください（同じ線路の上・20m単位）');
      S.drawTool = (g, z) => { const t = S.toolState; if (!t || !t.a) return; const p = segPointAt(t.a.s, t.a.at); g.fillStyle = '#1f5fbf'; g.beginPath(); g.arc(sx(p.x), sy(p.y), 6, 0, 6.3); g.fill(); g.strokeStyle = '#fff'; g.lineWidth = 2; g.stroke(); };
      S.dirty = true; return;
    }
    st.b = hr; st.done = true; hint('');
    return staSheet('rail', st.a, st.b);
  }
  const hb = nearSeg(x, y, 12, s => s.k === 'road' && s.c !== 'exp');
  if (hb) return staSheet('bus', hb);
  toast('自分の線路か、道路の上をタップしてください');
}
function staSheet(kind, hit, hit2) {
  const segLenMax = kind === 'rail' ? hit.s.len / 50 : 0;
  // 起点と終点のまん中・長さ（20m単位）
  const span = kind === 'rail' ? Math.abs(hit2.at - hit.at) : 0;
  const st = { plat: kind === 'rail' ? clamp(Math.round(span * 50 / 20) * 20, 20, 400) : 0, mid: kind === 'rail' ? (hit.at + hit2.at) / 2 : hit.at,
               tracks: 2, name: nearDist(hit.x, hit.y), q: null, err: null };
  const pt = () => segPointAt(hit.s, st.mid);
  S.sel = { kind: 'seg', id: hit.s.id }; S.dirty = true;
  if (kind === 'rail') {
    S.drawTool = (g, z) => {
      const a0 = st.mid - st.plat / 100, a1 = st.mid + st.plat / 100;
      g.lineCap = 'butt'; g.strokeStyle = 'rgba(31,95,191,.9)'; g.lineWidth = Math.max(8, (0.22 * st.tracks + 0.3) * z); pathPart(g, hit.s, a0, a1); g.stroke();
      g.strokeStyle = '#fff'; g.lineWidth = Math.max(4, (0.22 * st.tracks + 0.18) * z); pathPart(g, hit.s, a0, a1); g.stroke(); g.lineCap = 'round';
    };
  }
  // 見つもりは「見つもる」を押してから。大きさを変えたら、やりなおし
  const quote = async () => {
    const p = pt(), my = st.seq = (st.seq || 0) + 1; st.quoting = true; draw();
    let q = null, err = null;
    try { q = await call('mp_sta_build', { p_kind: kind, p_seg: hit.s.id, p_x: p.x, p_y: p.y, p_plat: st.plat, p_tracks: st.tracks, p_name: st.name || '仮', p_as: S.as, p_dry: true }); } catch (e) { err = e.message; }
    if (st.seq !== my) return;
    st.quoting = false; st.q = q; st.err = err;
    draw(); S.dirty = true;
  };
  const changed = () => { st.seq = (st.seq || 0) + 1; st.quoting = false; st.q = null; st.err = null; draw(); S.dirty = true; };
  const draw = () => sheet(`<h4>${kind === 'rail' ? '🚉 駅をつくる' : '🚏 バス停をつくる'}</h4>
    <div class="mp-row"><input class="mp-inp" data-nm placeholder="${kind === 'rail' ? '駅の名前（「駅」はつけない）' : 'バス停の名前'}" value="${esc(st.name)}"></div>
    ${kind === 'rail' ? `<div class="mp-row"><span>ホーム</span> <button class="btn" data-pm="-20" style="flex:none;padding:4px 12px">−</button><b style="min-width:4.2em;text-align:center">${st.plat}m</b><button class="btn" data-pm="20" style="flex:none;padding:4px 12px">＋</button>
        <span class="muted small">20m の車両 ${Math.floor(st.plat / 20)}両まで</span></div>
      <div class="mp-row">番線 <span class="mp-seg">${[1, 2, 3, 4, 6].map(n => `<button data-t="${n}" class="${st.tracks === n ? 'on' : ''}">${n}</button>`).join('')}</span></div>
      <p class="muted small" style="margin:4px 0 0">起点と終点のあいだが、ホームになります（20m単位）。もう一度タップすると、えらびなおせます</p>` : ''}
    <div class="mp-row">${st.q ? `<span class="mp-cost">工事費 ${X(st.q.cost)}</span><span class="small"><span>維持費 1日 ${X(st.q.up_day)}</span>${st.q.lease ? `<span>・使用料 1日 ${X(st.q.lease)}</span>` : ''}</span>` : st.err ? `<span class="mp-warn">${esc(st.err)}</span>` : st.quoting ? '<span class="muted small">見つもり中…</span>' : '<button class="btn" data-est>見つもる</button><span class="muted small">工事費を出してから、つくれます</span>'}</div>
    ${st.q ? needH(st.q.need) : ''}
    <div class="mp-row"><button class="btn main" data-ok ${st.q && !hasNeed(st.q) ? '' : 'disabled'}>つくる（${esc(asName())}）</button></div>`, s => {
    s.querySelector('[data-nm]').onchange = e => { st.name = e.target.value; };
    needBind(s, st.q && st.q.need, () => quote());
    s.querySelectorAll('[data-pm]').forEach(b => b.onclick = () => { st.plat = clamp(st.plat + Number(b.dataset.pm), 20, 400); changed(); });
    s.querySelectorAll('[data-t]').forEach(b => b.onclick = () => { st.tracks = Number(b.dataset.t); changed(); });
    { const es = s.querySelector('[data-est]'); if (es) es.onclick = () => quote(); }
    s.querySelector('[data-ok]').onclick = async () => {
      st.name = s.querySelector('[data-nm]').value.trim(); if (!st.name) return toast('名前をつけてください');
      const p = pt();
      if (await api('mp_sta_build', { p_kind: kind, p_seg: hit.s.id, p_x: p.x, p_y: p.y, p_plat: st.plat, p_tracks: st.tracks, p_name: st.name, p_as: S.as, p_dry: false }, 'つくりました')) {
        refreshBox(p.x - 6, p.y - 6, p.x + 6, p.y + 6); sheet(null); S.sel = null; S.toolState = null; S.drawTool = null; S.dirty = true;
        if (kind === 'rail') hint('駅：ホームの起点をタップ（自分の線路の上）。バス停は道路の上をタップ');
      }
    };
  });
  S.onSheetClose = () => { S.toolState = null; S.drawTool = null; S.dirty = true; if (S.tool === 'sta') hint('駅：ホームの起点をタップ（自分の線路の上）。バス停は道路の上をタップ'); };
  draw();
}

// 車庫：車両基地は線路をなぞる（起点と終点をタップ・20m単位。つなぎ目をはさむときは1本にする）。バスの営業所は道路の横をタップ
async function depTap(x, y) {
  if (S.toolState && S.toolState.busy) return;
  const hr = nearSeg(x, y, 14, s => s.k === 'rail' && s.mine);
  if (hr) {
    const st = S.toolState || (S.toolState = {});
    let why = null;
    if (st.da && !st.ddone && st.da.s.id !== hr.s.id) {
      st.busy = true; const j = await joinHits(st.da, hr, 20.6); st.busy = false;
      if (S.toolState !== st || S.tool !== 'dep') return;
      if (Array.isArray(j)) { st.da = j[0]; st.ddone = true; hint(''); return depSheetRail(j[0], j[1]); }
      why = j;
    }
    if (!st.da || st.da.s.id !== hr.s.id || st.ddone) {
      if (why === 'far') toast(T('同じ線路の上で終点をタップしてください（起点をえらびなおしました）'));
      S.toolState = { da: hr }; sheet(null);
      hint('車両基地：終点をタップしてください（同じ線路の上・20m単位）');
      S.drawTool = (g, z) => { const t = S.toolState; if (!t || !t.da) return; const p = segPointAt(t.da.s, t.da.at); g.fillStyle = '#8a5a1f'; g.beginPath(); g.arc(sx(p.x), sy(p.y), 6, 0, 6.3); g.fill(); g.strokeStyle = '#fff'; g.lineWidth = 2; g.stroke(); };
      S.dirty = true; return;
    }
    st.ddone = true; hint('');
    return depSheetRail(st.da, hr);
  }
  const hb = nearSeg(x, y, 12, s => s.k === 'road' && s.c !== 'exp');
  const hit = hb; if (!hit) return toast('自分の線路（バスは道路）の近くをタップしてください');
  const kind = 'bus';
  // タップした側
  const side = ((x - hit.x) * -Math.sin(hit.ang) + (y - hit.y) * Math.cos(hit.ang)) >= 0 ? 1 : -1;
  const st = { size: 'S', side, name: nearDist(x, y) + (kind === 'rail' ? '車両基地' : '営業所'), q: null, err: null };
  const prev = () => ({ fx: hit.x, fy: hit.y, a: hit.ang, side: st.side, sz: st.size, k: kind });
  S.drawTool = (g, z) => { const P = depPoly(prev()); g.beginPath(); P.forEach((p, i) => i ? g.lineTo(sx(p[0]), sy(p[1])) : g.moveTo(sx(p[0]), sy(p[1]))); g.closePath(); g.fillStyle = st.err ? 'rgba(220,40,40,.35)' : 'rgba(30,110,230,.3)'; g.fill(); g.strokeStyle = '#1f5fbf'; g.lineWidth = 2; g.stroke(); };
  S.dirty = true;
  const quote = async () => {
    const my = st.seq = (st.seq || 0) + 1; st.quoting = true; draw();
    let q = null, err = null;
    try { q = await call('mp_dep_build', { p_kind: kind, p_seg: hit.s.id, p_x: hit.x, p_y: hit.y, p_side: st.side, p_size: st.size, p_name: st.name || '仮', p_as: S.as, p_dry: true }); } catch (e) { err = e.message; }
    if (st.seq !== my) return;
    st.quoting = false; st.q = q; st.err = err;
    draw(); S.dirty = true;
  };
  const changed = () => { st.seq = (st.seq || 0) + 1; st.quoting = false; st.q = null; st.err = null; draw(); S.dirty = true; };
  const sizes = kind === 'rail' ? [['S', '小（16両）'], ['M', '中（48両）'], ['L', '大（120両）']] : [['S', '小（20台）'], ['M', '中（60台）']];
  const draw = () => sheet(`<h4>${kind === 'rail' ? '🏭 車両基地をつくる' : '🏭 バスの営業所をつくる'}</h4>
    <div class="mp-row"><input class="mp-inp" data-nm value="${esc(st.name)}"></div>
    <div class="mp-row"><span class="mp-seg">${sizes.map(s => `<button data-s="${s[0]}" class="${st.size === s[0] ? 'on' : ''}">${s[1]}</button>`).join('')}</span>
      <button class="btn" data-side>反対側にする</button></div>
    <div class="mp-row">${st.q ? `<span class="mp-cost">工事費 ${X(st.q.cost)}</span><span class="small">使用料 1日 ${X(st.q.lease)}・維持費 1日 ${X(st.q.up_day)}</span>` : st.err ? `<span class="mp-warn">${esc(st.err)}</span>` : st.quoting ? '<span class="muted small">見つもり中…</span>' : '<button class="btn" data-est>見つもる</button><span class="muted small">工事費を出してから、つくれます</span>'}</div>
    ${st.q ? needH(st.q.need) : ''}
    <div class="mp-row"><button class="btn main" data-ok ${st.q && !hasNeed(st.q) ? '' : 'disabled'}>つくる（${esc(asName())}）</button></div>`, s => {
    s.querySelector('[data-nm]').onchange = e => { st.name = e.target.value; };
    needBind(s, st.q && st.q.need, () => quote());
    s.querySelectorAll('[data-s]').forEach(b => b.onclick = () => { st.size = b.dataset.s; changed(); });
    s.querySelector('[data-side]').onclick = () => { st.side = -st.side; changed(); };
    { const es = s.querySelector('[data-est]'); if (es) es.onclick = () => quote(); }
    s.querySelector('[data-ok]').onclick = async () => {
      st.name = s.querySelector('[data-nm]').value.trim();
      if (await api('mp_dep_build', { p_kind: kind, p_seg: hit.s.id, p_x: hit.x, p_y: hit.y, p_side: st.side, p_size: st.size, p_name: st.name, p_as: S.as, p_dry: false }, 'つくりました')) {
        refreshBox(hit.x - 12, hit.y - 12, hit.x + 12, hit.y + 12); sheet(null); S.drawTool = null;
      }
    };
  });
  S.onSheetClose = () => { S.drawTool = null; S.dirty = true; };
  draw();
}

// 車両基地（線路をなぞる）：長さ（20m単位）・留置線の数・どちら側か
function depSheetRail(h1, h2) {
  const seg = h1.s, span = Math.abs(h2.at - h1.at);
  const st = { len: clamp(Math.round(span * 50 / 20) * 20, 40, 1000), mid: (h1.at + h2.at) / 2, n: 6, side: 1, name: nearDist(h1.x, h1.y) + '車両基地', q: null, err: null };
  const sz = () => `T${st.len}x${st.n}`;
  const at = () => { const p = segPointAt(seg, st.mid); return p; };
  S.sel = { kind: 'seg', id: seg.id };
  S.drawTool = (g, z) => {
    const p = at(), P = depPoly({ fx: p.x, fy: p.y, a: p.ang, side: st.side, sz: sz(), k: 'rail' });
    g.beginPath(); P.forEach((q, i) => i ? g.lineTo(sx(q[0]), sy(q[1])) : g.moveTo(sx(q[0]), sy(q[1]))); g.closePath();
    g.fillStyle = st.err ? 'rgba(220,40,40,.35)' : 'rgba(150,110,60,.4)'; g.fill(); g.strokeStyle = '#8a5a1f'; g.lineWidth = 2; g.stroke();
    g.lineCap = 'butt'; g.strokeStyle = 'rgba(138,90,31,.85)'; g.lineWidth = Math.max(5, 0.3 * z); pathPart(g, seg, st.mid - st.len / 100, st.mid + st.len / 100); g.stroke(); g.lineCap = 'round';
  };
  S.dirty = true;
  const args = dry => { const p = at(); return { p_kind: 'rail', p_seg: seg.id, p_x: p.x, p_y: p.y, p_side: st.side, p_size: sz(), p_name: st.name || '仮', p_as: S.as, p_dry: dry }; };
  const quote = async () => {
    const my = st.seq = (st.seq || 0) + 1; st.quoting = true; draw();
    let q = null, err = null;
    try { q = await call('mp_dep_build', args(true)); } catch (e) { err = e.message; }
    if (st.seq !== my) return;
    st.quoting = false; st.q = q; st.err = err;
    draw(); S.dirty = true;
  };
  const changed = () => { st.seq = (st.seq || 0) + 1; st.quoting = false; st.q = null; st.err = null; draw(); S.dirty = true; };
  const step = (k, d, lo, hi) => `<button class="btn" data-${k}="${-d}" style="flex:none;padding:4px 12px">−</button><b style="min-width:4.2em;text-align:center">${k === 'len' ? st.len + 'm' : T(`${st.n}本`)}</b><button class="btn" data-${k}="${d}" style="flex:none;padding:4px 12px">＋</button>`;
  const draw = () => sheet(`<h4>🏭 車両基地をつくる</h4>
    <div class="mp-row"><input class="mp-inp" data-nm value="${esc(st.name)}" placeholder="車両基地の名前"></div>
    <div class="mp-row"><span>長さ</span> ${step('len', 20)}</div>
    <div class="mp-row"><span>留置線</span> ${step('n', 1)} <button class="btn" data-side>反対側にする</button></div>
    <p class="small" style="margin:4px 0 0">20m の車両 ${Math.floor(st.len / 20) * st.n}両まで（${Math.floor(st.len / 20)}両 × ${st.n}本）</p>
    <div class="mp-row">${st.q ? `<span class="mp-cost">工事費 ${X(st.q.cost)}</span><span class="small">使用料 1日 ${X(st.q.lease)}・維持費 1日 ${X(st.q.up_day)}</span>` : st.err ? `<span class="mp-warn">${esc(st.err)}</span>` : st.quoting ? '<span class="muted small">見つもり中…</span>' : '<button class="btn" data-est>見つもる</button><span class="muted small">工事費を出してから、つくれます</span>'}</div>
    ${st.q ? needH(st.q.need) : ''}
    <div class="mp-row"><button class="btn main" data-ok ${st.q && !hasNeed(st.q) ? '' : 'disabled'}>つくる（${esc(asName())}）</button></div>
    <p class="muted small" style="margin:4px 0 0">起点と終点のあいだに、線路にそって車両基地をつくります（20m単位）。もう一度タップすると、えらびなおせます</p>`, s => {
    s.querySelector('[data-nm]').onchange = e => { st.name = e.target.value; };
    needBind(s, st.q && st.q.need, () => quote());
    s.querySelectorAll('[data-len]').forEach(b => b.onclick = () => { st.len = clamp(st.len + Number(b.dataset.len), 40, 1000); changed(); });
    s.querySelectorAll('[data-n]').forEach(b => b.onclick = () => { st.n = clamp(st.n + Number(b.dataset.n), 1, 20); changed(); });
    s.querySelector('[data-side]').onclick = () => { st.side = -st.side; changed(); };
    { const es = s.querySelector('[data-est]'); if (es) es.onclick = () => quote(); }
    s.querySelector('[data-ok]').onclick = async () => {
      st.name = s.querySelector('[data-nm]').value.trim(); if (!st.name) return toast('名前をつけてください');
      const p = at();
      if (await api('mp_dep_build', args(false), 'つくりました')) { refreshBox(p.x - 14, p.y - 14, p.x + 14, p.y + 14); sheet(null); S.drawTool = null; S.toolState = null; S.sel = null; hint(TOOL_HINT.dep); }
    };
  });
  S.onSheetClose = () => { S.drawTool = null; S.toolState = null; S.dirty = true; if (S.tool === 'dep') hint(TOOL_HINT.dep); };
  draw();
}

/* ---- こわす ---- */
async function delTap(x, y) {
  const st = nearSta(x, y, 14); if (st && st.s.mine) return showSta(st.s);
  const dp = nearDep(x, y); if (dp && dp.mine) return showDep(dp);
  const sg = nearSeg(x, y, 10, s => s.mine); if (sg) return segDel(sg.s);
  const [cx, cy] = cellAt(x, y), key = cx + ',' + cy;
  const P = S.vis && [...S.vis.parcels.values()].find(q => q.cells.has(key));
  const hb = hitBld(x, y);
  if (hb && hb.b.own === 2) return openBld(hb.b.id);
  if (P && P.own === 2 && P.bld) return showSpot(cx, cy);
  toast('こわせるもの（自分の線・駅・車庫・建物）がありません');
}

/* ---------- メニュー（車両・系統・ダイヤ・お金・管理） ---------- */
function modal(html, bind, cls) {
  const m = document.createElement('div'); m.className = 'modal mp-modal';
  m.innerHTML = `<div class="sheet ${cls || ''}"><div class="row" style="display:flex;align-items:center;gap:8px"><b style="font-size:18px" data-title></b><button class="btn" style="margin-left:auto" data-x>とじる</button></div><div data-body></div></div>`;
  const body = m.querySelector('[data-body]');
  m.onclick = ev => { if (ev.target === m || ev.target.hasAttribute('data-x')) close(); };
  const close = () => { m.remove(); if (m.onclose) m.onclose(); };
  m.set = (title, h, b) => { m.querySelector('[data-title]').textContent = T(title); body.innerHTML = h; if (b) b(body); busyGuard(body); };
  m.close = close;
  document.body.appendChild(m);
  if (html) m.set(html[0], html[1], bind);
  return m;
}
function openMenu() {
  const m = modal(['国土のメニュー', `<div class="mp-list">
    <button class="mp-item" style="text-align:left" data-k="cars"><b>🚃 車両と編成</b><br><small>注文（1両から）・編成を組む・改造・検査・更新・転属・廃車</small></button>
    <button class="mp-item" style="text-align:left" data-k="routes"><b>🗺 系統とダイヤ</b><br><small>止まる駅の順番・列車の時刻（採時駅）・ダイヤグラム</small></button>
    <button class="mp-item" style="text-align:left" data-k="ops"><b>📋 運用</b><br><small>どの編成がどの列車を走るか・運用ファイル（書き出し・読みこみ）</small></button>
    <button class="mp-item" style="text-align:left" data-k="xfer"><b>🤝 編成の譲渡</b><br><small>とどいた申しこみを受けとる・ことわる／出した申しこみ</small></button>
    <button class="mp-item" style="text-align:left" data-k="blds"><b>🏢 自分の建物</b><br><small>部屋の入居・家賃の水準・テナント（${esc(asName())}）</small></button>
    <button class="mp-item" style="text-align:left" data-k="tenants"><b>🔑 テナント募集</b><br><small>会社で部屋を借りる・借りている部屋</small></button>
    <button class="mp-item" style="text-align:left" data-k="landreq"><b>📨 土地の申請</b><br><small>他人の土地を使う申請・とどいた申請への返事（許可・ことわる）</small></button>
    <button class="mp-item" style="text-align:left" data-k="ledger"><b>💴 お金の記録</b><br><small>運賃・家賃・維持費・使用料・工事費（${esc(asName())}）</small></button>
    ${S.admin ? `<button class="mp-item" style="text-align:left" data-k="admin"><b>🛠 管理</b><br><small>値段の設定・用途地域・ようす</small></button>` : ''}
    <button class="mp-item" style="text-align:left" data-k="help"><b>❓ あそびかた</b></button></div>`], b => {
    b.querySelectorAll('[data-k]').forEach(x => x.onclick = () => { m.close(); ({ cars: () => openCars(), routes: openRoutes, ops: () => openOps(), xfer: () => openXfers(), blds: openMyBlds, tenants: openTenants, landreq: () => openLandReqs(), ledger: openLedger, admin: openAdmin, help: openHelp })[x.dataset.k](); });
  });
}
function openHelp() {
  modal(['国土のあそびかた', `<div class="small" style="line-height:1.8">
    <p><b>地図</b>：瑠璃市中里区がまん中。北西が山、南東が海です。指2本で拡大・縮小、ドラッグで動かします。タップすると住所（町字・地番）・地目・用途地域・地価がわかります。線は県・市区町村・町字の境界です。</p>
    <p><b>土地</b>：国の土地は区画（10m四方・100㎡）でえらんで買えます。道路の部分は国の土地（公衆用道路）なので買えません。買った土地は「筆」になり、地番がつきます（住所は町字＋地番）。となりあう自分の筆は合筆、筆の一部は分筆できます。売りに出ている筆は、その値段（＋取得税3%）。毎日、評価額の0.01%の固定資産税。</p>
    <p><b>地価と評価額</b>：瑠璃市の中心（中里区）は地価が高く（1㎡ 約10億 X）、まわり5kmで、なだらかにふつうの地価にもどります。国の土地を買う値段は地価、固定資産税・家賃・使用料・取得税は評価額（ふつうの地価）で計算します。瑠璃市役所と市民広場は国の建物です。</p>
    <p><b>建物</b>：自分の筆に、プリセット（一戸建て・アパート・マンション・タワーマンション・店舗つき住宅・雑居ビル・オフィスビル・超高層ビル・ショッピングセンター・工場・倉庫・港湾施設・田畑・駐車場・立体駐車場）から、形と階数をえらんで建てます。広さと高さは用途地域の建ぺい率・容積率まで。細い形（塔状・板状）ほど高くできます。</p>
    <p><b>部屋とテナント</b>：部屋ごとに「入居募集」（町の人やお店が入って家賃）・「テナント募集」（会社に貸す。会社が借りると、1時間ごとに会社から家賃）・「自分で使う」（店・事務所などは売上が入る）をえらびます。家賃の水準を上げると、入りにくく出ていきやすくなります。人が多いところ・乗り降りの多い駅の近くは入りやすく、店の売上も多くなります。会社は ≡ →「テナント募集」から部屋を借りられます。</p>
    <p><b>線路・道路</b>：点をおくと、なめらかな線になります。他人の土地や国の土地の上につくると、毎日使用料がかかります（国・府県・市の道路の上はかかりません）。まちの中は工事費が高くなります。</p>
    <p><b>他人の土地</b>：線路・道路・駅・車庫は、他人の筆の上には、持ち主が貸出料を決めているか、申請して許可をもらったときだけつくれます（使用料は1区画・1日。許可のときに持ち主が決めます）。自分の筆は、タップ →「貸出料」で貸し出せます。申請は ≡ →「土地の申請」。前からあるものは、そのまま使えます。</p>
    <p><b>バス停の貸し出し</b>：ほかの人・会社のバス停は、持ち主が貸し出しているものだけ系統に入れられます（1系統・1日の使用料。使いはじめたときの値段のまま）。自分のバス停は、タップ →「貸し出し」。</p>
    <p><b>駅と車庫</b>：駅はホームの長さ（20m単位）と番線の数を決めます（20mの車両がホームに入る両数まで）。車両は車庫に車籍をおきます。</p>
    <p><b>車両</b>：122系0番台は国鉄103系とほぼ同じ性能（最高100km/h）。両はしに運転台つきの Tc（奇数向き・偶数向き）、まん中に Mp（パンタグラフつき）と M をはさんで編成にします。「編成で注文」で形式を先頭から順にえらんで、まとめて注文できます（編成番号は自分で決める）。車番は 12200-001 のように、形式の番号と3けたの番号です。編成はほかの人・会社にゆずれます（相手が受けとったら移る）。</p>
    <p><b>系統とダイヤ</b>：止まる駅を順にえらんで系統をつくり、列車を入れます。時刻を決めるのは、会社が決めた採時駅だけ（着・発・番線）。ほかの駅は走る時間から自動で決まります。回送・試運転はお客を乗せません。日付をえらぶと、その日だけ走る臨時列車になります（過ぎたら消えます）。</p>
    <p><b>運用</b>：1つの編成が1日に走る列車のならびです。列車は運用に入れ、運用に編成を入れます（編成を入れかえると、その運用の列車ぜんぶが変わる）。「運用を自動で組む」で、編成ごとの運用をつくれます。運用ごとに JSON ファイルに書き出して、バックアップや AI にまかせたあと、読みこめます。</p>
    <p><b>待避と発着番線</b>：種別ごとに優先番号（0〜9。0 がいちばん優先）があります。優先番号の大きい列車は、待避できる駅で、うしろから来る優先番号の小さい列車に先をゆずって待ちます（待避）。追いつく列車は、前の列車のあとを走ります（続行）。時刻は自動でずれます。駅の番線ごとに、下り・上り・両方と、本線・待避線を決められます（駅をタップ →「発着番線」）。種別と優先番号は、系統の画面の「種別と優先番号」で。</p>
    <p><b>連結</b>：列車ごとに、ほかの運用の編成をつなげます（3つ・16両まで）。とちゅうの駅でつなぐ・切りはなすこともできます（その運用の編成は、つなぐ駅に2分前までに着いていること）。ダイヤグラムでは太い線です。</p>
    <p><b>お金</b>：1時間ごとに運賃（駅のまわりの人・本数・速さ・冷暖房で決まる）が入り、維持費・使用料をはらいます。</p></div>`]);
}

/* ---- 車両と編成 ---- */
async function openCars(depFocus) {
  const m = modal(['車両と編成', '<p class="muted small">読みこんでいます…</p>']);
  const st = { dep: depFocus || null, pick: [], form: null, mode: 'view', seq: [] };   // seq：編成で注文する形式の列
  const load = async () => {
    const d = await api('mp_cars_list', { p_as: S.as }); if (!d) return;
    st.d = d;
    if (!st.dep || !d.depots.some(x => x.id === st.dep)) st.dep = d.depots.length ? d.depots[0].id : null;
    draw();
  };
  const carChip = (c, on) => `<span class="mp-car ${on ? 'on' : ''} ${c.busy ? 'busy' : ''}" data-car="${c.id}">${c.role && c.role !== 'Bus' ? `<small class="muted">${esc(c.role)}</small> ` : ''}${esc(c.num)}<span class="n">${c.busy ? esc({ deliver: '納車まち', move: '転属中', ac: '冷房工事', heat: '暖房工事', toilet: 'トイレ工事', inspect: '検査中', renew: '更新工事' }[c.busy] || c.busy) : `<span>状態${c.cond}</span>${c.ac ? '❄' : ''}${c.toilet ? '🚻' : ''}`}</span></span>`;
  const draw = () => {
    const d = st.d, deps = d.depots, dep = deps.find(x => x.id === st.dep);
    if (!deps.length) return m.set('車両と編成', `<p class="small">まず地図で車庫（🏭）をつくってください。車両は車庫に車籍をおきます（${esc(asName())}）。</p>`);
    const cars = d.cars.filter(c => c.depot === st.dep), forms = d.forms.filter(f => f.depot === st.dep), loose = cars.filter(c => !c.form);
    const typeOpts = d.types.filter(t => (t.role === 'Bus') === (dep.kind === 'bus'));
    m.set('車両と編成', `
      <div class="tabs-s">${deps.map(x => `<button data-dep="${x.id}" class="${x.id === st.dep ? 'on' : ''}">${esc(x.name)} ${x.n}/${x.cap}</button>`).join('')}</div>
      <h4 style="margin:12px 0 4px">編成（${forms.length}）</h4>
      ${forms.map(f => { const p = f.perf || {}; const fc = cars.filter(c => c.form === f.id).sort((a, b) => a.pos - b.pos); return `<div class="mp-item">
        <b>${esc(f.name)}</b>${f.op ? ` <small class="muted"><span>運用</span> <span>${esc(f.op.num)}</span></small>` : ''}${f.xfer ? ' <small class="mp-warn">譲渡の申しこみ中</small>' : ''}
        <small><span>${p.n}両・${p.len}m・定員${fmt(p.cap)}人・加速 ${p.acc}km/h/s・最高${p.vmax}km/h</span>${p.ac ? '<span>・冷房</span>' : ''}${p.toilet ? '<span>・トイレ</span>' : ''}<span>・状態${p.cond}・列車 ${f.trains}本</span></small>
        <div class="mp-cars">${fc.map(c => carChip(c, st.pick.includes(c.id))).join('')}</div>
        <div class="mp-row">${dep.kind === 'rail' ? `<button class="btn" data-reform="${f.id}">組みかえる</button><button class="btn" data-split="${f.id}">ばらす</button>` : ''}${f.xfer ? '' : `<button class="btn" data-give="${f.id}">ゆずる</button>`}</div></div>`; }).join('') || '<p class="muted small">まだありません</p>'}
      ${dep.kind === 'rail' ? `<h4 style="margin:12px 0 4px">編成に入っていない車両（${loose.length}）</h4><div class="mp-cars">${loose.map(c => carChip(c, st.pick.includes(c.id))).join('') || '<span class="muted small">なし</span>'}</div>` : ''}
      <div class="mp-item" style="margin-top:8px">${st.pick.length ? `<b>えらんだ車両（${st.pick.length}）</b>：${st.pick.map(id => esc((d.cars.find(c => c.id === id) || {}).num || '')).join(' → ')}
          <div class="mp-row">${dep.kind === 'rail' ? `<input class="mp-inp" style="flex:1 1 120px" data-fname placeholder="編成番号（例：R1）" value="${esc(st.form ? (d.forms.find(f => f.id === st.form) || {}).name || '' : '')}"><button class="btn main" data-mkform>${st.form ? 'この順に組みかえる' : 'この順で編成にする'}</button>` : ''}</div>
          <div class="mp-row"><button class="btn" data-w="ac">冷房をつける</button><button class="btn" data-w="heat">暖房をつける</button><button class="btn" data-w="toilet">トイレをつける</button>
            <button class="btn" data-w="inspect">検査</button><button class="btn" data-w="renew">更新工事</button><button class="btn" data-move>転属</button><button class="btn" data-scrap>廃車</button><button class="btn" data-clear>えらびなおす</button></div>`
        : '<small class="muted">車両をタップしてえらぶと、編成・改造・検査・転属・廃車ができます。編成は、えらんだ順（先頭から）になります</small>'}</div>
      ${dep.kind === 'rail' ? `<h4 style="margin:14px 0 4px">編成で注文する</h4>
        <div class="mp-row small" style="align-items:center"><span>形式を先頭から順に</span>${typeOpts.map(t => `<button class="btn" style="flex:none;padding:4px 10px" data-sq="${t.code}">${esc(t.label)}${t.face ? `<small>（${esc(T(t.face))}）</small>` : ''}</button>`).join('')}</div>
        <div class="mp-row small" style="align-items:center"><span>よく使う形</span>${[4, 6, 8, 10].map(n => `<button class="btn" style="flex:none;padding:4px 10px" data-sqn="${n}">${n}両</button>`).join('')}</div>
        <div class="mp-cars">${st.seq.map((code, i) => { const t = d.types.find(x => x.code === code) || {}; return `<span class="mp-car on" data-sqx="${i}"><b>${i + 1}</b> ${esc(t.label || code)}<span class="n">${t.face ? esc(T(t.face)) : esc(t.role || '')}</span></span>`; }).join('') || '<span class="muted small">形式をえらぶと、ここに先頭から並びます（タップで外す）</span>'}</div>
        <div class="mp-row"><input class="mp-inp" style="flex:1 1 120px" data-fno placeholder="編成番号（例：R1）"><button class="btn main" data-ford ${st.seq.length ? '' : 'disabled'}>見つもって注文</button><button class="btn" data-sqc>えらびなおす</button></div>
        <p class="muted small" style="margin:2px 0 0">編成のきまり：両はしは運転台つきの Tc（奇数向きと偶数向き）、Mp が1両以上、M は Mp の数まで。納車まで6時間</p>` : ''}
      <h4 style="margin:14px 0 4px">注文する（1両から）</h4>
      <select class="mp-inp" data-type>${typeOpts.map(t => `<option value="${t.code}">${esc(t.label)}${t.face ? '（' + esc(T(t.face)) + '）' : ''}・${X(t.price)}</option>`).join('')}</select>
      <p class="small muted" data-tnote style="margin:4px 0"></p>
      <div class="mp-row">${dep.kind === 'bus' ? '台数' : '両数'} <input class="mp-inp mp-num" type="number" min="1" max="20" value="1" data-n> <button class="btn main" data-order>見つもって注文</button></div>
      <p class="muted small">${esc(asName())}・納車まで電車は6時間、バスは3時間。車番は形式ごとに順番につきます</p>`, b => {
      const tnote = () => { const t = d.types.find(x => x.code === b.querySelector('[data-type]').value); if (!t) return; const s = (S.boot.series || []).find(x => x.code === t.series);
        b.querySelector('[data-tnote]').innerHTML = `${s ? `<span>${esc(s.name)}</span>：` : ''}<span>${esc(t.note)}</span><br><span>長さ${t.len}m・定員${t.cap}人（座席${t.seats}）・${t.mass}t</span>${t.power ? `<span>・${t.power}kW</span>` : ''}<span>・最高${t.vmax}km/h・維持費 1日 ${fmt(t.upkeep)} X</span>`; };
      tnote(); b.querySelector('[data-type]').onchange = tnote;
      b.querySelectorAll('[data-dep]').forEach(x => x.onclick = () => { st.dep = Number(x.dataset.dep); st.pick = []; st.form = null; draw(); });
      b.querySelectorAll('[data-car]').forEach(x => x.onclick = () => { const id = Number(x.dataset.car); const i = st.pick.indexOf(id); if (i >= 0) st.pick.splice(i, 1); else st.pick.push(id); draw(); });
      b.querySelectorAll('[data-reform]').forEach(x => x.onclick = () => { const f = Number(x.dataset.reform); st.form = f; st.pick = cars.filter(c => c.form === f).sort((a, c) => a.pos - c.pos).map(c => c.id); draw(); });
      b.querySelectorAll('[data-split]').forEach(x => x.onclick = async () => { if (confirm(T('この編成をばらしますか？（列車の運用からも外れます）')) && await api('mp_form_del', { p_form: Number(x.dataset.split), p_as: S.as }, 'ばらしました')) load(); });
      const q = k => b.querySelector(k);
      if (q('[data-clear]')) q('[data-clear]').onclick = () => { st.pick = []; st.form = null; draw(); };
      if (q('[data-mkform]')) q('[data-mkform]').onclick = async () => {
        const r = await api('mp_form_set', { p_form: st.form, p_cars: st.pick, p_name: q('[data-fname]').value, p_as: S.as });
        if (r) { toast(T(`編成にしました（加速 ${r.perf.acc}km/h/s・定員 ${fmt(r.perf.cap)}人）`) + (r.fee ? SEP() + T(`・組みかえ ${fmt(r.fee)} X`) : '')); st.pick = []; st.form = null; load(); }
      };
      b.querySelectorAll('[data-w]').forEach(x => x.onclick = async () => {
        const k = x.dataset.w, r = await api('mp_car_work', { p_cars: st.pick, p_kind: k, p_as: S.as, p_dry: true }); if (!r) return;
        if (!confirm(T(`${r.n}両：${x.textContent}・${fmt(r.cost)} X・${r.hours}時間（そのあいだ走れません）${r.skip ? '\n（できない車両：' + r.skip + '）' : ''}`))) return;
        if (await api('mp_car_work', { p_cars: st.pick, p_kind: k, p_as: S.as, p_dry: false }, 'たのみました')) { st.pick = []; load(); }
      });
      if (q('[data-move]')) q('[data-move]').onclick = async () => {
        const others = deps.filter(x => x.id !== st.dep && x.kind === dep.kind);
        if (!others.length) return toast('ほかの車庫がありません');
        const name = prompt(T('うつす先の車庫の番号：\n') + others.map((x, i) => `${i + 1}. ${x.name}`).join('\n'), '1'); const to = others[Number(name) - 1]; if (!to) return;
        const r = await api('mp_car_move', { p_cars: st.pick, p_depot: to.id, p_as: S.as, p_dry: true }); if (!r) return;
        if (confirm(T(`「${to.name}」へ ${r.how}・${fmt(r.cost)} X・${r.hours}時間`)) && await api('mp_car_move', { p_cars: st.pick, p_depot: to.id, p_as: S.as, p_dry: false }, '転属します')) { st.pick = []; load(); }
      };
      if (q('[data-scrap]')) q('[data-scrap]').onclick = async () => {
        const r = await api('mp_car_scrap', { p_cars: st.pick, p_as: S.as, p_dry: true }); if (!r) return;
        if (confirm(T(`${r.n}両を廃車にします（車籍がなくなります）。スクラップ代 ${fmt(r.back)} X がもどります`)) && await api('mp_car_scrap', { p_cars: st.pick, p_as: S.as, p_dry: false }, '廃車にしました')) { st.pick = []; load(); }
      };
      b.querySelectorAll('[data-sq]').forEach(x => x.onclick = () => { if (st.seq.length >= 16) return toast('1編成は16両までです'); st.seq.push(x.dataset.sq); draw(); });
      b.querySelectorAll('[data-sqx]').forEach(x => x.onclick = () => { st.seq.splice(Number(x.dataset.sqx), 1); draw(); });
      b.querySelectorAll('[data-sqn]').forEach(x => x.onclick = () => {   // Tc（奇数向き）＋（Mp M）× k ＋ Tc（偶数向き）
        const by = (role, face) => (typeOpts.find(t => t.role === role && (face == null || t.face === face)) || {}).code;
        const tc1 = by('Tc', '奇数向き') || by('Tc'), tc2 = by('Tc', '偶数向き') || by('Tc'), mp = by('Mp'), mm = by('M');
        if (!tc1 || !tc2 || !mp) return toast('この形式ではつくれません');
        const k = (Number(x.dataset.sqn) - 2) / 2; st.seq = [tc1]; for (let i = 0; i < k; i++) { st.seq.push(mp); if (mm) st.seq.push(mm); else st.seq.push(mp); } st.seq.push(tc2); draw();
      });
      if (q('[data-sqc]')) q('[data-sqc]').onclick = () => { st.seq = []; draw(); };
      if (q('[data-ford]')) q('[data-ford]').onclick = async () => {
        const no = q('[data-fno]').value.trim(); if (!no) return toast('編成番号を入れてください');
        const r = await api('mp_form_order', { p_types: st.seq, p_name: no, p_depot: st.dep, p_as: S.as, p_dry: true }); if (!r) return;
        if (!confirm(T(`編成「${no}」${r.n}両：${r.nums.join('・')}\n${fmt(r.cost)} X（維持費 1日 ${fmt(r.upkeep)} X）。${r.hours}時間で納車`))) return;
        if (await api('mp_form_order', { p_types: st.seq, p_name: no, p_depot: st.dep, p_as: S.as, p_dry: false }, '注文しました')) { st.seq = []; load(); }
      };
      b.querySelectorAll('[data-give]').forEach(x => x.onclick = () => giveForm(d.forms.find(f => f.id === Number(x.dataset.give)), load));
      q('[data-order]').onclick = async () => {
        const t = q('[data-type]').value, n = Number(q('[data-n]').value) || 1;
        const r = await api('mp_car_order', { p_type: t, p_n: n, p_depot: st.dep, p_as: S.as, p_dry: true }); if (!r) return;
        if (!confirm(T(`${r.nums.join('・')}\n${fmt(r.cost)} X（維持費 1日 ${fmt(r.upkeep)} X）。${r.hours}時間で納車`))) return;
        if (await api('mp_car_order', { p_type: t, p_n: n, p_depot: st.dep, p_as: S.as, p_dry: false }, '注文しました')) load();
      };
    });
  };
  load();
}

/* ---- 系統 ---- */
async function openRoutes() {
  const m = modal(['系統とダイヤ', '<p class="muted small">読みこんでいます…</p>']);
  const d = await api('mp_routes_list', { p_as: S.as }); if (!d) return;
  m.set('系統とダイヤ', `<div class="mp-list">${d.map(r => `<button class="mp-item" style="text-align:left" data-r="${r.id}">
      <b style="color:${esc(r.color)}">■</b> <b>${esc(r.name)}</b> <small><span>${r.kind === 'rail' ? '鉄道' : 'バス'}・${r.km}km・列車${r.trains}本</span>${r.warn ? `<span class="mp-warn">・注意 ${r.warn}本</span>` : ''}${r.ok ? '' : '<span class="mp-warn">・走れません</span>'}</small><br>
      <small>${esc((r.stops || []).join(' → '))}</small>${r.last && r.last.revenue != null ? `<br><small><span>さいきんの1時間：${fmt(r.last.served || 0)}人・${X(r.last.revenue || 0)}・${r.last.tph || 0}本</span>${r.last.load != null ? `<span>・混み具合${r.last.load}%</span>` : ''}</small>` : ''}</button>`).join('')
      || '<p class="muted small">まだありません</p>'}</div>
    <div class="mp-row"><button class="btn main" data-new="rail">＋ 鉄道の系統</button><button class="btn main" data-new="bus">＋ バスの系統</button></div>
    <p class="muted small">系統は、止まる駅（バス停）を順にえらんでつくります。下りはその順、上りは逆の順に走ります</p>`, b => {
    b.querySelectorAll('[data-r]').forEach(x => x.onclick = () => { m.close(); openDia(Number(x.dataset.r)); });
    b.querySelectorAll('[data-new]').forEach(x => x.onclick = () => { m.close(); routeBuild(x.dataset.new, null); });
  });
}
// 系統をつくる・直す：地図で駅を順にタップ
function routeBuild(kind, edit) {
  setTool('look');
  const st = { kind, stops: edit ? edit.stops.map(s => ({ id: s.id, n: s.name })) : [], name: edit ? edit.name : '', color: edit ? edit.color : (kind === 'rail' ? '#d23' : '#1d7fd8'),
               timing: new Set(edit ? edit.timing : []), dwell: edit ? edit.dwell : (kind === 'rail' ? 30 : 20) };
  hint(kind === 'rail' ? '止まる駅を、順にタップしてください（自分の駅）' : '止まるバス停を、順にタップしてください');
  S.tapHook = (x, y) => {
    const h = nearSta(x, y, 18); if (!h || h.s.k !== kind) return toast(kind === 'rail' ? '駅をタップしてください' : 'バス停をタップしてください');
    if (kind === 'rail' && !h.s.mine) return toast('自分（この名義）の駅だけです');
    if (kind === 'bus' && !h.s.mine && h.s.ln == null && !(edit && edit.stops.some(x => x.id === h.s.id))) return toast('このバス停は、持ち主が貸し出していません');
    if (st.stops.length && st.stops[st.stops.length - 1].id === h.s.id) return;
    st.stops.push({ id: h.s.id, n: h.s.n, x: h.s.fx, y: h.s.fy, ln: h.s.mine ? null : h.s.ln }); if (st.stops.length === 1 || st.stops.length === 2) st.timing.add(h.s.id); draw();
  };
  S.drawTool = (g, z) => {
    g.strokeStyle = st.color; g.lineWidth = 3; g.setLineDash([8, 6]); g.beginPath();
    let k = 0; for (const s of st.stops) { const it = S.vis && S.vis.stas.get(s.id); const x = it ? it.fx : s.x, y = it ? it.fy : s.y; if (x == null) continue; if (k++) g.lineTo(sx(x), sy(y)); else g.moveTo(sx(x), sy(y)); } g.stroke(); g.setLineDash([]);
  };
  S.toolEnd = () => { S.tapHook = null; };
  const draw = () => {
    sheet(`<h4>${edit ? '系統を直す' : kind === 'rail' ? '鉄道の系統をつくる' : 'バスの系統をつくる'}</h4>
      <div class="mp-row"><input class="mp-inp" style="flex:1 1 150px" data-nm placeholder="系統の名前（例：瑠璃本線）" value="${esc(st.name)}"><input type="color" data-col value="${esc(st.color)}" style="width:44px;height:36px;border:0;background:none"></div>
      <div class="mp-list">${st.stops.map((s, i) => `<div class="mp-item" style="display:flex;align-items:center;gap:6px"><b>${i + 1}.</b> ${esc(s.n)}${s.ln != null ? ` <small class="muted">（借りる・1日 ${X(s.ln)}）</small>` : ''}
          <label class="small" style="margin-left:auto"><input type="checkbox" data-tm="${s.id}" ${st.timing.has(s.id) ? 'checked' : ''}> 採時駅</label><button class="btn" data-rm="${i}">×</button></div>`).join('') || '<p class="muted small">まだ駅がありません</p>'}</div>
      <div class="mp-row">停車時間 <input class="mp-inp mp-num" type="number" min="10" max="300" value="${st.dwell}" data-dw> 秒</div>
      <div class="mp-row"><button class="btn" data-cancel>キャンセル</button><button class="btn main" data-ok ${st.stops.length >= 2 ? '' : 'disabled'}>${edit ? 'この順に直す' : '系統をつくる'}（${esc(asName())}）</button></div>
      <p class="muted small">採時駅：時刻表に時刻を決めて出す駅（はじめ・終わりなど）。ほかの駅は、走る時間から自動で決まります</p>`, s => {
      s.querySelector('[data-nm]').onchange = e => { st.name = e.target.value; };
      s.querySelector('[data-col]').oninput = e => { st.color = e.target.value; S.dirty = true; };
      s.querySelector('[data-dw]').onchange = e => { st.dwell = Number(e.target.value) || 30; };
      s.querySelectorAll('[data-tm]').forEach(c => c.onchange = () => { const id = Number(c.dataset.tm); if (c.checked) st.timing.add(id); else st.timing.delete(id); });
      s.querySelectorAll('[data-rm]').forEach(c => c.onclick = () => { st.stops.splice(Number(c.dataset.rm), 1); draw(); S.dirty = true; });
      s.querySelector('[data-cancel]').onclick = () => setTool('look');
      s.querySelector('[data-ok]').onclick = async () => {
        st.name = s.querySelector('[data-nm]').value.trim(); if (!st.name) return toast('系統の名前をつけてください');
        let paths = null;
        if (kind === 'bus') { paths = await busPaths(st.stops.map(x => x.id)); if (!paths) return; }
        const r = await api('mp_route_save', { p_id: edit ? edit.id : null, p_kind: kind, p_name: st.name, p_color: st.color, p_stops: st.stops.map(x => x.id),
          p_timing: st.stops.map(x => x.id).filter(id => st.timing.has(id)), p_dwell: st.dwell, p_paths: paths, p_as: S.as });
        if (r) { toast(T(edit ? '直しました' : '系統をつくりました。列車を入れましょう') + (r.stopfee ? SEP() + T(`（バス停の使用料 1日 ${fmt(r.stopfee)} X）`) : '')); setTool('look'); openDia(r.id); }
      };
    });
    S.dirty = true;
  };
  S.onSheetClose = () => setTool('look');
  draw();
}
// バスの道すじ：道路のつながり（グラフ）から、いちばん短い道をさがす（画面で）
async function busPaths(ids) {
  const it = S.vis, stas = ids.map(id => it.stas.get(id));
  if (stas.some(s => !s)) { toast('バス停が見えるところまで地図を動かしてください'); return null; }
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const s of stas) { x0 = Math.min(x0, s.fx); y0 = Math.min(y0, s.fy); x1 = Math.max(x1, s.fx); y1 = Math.max(y1, s.fy); }
  x0 = Math.floor(x0 - 40); y0 = Math.floor(y0 - 40); x1 = Math.ceil(x1 + 40); y1 = Math.ceil(y1 + 40);
  if ((x1 - x0) * (y1 - y0) > 600 * 600) { toast('バス停どうしが遠すぎます（およそ30kmまで）'); return null; }
  toast('道をさがしています…');
  const segs = new Map();
  for (let y = y0; y < y1; y += 300) for (let x = x0; x < x1; x += 300) {
    const d = await api('mp_area', { p_x0: x, p_y0: y, p_x1: Math.min(x1, x + 300), p_y1: Math.min(y1, y + 300), p_lod: 0 }); if (!d) return null;
    for (const s of d.segs) if (s.k === 'road' && (s.c !== 'priv' || s.mine)) segs.set(s.id, s);
  }
  // 点 → つながる線
  const adj = new Map(); const addA = (n, s) => { if (n == null) return; let a = adj.get(n); if (!a) adj.set(n, a = []); a.push(s); };
  for (const s of segs.values()) { addA(s.n0, s); addA(s.n1, s); }
  const out = [];
  for (let i = 0; i + 1 < stas.length; i++) {
    const A = stas[i], B = stas[i + 1];
    if (A.seg === B.seg) { out.push([A.seg]); continue; }
    const sa = segs.get(A.seg), sb = segs.get(B.seg); if (!sa || !sb) { toast('バス停の道路が読めません'); return null; }
    // ダイクストラ（点ごと）：はじめは A の線の両はし
    const dist = new Map(), prev = new Map(), done = new Set(), pq = [];
    const push = (n, d, from) => { if (n == null) return; if (!dist.has(n) || d < dist.get(n)) { dist.set(n, d); prev.set(n, from); pq.push([d, n]); } };
    push(sa.n0, A.at, null); push(sa.n1, sa.len - A.at, null);
    let goal = null, best = Infinity;
    while (pq.length) {
      pq.sort((a, b) => a[0] - b[0]); const [d, n] = pq.shift(); if (done.has(n)) continue; done.add(n);
      if (d >= best) break;
      if (n === sb.n0 && d + B.at < best) { best = d + B.at; goal = n; }
      if (n === sb.n1 && d + sb.len - B.at < best) { best = d + sb.len - B.at; goal = n; }
      for (const s of adj.get(n) || []) { if (s.id === sa.id || s.id === sb.id) continue; const m2 = s.n0 === n ? s.n1 : s.n0; push(m2, d + s.len, [n, s.id]); }
    }
    if (goal == null) { toast(`「${A.n}」から「${B.n}」への道が見つかりません`); return null; }
    const mid = []; for (let n = goal; prev.get(n); n = prev.get(n)[0]) mid.unshift(prev.get(n)[1]);
    out.push([A.seg, ...mid, B.seg]);
  }
  return out;
}

/* ---- ダイヤ ---- */
const warnH = w => String(w || '').split(' / ').filter(Boolean).map(x => `<span>${esc(x)}</span>`).join('<br>');
const hms = s => { if (s == null) return ''; s = ((s % 86400) + 86400) % 86400; return String(Math.floor(s / 3600)).padStart(2, '0') + ':' + String(Math.floor(s / 60) % 60).padStart(2, '0'); };
const parseHM = t => { const m = String(t || '').trim().match(/^(\d{1,2})[:：]?(\d{2})(?:[:：](\d{2}))?$/); if (!m) return null; return Number(m[1]) * 3600 + Number(m[2]) * 60 + Number(m[3] || 0); };
const KIND_COL = { 普通: '#222', 各停: '#222', 快速: '#e07020', 急行: '#d42', 特急: '#c0186a', 回送: '#999', 試運転: '#7b4fd8' };
const KINDS = ['普通', '快速', '急行', '特急', '回送', '試運転'];
const mdL = d => { const m = String(d || '').match(/^\d{4}-(\d{2})-(\d{2})/); return m ? T(`${Number(m[1])}月${Number(m[2])}日`) : ''; };   // 臨時列車の日付（10月25日）
const dayAdd = (d, n) => { const t = new Date(d + 'T00:00:00Z'); t.setUTCDate(t.getUTCDate() + n); return t.toISOString().slice(0, 10); };
const kindL = k => k === '普通' ? '各停' : k;   // 種別の見せ方（データは「普通」のまま）
async function openDia(rid) {
  const m = modal(['系統', '<p class="muted small">読みこんでいます…</p>'], null, 'mp-wide');
  let D = null, tab = 'dia';
  const lf = { kinds: new Set(), sers: new Set(), dirs: new Set(), sort: 'dep' };   // 列車一覧の絞り込み（空はぜんぶ）・並べ替え
  const load = async () => { D = await api('mp_dia', { p_route: rid }); if (!D) return m.close(); S.routeHi = { legs: D.legs, color: D.color }; S.dirty = true; draw(); };
  m.onclose = () => { S.routeHi = null; S.dirty = true; };
  const draw = () => {
    const idx = new Map(D.stops.map((s, i) => [s.id, i]));
    m.set(D.name, `<p class="small" style="margin:0"><b style="color:${esc(D.color)}">■</b> <span>${D.kind === 'rail' ? '鉄道' : 'バス'}</span>・<span>${esc(D.owner)}</span>・<span>${D.km[D.km.length - 1]}km・停車 ${D.dwell}秒</span>
        ${D.ok ? '' : `<br><span class="mp-warn"><span>走れません：</span> <span>${esc(D.why || '')}</span></span>`}${D.last && D.last.revenue != null ? `<br>さいきんの1時間：${fmt(D.last.served || 0)}人・${X(D.last.revenue || 0)}・${D.last.tph}本・混み具合${D.last.load}%・平均${D.last.speed}km/h` : ''}</p>
      <div class="tabs-s" style="margin-top:8px">${[['dia', 'ダイヤグラム'], ['tt1', '時刻表（下り）'], ['tt2', '時刻表（上り）'], ['list', '列車']].map(t => `<button data-tab="${t[0]}" class="${tab === t[0] ? 'on' : ''}">${t[1]}</button>`).join('')}</div>
      <div data-pane style="margin-top:8px"></div>
      ${D.mine ? `<div class="mp-row"><button class="btn main" data-add>＋ 列車</button><button class="btn" data-bulk>＋ まとめて</button><button class="btn" data-auto>運用を自動で組む</button>
        <button class="btn" data-edit>駅の順を直す</button><button class="btn" data-kp>種別と優先番号</button><button class="btn" data-del>系統を消す</button></div>
        <div class="mp-row"><button class="btn" style="flex:none" data-undo ${D.undo ? '' : 'disabled'}>↶ 取り消す</button>${D.undo ? `<span class="small muted"><span>もどす：</span><span>${esc(D.undo.what)}</span><span>（${D.undo.n}回もどせます）</span></span>` : '<span class="small muted">もどせる操作はありません</span>'}</div>` : ''}`, b => {
      b.querySelectorAll('[data-tab]').forEach(x => x.onclick = () => { tab = x.dataset.tab; draw(); });
      { const un = b.querySelector('[data-undo]'); if (un) un.onclick = async () => {
        if (!D.undo || !confirm(T('この操作を取り消して、その前のダイヤにもどしますか？') + '\n' + T(D.undo.what))) return;
        const r = await api('mp_dia_undo', { p_route: rid }); if (r) { toast(T('取り消しました') + SEP() + '（' + T(r.what) + '）'); load(); }
      }; }
      const pane = b.querySelector('[data-pane]');
      if (tab === 'dia') diaCanvas(pane, D, t => trainEdit(D, t, load));
      if (tab === 'tt1' || tab === 'tt2') pane.innerHTML = ttTable(D, tab === 'tt1' ? 1 : -1, idx);
      if (tab === 'list') {
        // 形式（編成の系列・両数）・種別・向きで絞りこむ。発車時刻・列車番号・種別・形式で並べかえる
        const serOf = t => t.fser ? t.fser + '|' + t.fn : '';   // 形式（系列）と両数
        const serH = k => { if (!k) return '<span>編成なし</span>'; const [a, n] = k.split('|'); return `<span>${esc(a)}</span>・<span>${D.kind === 'bus' ? `${n}台` : `${n}両`}</span>`; };
        const ko = k => { const x = (D.kinds || []).find(y => y.name === k); return x ? x.prio * 100 + (KINDS.indexOf(k) + 1) : 999; };   // 優先番号の順
        const kinds = [...new Set(D.trains.map(t => t.kind))].sort((a, b) => ko(a) - ko(b) || a.localeCompare(b, 'ja'));
        const sers = [...new Set(D.trains.map(serOf))].sort((a, b) => (a === '') - (b === '') || a.localeCompare(b, 'ja', { numeric: true }));
        for (const k of [...lf.kinds]) if (!kinds.includes(k)) lf.kinds.delete(k);
        for (const k of [...lf.sers]) if (!sers.includes(k)) lf.sers.delete(k);
        const pass = t => (!lf.kinds.size || lf.kinds.has(t.kind)) && (!lf.sers.size || lf.sers.has(serOf(t))) && (!lf.dirs.size || lf.dirs.has(t.dir));
        const byNum = (a, b) => String(a.num).localeCompare(String(b.num), 'ja', { numeric: true });
        const cmp = { dep: (a, b) => a.dep - b.dep || byNum(a, b), num: (a, b) => byNum(a, b) || a.dep - b.dep, kind: (a, b) => ko(a.kind) - ko(b.kind) || a.dep - b.dep,
                      ser: (a, b) => (serOf(a) === '') - (serOf(b) === '') || serOf(a).localeCompare(serOf(b), 'ja', { numeric: true }) || a.dep - b.dep }[lf.sort];
        const L = D.trains.filter(pass).sort(cmp);
        const chip = (g, v, label, on) => `<button data-${g}="${esc(String(v))}" class="${on ? 'on' : ''}">${label}</button>`;
        const row = (title, g, all, items) => `<div class="mp-row small" style="align-items:center"><span style="min-width:3.5em">${title}</span><span class="mp-seg" style="flex-wrap:wrap">${chip(g, '*', 'すべて', !all.size)}${items.join('')}</span></div>`;
        pane.innerHTML = `${row('種別', 'fk', lf.kinds, kinds.map(k => chip('fk', k, `<span>${esc(kindL(k))}</span>`, lf.kinds.has(k))))}
          ${row('形式', 'fs', lf.sers, sers.map(k => chip('fs', k, serH(k), lf.sers.has(k))))}
          ${row('向き', 'fd', lf.dirs, [chip('fd', 1, '下り', lf.dirs.has(1)), chip('fd', -1, '上り', lf.dirs.has(-1))])}
          <div class="mp-row small" style="align-items:center"><span style="min-width:3.5em">並べかえ</span><select class="mp-inp" style="width:auto" data-sort>${[['dep', '発車時刻'], ['num', '列車番号'], ['kind', '種別'], ['ser', '形式']].map(o => `<option value="${o[0]}" ${lf.sort === o[0] ? 'selected' : ''}>${o[1]}</option>`).join('')}</select>
            <span class="muted">${L.length} / ${D.trains.length}本</span></div>
          <div class="mp-list">${L.map(t => `<button class="mp-item" style="text-align:left" data-t="${t.id}"><b>${esc(t.num)}</b> <span>${esc(kindL(t.kind))}・${t.dir === 1 ? '下り' : '上り'}・${hms(t.dep)}発</span>${t.day ? ` <small class="mp-tag"><span>臨時</span> <span>${mdL(t.day)}</span></small>` : ''}・${t.onum ? `<small class="muted"><span>運用</span> <span>${esc(t.onum)}</span></small> ` : ''}${t.fname ? `<span>${esc(t.fname)}</span>${t.fser ? `<small class="muted">（${serH(serOf(t))}）</small>` : ''}` : `<span class="mp-warn">${t.onum ? '運用に編成なし' : '編成なし'}</span>`}${cplL(t, D)}${taiL(t, D)}${t.warn ? `<br><small class="mp-warn">${warnH(t.warn)}</small>` : ''}</button>`).join('')
            || `<p class="muted small">${D.trains.length ? '条件にあう列車はありません' : '列車はまだありません'}</p>`}</div>`;
        const tog = (set, v) => { if (v === '*') set.clear(); else if (set.has(v)) set.delete(v); else set.add(v); draw(); };
        pane.querySelectorAll('[data-fk]').forEach(x => x.onclick = () => tog(lf.kinds, x.dataset.fk));
        pane.querySelectorAll('[data-fs]').forEach(x => x.onclick = () => tog(lf.sers, x.dataset.fs));
        pane.querySelectorAll('[data-fd]').forEach(x => x.onclick = () => tog(lf.dirs, x.dataset.fd === '*' ? '*' : Number(x.dataset.fd)));
        pane.querySelector('[data-sort]').onchange = e => { lf.sort = e.target.value; draw(); };
        pane.querySelectorAll('[data-t]').forEach(x => x.onclick = () => trainEdit(D, D.trains.find(t => t.id === Number(x.dataset.t)), load));
      }
      const q = k => b.querySelector(k);
      if (q('[data-add]')) q('[data-add]').onclick = () => trainEdit(D, null, load);
      if (q('[data-bulk]')) q('[data-bulk]').onclick = () => trainBulk(D, load);
      if (q('[data-auto]')) q('[data-auto]').onclick = () => autoForm(D, load);
      if (q('[data-edit]')) q('[data-edit]').onclick = () => { m.close(); routeBuild(D.kind, D); };
      if (q('[data-kp]')) q('[data-kp]').onclick = () => kindsEdit(D, load);
      if (q('[data-del]')) q('[data-del]').onclick = async () => { if (confirm(T('この系統と、列車をぜんぶ消しますか？')) && await api('mp_route_del', { p_id: D.id, p_as: S.as }, '消しました')) m.close(); };
    });
  };
  load();
}
// 列車の連結（一覧）：＋連結 A02（なか〜ひがし）。つながないものは、わけも
function cplL(t, D) {
  const cx = t.cplx || []; if (!cx.length) return '';
  const nm = id => (D.stops.find(s => s.id === id) || {}).name || '';
  const s0 = t.sched && t.sched.length ? t.sched[0][0] : null, s1 = t.sched && t.sched.length ? t.sched[t.sched.length - 1][0] : null;
  return '<br><small>' + cx.map(c => `<span class="${c.ok ? '' : 'mp-warn'}">＋<span>連結</span> <span translate="no">${esc(c.num || '')}</span>${c.v && (c.a !== s0 || c.b !== s1) ? `（<span translate="no">${esc(nm(c.a))}</span>〜<span translate="no">${esc(nm(c.b))}</span>）` : ''}${c.ok ? '' : `：<span>${esc(c.w || '')}</span>`}</span>`).join(' ') + '</small>';
}
// 待避・続行（一覧）：待避 みどり：先に通す列車 201（1分12秒）／続行 あさひ：前の列車 102（40秒）
const mmss = n => n >= 60 ? (n % 60 ? T(`${Math.floor(n / 60)}分${n % 60}秒`) : T(`${Math.floor(n / 60)}分`)) : T(`${n}秒`);
function taiL(t, D) {
  const x = t.tai || []; if (!x.length) return '';
  const nm = id => (D.stops.find(s => s.id === id) || {}).name || '';
  return '<br><small class="muted">' + x.map(a => `<span>${a.f ? '続行' : '待避'}</span> <span translate="no">${esc(nm(a.s))}</span>：<span>${a.f ? '前の列車' : '先に通す列車'}</span> <span translate="no">${(a.by || []).map(esc).join('・')}</span>（<span>${esc(mmss(a.sec))}</span>）`).join('<br>') + '</small>';
}
// 種別と優先番号（0 がいちばん優先。名義ごと）。種別を足す・消す
function kindsEdit(D, reload) {
  const L = (D.kinds || []).map(k => ({ ...k }));
  const m = modal(['種別と優先番号', '']);
  const draw = () => m.set('種別と優先番号', `<div class="mp-list">${L.map((k, i) => `<div class="mp-row small" style="align-items:center;margin-top:4px">
      <b style="min-width:5em;color:${KIND_COL[k.name] || '#2a7'}">${esc(kindL(k.name))}</b>
      <select class="mp-inp" style="width:auto" data-kp="${i}">${Array.from({ length: 10 }, (_, n) => `<option value="${n}" ${k.prio === n ? 'selected' : ''}>${n}</option>`).join('')}</select>
      ${k.std ? '' : `<button class="btn" style="flex:none" data-kx="${i}">×</button>`}</div>`).join('')}</div>
    <div class="mp-row"><input class="mp-inp" style="flex:1 1 120px" data-kn placeholder="種別を足す（例：準急）" maxlength="8"><button class="btn" data-ka>足す</button></div>
    <div class="mp-row"><button class="btn main" data-ok>決める</button></div>
    <p class="muted small">優先番号は 0 がいちばん優先（0〜9）。優先番号の大きい列車は、待避できる駅で優先番号の小さい列車に先をゆずります（待避）。追いつく列車は、前の列車のあとを走ります（続行）。同じ番号なら、先に出る列車が先です。${esc(asName())}のぜんぶの系統で使います</p>`, b => {
    b.querySelectorAll('[data-kp]').forEach(x => x.onchange = () => { L[Number(x.dataset.kp)].prio = Number(x.value); });
    b.querySelectorAll('[data-kx]').forEach(x => x.onclick = () => { L.splice(Number(x.dataset.kx), 1); draw(); });
    b.querySelector('[data-ka]').onclick = () => {
      const nm = b.querySelector('[data-kn]').value.trim(); if (!nm) return toast('種別の名前を入れてください');
      if (L.some(k => k.name === nm)) return toast('その種別はもうあります');
      L.push({ name: nm, prio: 4, std: false, add: true }); draw();
    };
    b.querySelector('[data-ok]').onclick = async () => {
      const r = await api('mp_kinds_set', { p_items: L.map(k => ({ name: k.name, prio: k.prio })), p_as: S.as }, '決めました');
      if (r) { m.close(); if (reload) reload(); }
    };
  });
  draw();
}
function ttTable(D, dir, idx) {
  const ord = dir === 1 ? D.stops : D.stops.slice().reverse();
  const trs = D.trains.filter(t => t.dir === dir).sort((a, b) => a.dep - b.dep);
  if (!trs.length) return '<p class="muted small">列車はまだありません</p>';
  const cell = (t, s) => {
    const e = (t.sched || []).find(x => x[0] === s.id);
    if (!e) { const i0 = t.sched.length ? idx.get(t.sched[0][0]) : -1, i1 = t.sched.length ? idx.get(t.sched[t.sched.length - 1][0]) : -1, i = idx.get(s.id);
      return (Math.min(i0, i1) < i && i < Math.max(i0, i1)) ? '<span class="muted">レ</span>' : '<span class="muted">‥</span>'; }
    const tm = D.timing.includes(s.id);
    return `<span style="${tm ? 'font-weight:800' : ''}">${e[2] != null ? hms(e[2]) : hms(e[1]) + '着'}</span>${tm && e[3] ? `<br><small class="muted">${e[3]}番</small>` : ''}`;
  };
  return `<div class="mp-scroll"><table class="mp-tt"><tr><th></th>${trs.map(t => `<th style="color:${KIND_COL[t.kind] || '#222'}">${esc(t.num)}<br>${esc(kindL(t.kind))}${t.day ? `<br><small>${mdL(t.day)}</small>` : ''}</th>`).join('')}</tr>
    ${ord.map(s => `<tr><td class="st">${esc(s.name)}${D.timing.includes(s.id) ? ' ◎' : ''}</td>${trs.map(t => `<td>${cell(t, s)}</td>`).join('')}</tr>`).join('')}
    <tr><td class="st">運用</td>${trs.map(t => `<td><small>${t.onum ? esc(t.onum) : '—'}</small></td>`).join('')}</tr>
    <tr><td class="st">編成</td>${trs.map(t => `<td><small>${t.fname ? esc(t.fname) : '—'}</small></td>`).join('')}</tr>
    <tr><td class="st">両数</td>${trs.map(t => `<td><small>${t.fn ? t.fn + (t.cplx || []).filter(c => c.ok).map(c => '+' + c.n).join('') : '—'}</small></td>`).join('')}</tr></table></div><p class="muted small">◎ 採時駅（太字の時刻）・レ 通過・日付があるのは臨時列車（その日だけ）</p>`;
}
// ダイヤグラム（よこ：時刻・たて：駅）。ドラッグでよこに動く・ピンチでよこに拡大
function diaCanvas(pane, D, onTrain) {
  pane.innerHTML = `<canvas class="mp-dia"></canvas><p class="muted small" style="margin:4px 0 0">よこにドラッグで動かす・2本指でよこに拡大・列車の線をタップで編集（一点鎖線は臨時列車・灰色の点線は編成なし・太い線は連結している区間）</p>`;
  const cv = pane.querySelector('canvas'), dpr = Math.min(2, window.devicePixelRatio || 1);
  const km = D.km.map(Number), tot = Math.max(0.1, km[km.length - 1]);
  const V = { t0: 5 * 3600, sec: 19 * 3600 };
  const ML = 78, MT = 16, MB = 22;
  const draw = () => {
    const W = cv.clientWidth, H = cv.clientHeight; cv.width = W * dpr; cv.height = H * dpr;
    const g = cv.getContext('2d'); g.setTransform(dpr, 0, 0, dpr, 0, 0); g.clearRect(0, 0, W, H);
    const X = t => ML + (t - V.t0) / V.sec * (W - ML - 8), Y = k => MT + k / tot * (H - MT - MB);
    g.font = '11px system-ui, sans-serif'; g.textBaseline = 'middle';
    // 時刻のめもり
    const stepM = V.sec > 12 * 3600 ? 60 : V.sec > 4 * 3600 ? 30 : V.sec > 3600 ? 10 : 2;
    for (let t = Math.ceil(V.t0 / (stepM * 60)) * stepM * 60; t <= V.t0 + V.sec; t += stepM * 60) {
      const x = X(t); g.strokeStyle = t % 3600 === 0 ? '#bbb' : '#eee'; g.lineWidth = 1; g.beginPath(); g.moveTo(x, MT); g.lineTo(x, H - MB); g.stroke();
      if (t % 3600 === 0 || stepM <= 10) { g.fillStyle = '#666'; g.textAlign = 'center'; g.fillText(t % 3600 === 0 ? T(String(Math.floor(t / 3600) % 24) + '時') : String(Math.floor(t / 60) % 60), x, H - 9); }
    }
    // 駅
    D.stops.forEach((s, i) => { const y = Y(km[i]); g.strokeStyle = D.timing.includes(s.id) ? '#888' : '#ddd'; g.beginPath(); g.moveTo(ML, y); g.lineTo(W - 8, y); g.stroke();
      g.fillStyle = '#222'; g.textAlign = 'right'; g.fillText(s.name, ML - 6, y); });
    // 列車
    const idx = new Map(D.stops.map((s, i) => [s.id, i]));
    D.paths = [];
    for (const t of D.trains) {
      const pts = [], at = new Map();   // 駅 → [着の点, 発の点]
      for (const e of t.sched || []) { const k = km[idx.get(e[0])], i0 = pts.length; if (e[1] != null) pts.push([X(e[1]), Y(k)]); if (e[2] != null) pts.push([X(e[2]), Y(k)]); at.set(e[0], [i0, pts.length - 1]); }
      if (pts.length < 2) continue;
      g.strokeStyle = t.form && !t.warn ? (KIND_COL[t.kind] || '#222') : t.form ? '#d23' : '#aaa'; g.lineWidth = 1.4; g.setLineDash(!t.form ? [4, 3] : t.day ? [9, 3, 2, 3] : []);
      g.beginPath(); pts.forEach((p, i) => i ? g.lineTo(p[0], p[1]) : g.moveTo(p[0], p[1])); g.stroke(); g.setLineDash([]);
      // 連結している区間は太く
      for (const c of t.cplx || []) {
        const a = c.ok && at.get(c.a), b = c.ok && at.get(c.b); if (!a || !b) continue;
        g.lineWidth = 3.4; g.beginPath(); for (let i = a[1]; i <= b[0]; i++) { if (i === a[1]) g.moveTo(pts[i][0], pts[i][1]); else g.lineTo(pts[i][0], pts[i][1]); } g.stroke();
      }
      D.paths.push([t, pts]);
    }
  };
  let P = new Map(), pin = null, dr = null, moved = false;
  cv.addEventListener('pointerdown', e => { cv.setPointerCapture(e.pointerId); P.set(e.pointerId, e.clientX); moved = false;
    if (P.size === 1) dr = { x: e.clientX, t0: V.t0 }; else if (P.size === 2) { const [a, b] = [...P.values()]; pin = { d: Math.abs(a - b), sec: V.sec, mid: (a + b) / 2, t0: V.t0 }; dr = null; } });
  cv.addEventListener('pointermove', e => { if (!P.has(e.pointerId)) return; P.set(e.pointerId, e.clientX); const W = cv.clientWidth - ML - 8;
    if (pin && P.size >= 2) { const [a, b] = [...P.values()]; const f = pin.d / Math.max(20, Math.abs(a - b)); const r = cv.getBoundingClientRect();
      const tm = pin.t0 + (pin.mid - r.left - ML) / W * pin.sec; V.sec = clamp(pin.sec * f, 1800, 24 * 3600); V.t0 = clamp(tm - (pin.mid - r.left - ML) / W * V.sec, 0, 86400 - V.sec); moved = true; draw(); return; }
    if (dr) { const dx = e.clientX - dr.x; if (Math.abs(dx) > 5) moved = true; V.t0 = clamp(dr.t0 - dx / W * V.sec, 0, 86400 - V.sec); draw(); } });
  const up = e => { P.delete(e.pointerId); if (P.size < 2) pin = null;
    if (dr && !moved && e.type === 'pointerup' && D.mine) { const r = cv.getBoundingClientRect(), x = e.clientX - r.left, y = e.clientY - r.top; let best = null, bd = 10;
      for (const [t, pts] of D.paths || []) for (let i = 0; i + 1 < pts.length; i++) { const a = pts[i], b = pts[i + 1], dx = b[0] - a[0], dy = b[1] - a[1], L2 = dx * dx + dy * dy; let u = L2 ? ((x - a[0]) * dx + (y - a[1]) * dy) / L2 : 0; u = clamp(u, 0, 1); const d = Math.hypot(x - a[0] - dx * u, y - a[1] - dy * u); if (d < bd) { bd = d; best = t; } }
      if (best) onTrain(best); }
    if (!P.size) dr = null; };
  cv.addEventListener('pointerup', up); cv.addEventListener('pointercancel', up);
  cv.addEventListener('wheel', e => { e.preventDefault(); const W = cv.clientWidth - ML - 8, r = cv.getBoundingClientRect(), mx = e.clientX - r.left - ML;
    if (Math.abs(e.deltaX) > Math.abs(e.deltaY)) V.t0 = clamp(V.t0 + e.deltaX / W * V.sec, 0, 86400 - V.sec);
    else { const tm = V.t0 + mx / W * V.sec; V.sec = clamp(V.sec * Math.exp(e.deltaY * 0.002), 1800, 86400); V.t0 = clamp(tm - mx / W * V.sec, 0, 86400 - V.sec); } draw(); }, { passive: false });
  requestAnimationFrame(draw);
}
// 列車を1本つくる・直す
// 運用のえらび方：運用（o:id）・運用に入っていない編成（f:id。その編成の運用をつくる）・なし
// 種別のえらびかた：はじめからの種別と、自分で足した種別（優先番号つき）
function kindOpts(D, cur) {
  const ks = (D.kinds || []).length ? D.kinds.map(k => k.name) : KINDS.slice();
  if (cur && !ks.includes(cur)) ks.push(cur);
  const pr = k => { const x = (D.kinds || []).find(y => y.name === k); return x ? x.prio : null; };
  return ks.map(k => `<option value="${esc(k)}" ${cur === k ? 'selected' : ''}>${esc(pr(k) != null ? T(`${kindL(k)}（優先番号 ${pr(k)}）`) : kindL(k))}</option>`).join('');
}
async function trainEdit(D, t, reload) {
  if (!D.mine) return;
  const cl = await api('mp_cars_list', { p_as: S.as }); if (!cl) return;
  const forms = cl.forms.filter(f => f.perf && f.perf.rail === (D.kind === 'rail'));
  const tm = D.stops.filter(s => D.timing.includes(s.id));
  const ops = (D.ops || []).slice();
  const st = t ? { ...t, tt: { ...(t.tt || {}) }, skip: new Set(t.skip || []), opv: t.op ? 'o:' + t.op : '', day: t.day || null, cpl: (t.cpl || []).map(c => ({ op: c.op, a: c.a, b: c.b })) }
               : { dir: 1, num: '', kind: D.kind === 'rail' ? '普通' : '', dep: 7 * 3600, opv: '', day: null, tt: {}, skip: new Set(), cpl: [] };
  const m = modal([t ? `列車 ${t.num}` : '列車をつくる', '']);
  const bus = D.kind === 'bus';
  const opL = o => esc(o.fname ? T(bus ? `${o.num}（${o.fname}・${o.n}台）` : `${o.num}（${o.fname}・${o.n}両）`) : T(`${o.num}（編成なし）`));
  const fL = f => esc(T(bus ? `${f.name}（${f.perf.n}台・${f.perf.len}m）` : `${f.name}（${f.perf.n}両・${f.perf.len}m）`));
  const draw = () => {
    const ord = st.dir === 1 ? D.stops : D.stops.slice().reverse();
    const op = st.opv.startsWith('o:') ? ops.find(o => o.id === Number(st.opv.slice(2))) : null, fo = st.opv.startsWith('f:') ? forms.find(f => f.id === Number(st.opv.slice(2))) : null;
    const freeF = forms.filter(f => !f.op), mid = ord.slice(1, -1);
    // 連結：つなぐ運用（この列車の運用はのぞく）・つなぐ駅・切りはなす駅（走る順）
    const cops = sel => `<option value="">${esc(T('（運用をえらぶ）'))}</option>` + ops.filter(o => 'o:' + o.id !== st.opv).map(o => `<option value="${o.id}" ${o.id === sel ? 'selected' : ''}>${opL(o)}</option>`).join('');
    const cplH = bus ? '' : `<h4 style="margin:10px 0 4px">連結</h4>
      ${st.cpl.map((c, i) => { const cx = t && t.cplx && t.cplx[i] && t.cplx[i].op === c.op ? t.cplx[i] : null; return `<div class="mp-item small" style="margin-bottom:6px">
        <div class="mp-row" style="margin-top:0;align-items:center"><select class="mp-inp" style="flex:1 1 140px" data-co="${i}">${cops(c.op)}</select><button class="btn" style="flex:none" data-cx="${i}">×</button></div>
        <div class="mp-row" style="align-items:center"><select class="mp-inp" style="flex:1 1 110px" data-ca="${i}"><option value="">${esc(T('始発からつなぐ'))}</option>${mid.map(s => `<option value="${s.id}" ${c.a === s.id ? 'selected' : ''}>${esc(T(`${s.name}でつなぐ`))}</option>`).join('')}</select>
          <select class="mp-inp" style="flex:1 1 110px" data-cb="${i}"><option value="">${esc(T('終点まで'))}</option>${mid.map(s => `<option value="${s.id}" ${c.b === s.id ? 'selected' : ''}>${esc(T(`${s.name}で切りはなす`))}</option>`).join('')}</select></div>
        ${cx ? (cx.ok ? `<small class="muted"><span>${cx.n}両をつなぎます</span></small>` : `<small class="mp-warn">${esc(cx.w || '')}</small>`) : ''}</div>`; }).join('')}
      ${st.cpl.length < 3 ? '<div class="mp-row" style="margin-top:0"><button class="btn" data-cadd>＋ 連結する運用</button></div>' : ''}
      <p class="muted small">ほかの運用の編成を、この列車につなぎます（3つ・16両まで）。とちゅうの駅でつなぐ・切りはなすこともできます。つなぐ駅には、その編成が2分前までに着いていないとつながりません</p>`;
    m.set(t ? `列車 ${t.num}` : '列車をつくる', `
      <div class="mp-row"><input class="mp-inp" style="flex:1 1 90px" data-num placeholder="列車番号" value="${esc(st.num)}">
        <select class="mp-inp" style="flex:1 1 90px" data-kind>${kindOpts(D, st.kind)}</select>
        <span class="mp-seg"><button data-dir="1" class="${st.dir === 1 ? 'on' : ''}">下り</button><button data-dir="-1" class="${st.dir === -1 ? 'on' : ''}">上り</button></span></div>
      <div class="mp-row">始発（${esc(ord[0].name)}）の発車 <input class="mp-inp mp-num" data-dep value="${hms(st.dep)}"></div>
      <div class="mp-row" style="align-items:center"><span>走る日</span><span class="mp-seg"><button data-day="0" class="${st.day ? '' : 'on'}">毎日</button><button data-day="1" class="${st.day ? 'on' : ''}">この日だけ（臨時）</button></span>
        ${st.day ? `<input class="mp-inp" style="width:auto" type="date" data-dt value="${esc(st.day)}" min="${esc(D.today)}" max="${esc(dayAdd(D.today, 60))}">` : ''}</div>
      <div class="mp-row" style="align-items:center"><span>運用</span><select class="mp-inp" style="flex:1 1 160px" data-op><option value="">（運用なし・編成なし）</option>
          ${ops.length ? `<optgroup label="${esc(T('運用'))}">${ops.map(o => `<option value="o:${o.id}" ${st.opv === 'o:' + o.id ? 'selected' : ''}>${opL(o)}</option>`).join('')}</optgroup>` : ''}
          ${freeF.length ? `<optgroup label="${esc(T('運用に入っていない編成（その編成の運用をつくる）'))}">${freeF.map(f => `<option value="f:${f.id}" ${st.opv === 'f:' + f.id ? 'selected' : ''}>${fL(f)}</option>`).join('')}</optgroup>` : ''}
          <option value="new">${esc(T('＋ 新しい運用…'))}</option></select></div>
      <p class="small muted" style="margin:0 0 4px">${op ? (op.fname ? `<span>この列車は 運用 ${esc(op.num)} の編成「${esc(op.fname)}」で走ります</span>` : `<span class="mp-warn">運用 ${esc(op.num)} には編成が入っていません（≡ →「運用」で入れられます）</span>`)
        : fo ? `<span>編成「${esc(fo.name)}」の運用をつくって入れます</span>` : '<span>編成がない列車は走りません</span>'}</p>
      ${cplH}
      <h4 style="margin:10px 0 4px">採時駅の時刻・番線</h4>
      ${tm.map(s => { const v = st.tt[s.id] || {}; return `<div class="mp-row"><b style="min-width:5em">${esc(s.name)}</b>到着<input class="mp-inp mp-num" data-a="${s.id}" value="${v.a != null ? hms(v.a) : ''}" placeholder="—">
          発車<input class="mp-inp mp-num" data-d="${s.id}" value="${v.d != null ? hms(v.d) : ''}" placeholder="—">
          <select class="mp-inp" style="width:auto" data-tr="${s.id}"><option value="">${esc(T('番線（いつもの）'))}</option>${Array.from({ length: s.tracks }, (_, i) => `<option ${v.t === i + 1 ? 'selected' : ''} value="${i + 1}">${esc(s.trk && s.trk[i] ? trkL(s.trk[i], i) : T(`${i + 1}番線`))}</option>`).join('')}</select></div>`; }).join('')}
      <p class="muted small">空のところは、走る時間から自動で決まります（いちばん早い時刻）。遅くするときだけ入れます</p>
      ${ord.length > 2 ? `<h4 style="margin:10px 0 4px">止まる駅</h4><div class="mp-cars">${ord.slice(1, -1).map(s => `<span class="mp-car ${st.skip.has(s.id) ? '' : 'on'}" data-sk="${s.id}">${esc(s.name)}<span class="n">${st.skip.has(s.id) ? '通過' : '停車'}</span></span>`).join('')}</div>` : ''}
      ${t && t.warn ? `<p class="mp-warn">${warnH(t.warn)}</p>` : ''}
      <p class="muted small">回送・試運転はお客を乗せません</p>
      <div class="mp-row">${t ? '<button class="btn" data-del>消す</button>' : ''}<button class="btn main" data-ok>${t ? '保存' : 'つくる'}</button></div>`, b => {
      const q = k => b.querySelector(k);
      const keep = () => {
        st.num = q('[data-num]').value; st.kind = q('[data-kind]').value; st.dep = parseHM(q('[data-dep]').value) ?? st.dep;
        if (q('[data-dt]')) st.day = q('[data-dt]').value || st.day;
        st.cpl = st.cpl.map((c, i) => q(`[data-co="${i}"]`) ? { op: Number(q(`[data-co="${i}"]`).value) || null, a: Number(q(`[data-ca="${i}"]`).value) || null, b: Number(q(`[data-cb="${i}"]`).value) || null } : c);
        for (const s of tm) { const a = parseHM(q(`[data-a="${s.id}"]`).value), d = parseHM(q(`[data-d="${s.id}"]`).value), r = q(`[data-tr="${s.id}"]`).value;
          const o = {}; if (a != null) o.a = a; if (d != null) o.d = d; if (r) o.t = Number(r); if (Object.keys(o).length) st.tt[s.id] = o; else delete st.tt[s.id]; }
      };
      b.querySelectorAll('[data-dir]').forEach(x => x.onclick = () => { keep(); st.dir = Number(x.dataset.dir); draw(); });
      b.querySelectorAll('[data-day]').forEach(x => x.onclick = () => { keep(); st.day = x.dataset.day === '1' ? (st.day || D.today) : null; draw(); });
      q('[data-op]').onchange = async e => {
        keep();
        if (e.target.value === 'new') {
          const nm = prompt(T('新しい運用の運用番号（例：A01）'), '');
          const r = nm && await api('mp_op_save', { p_id: null, p_num: nm, p_form: null, p_note: '', p_kind: D.kind, p_as: S.as });
          if (r) { ops.push({ id: r.id, num: nm.trim(), form: null, fname: null, n: 0 }); st.opv = 'o:' + r.id; }
        } else st.opv = e.target.value;
        draw();
      };
      b.querySelectorAll('[data-sk]').forEach(x => x.onclick = () => { keep(); const id = Number(x.dataset.sk); if (st.skip.has(id)) st.skip.delete(id); else st.skip.add(id); draw(); });
      if (q('[data-cadd]')) q('[data-cadd]').onclick = () => { keep(); st.cpl.push({ op: null, a: null, b: null }); draw(); };
      b.querySelectorAll('[data-cx]').forEach(x => x.onclick = () => { keep(); st.cpl.splice(Number(x.dataset.cx), 1); draw(); });
      if (q('[data-del]')) q('[data-del]').onclick = async () => { if (await api('mp_train_del', { p_ids: [t.id], p_as: S.as }, '消しました')) { m.close(); reload(); } };
      q('[data-ok]').onclick = async () => {
        keep(); if (!st.num.trim()) return toast('列車番号を入れてください');
        const pop = st.opv.startsWith('o:') ? Number(st.opv.slice(2)) : null, pf = st.opv.startsWith('f:') ? Number(st.opv.slice(2)) : null;
        const r = await api('mp_train_save', { p_id: t ? t.id : null, p_route: D.id, p_dir: st.dir, p_num: st.num, p_kind: st.kind, p_dep: st.dep, p_form: pf, p_tt: st.tt, p_skip: [...st.skip], p_as: S.as,
          p_op: pop, p_day: st.day || null, p_cpl: bus ? [] : st.cpl.filter(c => c.op).map(c => ({ op: c.op, a: c.a || null, b: c.b || null })) });
        if (r) { toast(r.warn || (r.cplx || []).some(c => !c.ok) ? '保存しました（注意があります）' : '保存しました'); m.close(); reload(); }
      };
    });
  };
  draw();
}
function trainBulk(D, reload) {
  const ops = D.ops || [];
  const m = modal(['まとめて列車をつくる', `
    <div class="mp-row"><span class="mp-seg"><button data-dir="1" class="on">下り</button><button data-dir="-1">上り</button></span>
      <select class="mp-inp" style="width:auto" data-kind>${kindOpts(D, '普通')}</select></div>
    <div class="mp-row"><label class="small">はじめの列車 <input class="mp-inp mp-num" data-from value="06:00"></label> <label class="small">さいごの列車 <input class="mp-inp mp-num" data-to value="23:00"></label> <label class="small">何分おき <input class="mp-inp mp-num" type="number" data-ev value="10" min="2" max="240"></label></div>
    <div class="mp-row"><input class="mp-inp" data-pre placeholder="列車番号の頭（例：A。なくてもよい）"></div>
    <div class="mp-row" style="align-items:center"><span>走る日</span><span class="mp-seg"><button data-day="0" class="on">毎日</button><button data-day="1">この日だけ（臨時）</button></span>
      <input class="mp-inp" style="width:auto" type="date" data-dt value="${esc(D.today)}" min="${esc(D.today)}" max="${esc(dayAdd(D.today, 60))}" hidden></div>
    ${ops.length ? `<div class="mp-row" style="align-items:center"><span>運用</span><select class="mp-inp" style="flex:1 1 160px" data-op><option value="">（運用なし。あとで「運用を自動で組む」）</option>${ops.map(o => `<option value="${o.id}">${o.fname ? `${esc(o.num)}（${esc(o.fname)}）` : esc(T(`${o.num}（編成なし）`))}</option>`).join('')}</select></div>` : ''}
    <div class="mp-row"><button class="btn main" data-ok>つくる</button></div>
    <p class="muted small">編成はあとで「運用を自動で組む」でわりあてられます。1つの運用に入れると、その運用の編成がぜんぶ走ります（間にあわない列車には注意が出ます）</p>`], b => {
    let dir = 1, day = false;
    b.querySelectorAll('[data-dir]').forEach(x => x.onclick = () => { dir = Number(x.dataset.dir); b.querySelectorAll('[data-dir]').forEach(y => y.classList.toggle('on', y === x)); });
    b.querySelectorAll('[data-day]').forEach(x => x.onclick = () => { day = x.dataset.day === '1'; b.querySelectorAll('[data-day]').forEach(y => y.classList.toggle('on', y === x)); b.querySelector('[data-dt]').hidden = !day; });
    b.querySelector('[data-ok]').onclick = async () => {
      const opv = b.querySelector('[data-op]') ? b.querySelector('[data-op]').value : '';
      const r = await api('mp_train_bulk', { p_route: D.id, p_dir: dir, p_from: parseHM(b.querySelector('[data-from]').value), p_to: parseHM(b.querySelector('[data-to]').value),
        p_every: Number(b.querySelector('[data-ev]').value), p_kind: b.querySelector('[data-kind]').value, p_prefix: b.querySelector('[data-pre]').value, p_form: null, p_as: S.as,
        p_op: opv ? Number(opv) : null, p_day: day ? (b.querySelector('[data-dt]').value || D.today) : null });
      if (r) { toast(T(`${r.n}本つくりました`)); m.close(); reload(); }
    };
  });
}
async function autoForm(D, reload) {
  const cl = await api('mp_cars_list', { p_as: S.as }); if (!cl) return;
  const forms = cl.forms.filter(f => f.perf && f.perf.rail === (D.kind === 'rail'));
  if (!forms.length) return toast('編成がありません（車両と編成で組んでください）');
  const pick = new Set(forms.filter(f => f.trains === 0 || D.trains.some(t => t.form === f.id)).map(f => f.id));
  const m = modal(['運用を自動で組む', `<p class="small">この系統の列車に、えらんだ編成をわりあてます（始発駅にいて、2分前にあいている編成）</p>
    <div class="mp-cars">${forms.map(f => `<span class="mp-car ${pick.has(f.id) ? 'on' : ''}" data-f="${f.id}">${esc(f.name)}<span class="n">${f.perf.n}両・列車${f.trains}本</span></span>`).join('')}</div>
    <div class="mp-row"><button class="btn main" data-ok>わりあてる</button></div>`], b => {
    b.querySelectorAll('[data-f]').forEach(x => x.onclick = () => { const id = Number(x.dataset.f); if (pick.has(id)) pick.delete(id); else pick.add(id); x.classList.toggle('on'); });
    b.querySelector('[data-ok]').onclick = async () => {
      const r = await api('mp_train_autoform', { p_route: D.id, p_forms: [...pick], p_as: S.as });
      if (r) { toast(T(`${r.ok}本にわりあてました（${r.used}編成）`) + (r.none ? SEP() + T(`・${r.none}本は編成が足りません`) : '')); m.close(); reload(); }
    };
  });
}

/* ---- 運用：運用番号・編成・列車の数。運用ファイル（JSON）の書き出し・読みこみ ---- */
function saveJson(name, obj) {
  const blob = new Blob([JSON.stringify(obj, null, 1)], { type: 'application/json' });
  const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = name; document.body.appendChild(a); a.click();
  setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
}
const ymd = () => new Date().toLocaleDateString('sv-SE', { timeZone: 'Asia/Tokyo' });
async function openOps() {
  const m = modal(['運用', '<p class="muted small">読みこんでいます…</p>'], null, 'mp-wide');
  let D = null, kind = 'rail';
  const load = async () => { D = await api('mp_ops_list', { p_as: S.as }); if (!D) return m.close(); draw(); };
  const exportOps = async (ids, name) => { const r = await api('mp_op_export', { p_ops: ids, p_as: S.as }); if (r) { saveJson(name, r); toast('書き出しました'); } };
  const draw = () => {
    const L = D.ops.filter(o => o.kind === kind), forms = D.forms.filter(f => f.perf && f.perf.rail === (kind === 'rail'));
    m.set('運用', `<p class="small" style="margin:0">${esc(asName())}</p>
      <div class="tabs-s" style="margin-top:6px">${[['rail', '鉄道'], ['bus', 'バス']].map(t => `<button data-kind="${t[0]}" class="${kind === t[0] ? 'on' : ''}">${t[1]}</button>`).join('')}</div>
      <div class="mp-list" style="margin-top:8px">${L.map(o => `<div class="mp-item">
          <b>${esc(o.num)}</b> <small class="muted"><span>列車 ${o.trains}本</span>${o.daily !== o.trains ? `<span>（臨時 ${o.trains - o.daily}本）</span>` : ''}${o.cpl ? `<span>・連結 ${o.cpl}本</span>` : ''}${o.first != null ? `<span>・${hms(o.first)}〜${hms(o.last)}</span>` : ''}${o.routes.length ? `<span>・</span><span>${o.routes.map(esc).join('・')}</span>` : ''}</small>
          ${o.bad ? `<small class="mp-warn">・<span>走れない列車 ${o.bad}本</span></small>` : ''}${o.note ? `<br><small>${esc(o.note)}</small>` : ''}
          <div class="mp-row small" style="align-items:center"><span>編成</span><select class="mp-inp" style="flex:1 1 140px" data-of="${o.id}"><option value="">（入れない）</option>${forms.map(f => `<option value="${f.id}" ${o.form === f.id ? 'selected' : ''} ${f.ok ? '' : 'disabled'}>${esc(T(f.op && f.op !== o.num ? (kind === 'bus' ? `${f.name}（${f.perf.n}台）・いまは運用 ${f.op}` : `${f.name}（${f.perf.n}両）・いまは運用 ${f.op}`) : kind === 'bus' ? `${f.name}（${f.perf.n}台）` : `${f.name}（${f.perf.n}両）`))}</option>`).join('')}</select>
            <button class="btn" data-oren="${o.id}">運用番号</button><button class="btn" data-oex="${o.id}">書き出す</button><button class="btn" data-odel="${o.id}">消す</button></div></div>`).join('')
        || '<p class="muted small">まだありません。「＋ 運用」でつくるか、系統の「運用を自動で組む」でつくれます</p>'}</div>
      <div class="mp-row"><button class="btn main" data-onew>＋ 運用</button><button class="btn" data-oall>ぜんぶ書き出す</button><button class="btn" data-oimp>ファイルを読みこむ</button>
        <input type="file" accept=".json,application/json" data-ofile hidden></div>
      <p class="muted small">列車は運用に入れ、運用に編成を入れます。編成を変えると、その運用の列車ぜんぶの編成が変わります（ほかの運用に入っていた編成は、そちらからはずれます）。運用ファイル（JSON）を読みこむと、ファイルにある運用の列車が、ファイルの列車に入れかわります${D.free ? `<span>（運用に入っていない列車 ${D.free}本）</span>` : ''}</p>`, b => {
      b.querySelectorAll('[data-kind]').forEach(x => x.onclick = () => { kind = x.dataset.kind; draw(); });
      b.querySelectorAll('[data-of]').forEach(x => x.onchange = async () => {
        const o = D.ops.find(y => y.id === Number(x.dataset.of)), fid = x.value ? Number(x.value) : null;
        const r = await api('mp_op_save', { p_id: o.id, p_num: o.num, p_form: fid, p_note: o.note, p_kind: o.kind, p_as: S.as });
        if (r) toast(T('編成を変えました') + (r.moved_from ? SEP() + T(`（運用 ${r.moved_from} からうつしました）`) : ''));
        load();
      });
      b.querySelectorAll('[data-oren]').forEach(x => x.onclick = async () => {
        const o = D.ops.find(y => y.id === Number(x.dataset.oren)); const nm = prompt(T('運用番号（例：A01）'), o.num); if (!nm) return;
        if (await api('mp_op_save', { p_id: o.id, p_num: nm, p_form: o.form, p_note: o.note, p_kind: o.kind, p_as: S.as }, '変えました')) load();
      });
      b.querySelectorAll('[data-oex]').forEach(x => x.onclick = () => { const o = D.ops.find(y => y.id === Number(x.dataset.oex)); return exportOps([o.id], `運用_${o.num}_${ymd()}.json`); });
      b.querySelectorAll('[data-odel]').forEach(x => x.onclick = async () => {
        const o = D.ops.find(y => y.id === Number(x.dataset.odel));
        if (confirm(T(`運用 ${o.num} を消しますか？（列車は消えずに、運用なし・編成なしになります）`)) && await api('mp_op_del', { p_id: o.id, p_as: S.as }, '消しました')) load();
      });
      b.querySelector('[data-onew]').onclick = async () => {
        const nm = prompt(T('新しい運用の運用番号（例：A01）'), ''); if (!nm) return;
        if (await api('mp_op_save', { p_id: null, p_num: nm, p_form: null, p_note: '', p_kind: kind, p_as: S.as }, '運用をつくりました')) load();
      };
      b.querySelector('[data-oall]').onclick = () => exportOps(null, `運用_ぜんぶ_${ymd()}.json`);
      const fi = b.querySelector('[data-ofile]');
      b.querySelector('[data-oimp]').onclick = () => fi.click();
      fi.onchange = async () => {
        const f = fi.files && fi.files[0]; fi.value = ''; if (!f) return;
        let data; try { data = JSON.parse(await f.text()); } catch (e) { return toast('JSON として読めません'); }
        const r = await api('mp_op_import', { p_data: data, p_as: S.as, p_dry: true }); if (!r) return;
        importPreview(r, data, load);
      };
    });
  };
  load();
}
// 運用ファイルの読みこみ：見つもり（変わる運用・列車の数・まちがい）を見せてから入れる
function importPreview(r, data, after) {
  const m = modal(['運用ファイルを読みこむ', `
    <div class="mp-list">${(r.ops || []).map(o => `<div class="mp-item small"><b>${o.num ? esc(o.num) : '<span>（運用なし）</span>'}</b>${o.new ? ' <small>（新しい運用）</small>' : ''}
      ：<span>今の列車 ${o.del}本 → ファイルの列車 ${o.add}本</span>${!('form' in o) ? '' : o.form != null ? `<span>・編成</span> <span>${esc(String(o.form))}</span>` : '<span>・編成なし</span>'}</div>`).join('')}</div>
    ${r.nerr ? `<p class="mp-warn"><span>まちがいが ${r.nerr}つあります（読みこめません）</span></p><div class="small">${(r.errors || []).map(e => `<div>・<span>${esc(e)}</span></div>`).join('')}</div>` : ''}
    ${(r.warns || []).length ? `<div class="small muted">${r.warns.map(e => `<div>・<span>${esc(e)}</span></div>`).join('')}</div>` : ''}
    <div class="mp-row"><button class="btn main" data-ok ${r.ok ? '' : 'disabled'}>読みこむ（${r.trains}本）</button></div>
    <p class="muted small">ファイルにある運用の列車は、ファイルの列車に入れかわります（あとで系統の「↶ 取り消す」でもどせます）</p>`], b => {
    b.querySelector('[data-ok]').onclick = async () => { const x = await api('mp_op_import', { p_data: data, p_as: S.as, p_dry: false }); if (x) { toast(T(`読みこみました（列車 ${x.trains}本）`)); m.close(); if (after) after(); } };
  });
}
/* ---- 編成の譲渡 ---- */
function giveForm(f, reload) {
  if (!f) return;
  const n = f.perf ? f.perf.n : 0;
  const m = modal(['編成をゆずる', `<p class="small" style="margin-bottom:2px"><b>${esc(f.name)}</b>（<span>${f.perf && !f.perf.rail ? `${n}台` : `${n}両`}</span>）</p>
    <p class="small" style="margin-top:0">ほかの人・会社にゆずります。相手が受けとったら移ります（受けとる側が車庫をえらびます）</p>
    <div class="mp-row"><input class="mp-inp" data-to inputmode="numeric" placeholder="相手の ID（人は5けた・会社は会社ID）"></div>
    <div class="mp-row">値段 <input class="mp-inp mp-num" style="width:140px" data-pr value="0"> X <small class="muted">（0 X でもよい）</small></div>
    <div class="mp-row"><input class="mp-inp" data-msg placeholder="ひとこと（なくてもよい）"></div>
    <div class="mp-row"><button class="btn main" data-ok>申しこむ</button></div>
    <p class="muted small">相手が受けとると、この編成は運用・列車からはずれます。車番は相手の続きの番号になります</p>`], b => {
    b.querySelector('[data-ok]').onclick = async () => {
      const to = b.querySelector('[data-to]').value.trim(), pr = Number(String(b.querySelector('[data-pr]').value).replace(/[,，\s]/g, ''));
      if (!to) return toast('相手の ID を入れてください'); if (!(pr >= 0)) return toast('数字を入れてください');
      const r = await api('mp_xfer_offer', { p_form: f.id, p_to: to, p_price: pr, p_msg: b.querySelector('[data-msg]').value, p_as: S.as });
      if (r) { toast(T(`${r.to}に申しこみました。受けとってもらうと移ります`)); m.close(); if (reload) reload(); }
    };
  });
}
const XST = { offer: '返事まち', done: '受けとりずみ', no: 'ことわり', cancel: '取り消し' };
async function openXfers() {
  const m = modal(['編成の譲渡', '<p class="muted small">読みこんでいます…</p>']);
  let D = null, tab = 'in', open = null, deps = [];
  const load = async () => { D = await api('mp_xfer_list', {}); if (!D) return m.close(); if (!D.in.length && D.out.length) tab = 'out'; draw(); };
  const item = (x, inc) => { const p = x.perf || {}; return `<div class="mp-item"><b>${esc(x.fname)}</b> <small><span>${p.rail === false ? `${p.n}台・${p.len}m・定員${fmt(p.cap || 0)}人` : `${p.n}両・${p.len}m・定員${fmt(p.cap || 0)}人・加速 ${p.acc}km/h/s・最高${p.vmax}km/h`}</span><span>・状態${p.cond}</span></small><br>
      <small><span>${esc(x.from)}</span> → <span>${esc(x.to)}</span>・<span>${X(x.price)}</span>・<b class="${x.st === 'no' ? 'mp-warn' : ''}">${esc(XST[x.st] || x.st)}</b></small>
      ${x.cars ? `<br><small class="muted">${x.cars.map(esc).join('・')}</small>` : ''}${x.msg ? `<br><small>ひとこと：<span>${esc(x.msg)}</span></small>` : ''}
      ${inc && x.st === 'offer' && open === x.id ? `<div class="mp-row small" style="align-items:center"><span>車庫</span><select class="mp-inp" style="flex:1 1 140px" data-xd>${deps.map(d => `<option value="${d.id}" ${d.n + (p.n || 0) > d.cap ? 'disabled' : ''}>${esc(d.name)}（${d.n}/${d.cap}）</option>`).join('') || '<option value="">（入れられる車庫がありません）</option>'}</select></div>
        <div class="mp-row"><input class="mp-inp" style="flex:1 1 120px" data-xn placeholder="新しい編成番号（なければ今のまま）"><button class="btn main" data-xgo="${x.id}" ${deps.length ? '' : 'disabled'}>受けとる（${X(x.price)}）</button></div>` : ''}
      ${x.st === 'offer' ? `<div class="mp-row">${inc ? (open !== x.id ? `<button class="btn main" data-xok="${x.id}">受けとる</button>` : '') + `<button class="btn" data-xno="${x.id}">ことわる</button>` : `<button class="btn" data-xno="${x.id}">取り消す</button>`}</div>` : ''}</div>`; };
  const draw = () => {
    const L = tab === 'in' ? D.in : D.out, nw = D.in.filter(x => x.st === 'offer').length;
    m.set('編成の譲渡', `<div class="tabs-s">${[['in', 'とどいた申しこみ'], ['out', '出した申しこみ']].map(t => `<button data-tab="${t[0]}" class="${tab === t[0] ? 'on' : ''}"><span>${t[1]}</span>${t[0] === 'in' && nw ? ` <b>${nw}</b>` : ''}</button>`).join('')}</div>
      <div class="mp-list" style="margin-top:8px">${L.map(x => item(x, tab === 'in')).join('') || '<p class="muted small">ありません</p>'}</div>
      <p class="muted small">${tab === 'in' ? '受けとるときに、車籍を置く車庫をえらびます（陸送で12時間）。車番は、受けとる側の続きの番号になります' : '編成をゆずるには、≡ →「車両と編成」の編成の「ゆずる」から'}</p>`, b => {
      b.querySelectorAll('[data-tab]').forEach(x => x.onclick = () => { tab = x.dataset.tab; open = null; draw(); });
      b.querySelectorAll('[data-xok]').forEach(x => x.onclick = async () => {
        const it = D.in.find(y => y.id === Number(x.dataset.xok));
        const cl = await api('mp_cars_list', { p_as: it.to_as }); if (!cl) return;
        deps = cl.depots.filter(d => (d.kind === 'rail') === (it.perf && it.perf.rail !== false)); open = it.id; draw();
      });
      b.querySelectorAll('[data-xgo]').forEach(x => x.onclick = async () => {
        const dep = Number(b.querySelector('[data-xd]').value); if (!dep) return toast('車庫をえらんでください');
        if (await api('mp_xfer_accept', { p_id: Number(x.dataset.xgo), p_depot: dep, p_name: b.querySelector('[data-xn]').value }, '受けとりました')) { open = null; load(); }
      });
      b.querySelectorAll('[data-xno]').forEach(x => x.onclick = async () => { if (confirm(T(tab === 'in' ? 'ことわりますか？' : '取り消しますか？')) && await api('mp_xfer_close', { p_id: Number(x.dataset.xno) }, tab === 'in' ? 'ことわりました' : '取り消しました')) load(); });
    });
  };
  load();
}

/* ---- 土地の申請：とどいた申請（自分と自分の会社の筆）・出した申請 ---- */
async function openLandReqs() {
  const m = modal(['土地の申請', '<p class="muted small">読みこんでいます…</p>']);
  let D = null, tab = 'in', open = null;
  const load = async () => { D = await api('mp_land_reqs', {}); if (!D) return m.close(); if (!D.in.some(r => r.st === 'wait') && D.out.length && tab === 'in' && !D.in.length) tab = 'out'; draw(); };
  const item = (r, inc) => `<div class="mp-item"><b translate="no">${esc(r.label)}</b> <small>${fmt(r.n * 100)}㎡</small><br>
      <small><span>${esc(r.who)}</span> → <span>${esc(r.owner)}</span>・<b class="${r.st === 'no' ? 'mp-warn' : ''}">${esc(LRS[r.st] || r.st)}</b>${r.st === 'ok' ? `<span>（1区画・1日 ${X(r.fee)}）</span>` : ''}${r.rent != null ? `<span>・貸出料 ${X(r.rent)}</span>` : ''}</small>
      ${r.msg ? `<br><small>ひとこと：<span>${esc(r.msg)}</span></small>` : ''}${r.reply ? `<br><small>返事：<span>${esc(r.reply)}</span></small>` : ''}
      ${inc && open === r.id ? `<div class="mp-row"><span class="small">使用料（1区画・1日）</span><input class="mp-inp mp-num" style="width:110px" data-fee value="${r.st === 'ok' ? r.fee : r.std}"> X <small class="muted">標準 ${X(r.std)}</small></div>
        <div class="mp-row"><input class="mp-inp" data-rp placeholder="返事のひとこと（なくてもよい）"><button class="btn main" data-okgo="${r.id}">許可する</button></div>` : ''}
      <div class="mp-row">${inc ? (open !== r.id ? `<button class="btn ${r.st === 'wait' ? 'main' : ''}" data-ok="${r.id}">${r.st === 'ok' ? '使用料を変える' : '許可する'}</button>` : '')
          + (r.st !== 'no' ? `<button class="btn" data-no="${r.id}">${r.st === 'ok' ? '許可をやめる' : 'ことわる'}</button>` : '')
        : `<button class="btn" data-del="${r.id}">${r.st === 'ok' ? '許可を返す' : '取り消す'}</button>`}<button class="btn" data-go="${r.x},${r.y}">地図で見る</button></div></div>`;
  const draw = () => {
    const L = tab === 'in' ? D.in : D.out, nw = D.in.filter(r => r.st === 'wait').length;
    m.set('土地の申請', `<div class="tabs-s">${[['in', 'とどいた申請'], ['out', '出した申請']].map(t => `<button data-tab="${t[0]}" class="${tab === t[0] ? 'on' : ''}"><span>${t[1]}</span>${t[0] === 'in' && nw ? ` <b>${nw}</b>` : ''}</button>`).join('')}</div>
      <div class="mp-list" style="margin-top:8px">${L.map(r => item(r, tab === 'in')).join('') || '<p class="muted small">ありません</p>'}</div>
      <p class="muted small">${tab === 'in' ? '許可すると、その人・会社は申請した筆を、線路・道路・駅・車庫に使えます（使用料は1区画・1日。毎時、あなたに入ります）。許可をやめても、もうつくってあるものはそのままです。筆をタップ →「貸出料」で、だれでも申請なしで使えるようにもできます'
        : '申請は、地図で線路などを見つもったとき（「持ち主に申請する」）や、他人の筆をタップ →「使う申請」でできます。許可を返しても、もうつくってあるものはそのままです'}</p>`, b => {
      b.querySelectorAll('[data-tab]').forEach(x => x.onclick = () => { tab = x.dataset.tab; open = null; draw(); });
      b.querySelectorAll('[data-ok]').forEach(x => x.onclick = () => { open = Number(x.dataset.ok); draw(); });
      b.querySelectorAll('[data-okgo]').forEach(x => x.onclick = async () => {
        const t = String(b.querySelector('[data-fee]').value || '').replace(/[,，\s]/g, ''), f = t === '' ? null : Number(t);
        if (f != null && !(f >= 0)) return toast('数字を入れてください');
        if (await api('mp_land_decide', { p_ids: [Number(x.dataset.okgo)], p_ok: true, p_fee: f, p_reply: b.querySelector('[data-rp]').value }, '許可しました')) { open = null; load(); }
      });
      b.querySelectorAll('[data-no]').forEach(x => x.onclick = async () => {
        const rp = prompt(T('返事のひとこと（なくてもよい）'), ''); if (rp == null) return;
        if (await api('mp_land_decide', { p_ids: [Number(x.dataset.no)], p_ok: false, p_fee: null, p_reply: rp }, 'ことわりました')) load();
      });
      b.querySelectorAll('[data-del]').forEach(x => x.onclick = async () => { if (confirm(T('この申請を取り消しますか？（つくってあるものは、そのままです）')) && await api('mp_land_req_del', { p_ids: [Number(x.dataset.del)] }, '取り消しました')) load(); });
      b.querySelectorAll('[data-go]').forEach(x => x.onclick = () => { const [cx, cy] = x.dataset.go.split(',').map(Number); m.close(); setCam((cx + 0.5) / 5, (cy + 0.5) / 5, Math.max(S.cam.z, 24)); showSpot(cx, cy); });
    });
  };
  load();
}

/* ---- お金の記録 ---- */
const LK = { fare: '運賃', rent: '家賃', sales: '売上', tenant: 'テナントの家賃（はらう）', lease: '使用料（はらう）', lease_in: '使用料（受けとり）', upkeep: '維持費', tax: '固定資産税', land: '土地', bld: '建物', car: '車両', rail: '線路の工事', road: '道路の工事', sta: '駅', dep: '車庫', owed: '未払い' };
async function openLedger() {
  const m = modal(['お金の記録', '<p class="muted small">読みこんでいます…</p>']);
  let rows = [], before = null, head = null;
  const more = async () => {
    const d = await api('mp_ledger_page', { p_as: S.as, p_before: before }); if (!d) return;
    if (!head) head = d; rows = rows.concat(d.rows); before = d.rows.length ? d.rows[d.rows.length - 1].id : before;
    const day = head.day || {}, a = head.assets;
    m.set('お金の記録', `<p class="small" style="margin:0">${esc(asName())}</p>
      <div class="mp-kv"><b>土地</b><span>${a.land}筆・${fmt(a.land_m2 || 0)}㎡（地価 ${X(a.land_val)}）${a.land_val0 != null && a.land_val0 !== a.land_val ? `<br><small>評価額 ${X(a.land_val0)}（税・家賃・使用料のもと）</small>` : ''}</span><b>線路</b><span>${a.rail_km} km</span><b>駅・バス停</b><span>${a.stations}</span><b>車両</b><span>${a.cars}両（台）</span>
        ${head.owed ? `<b>未払い</b><span class="mp-warn">${X(head.owed)}（運賃などから先に引かれます）</span>` : ''}</div>
      <h4 style="margin:10px 0 4px">この24時間</h4><div class="mp-kv">${Object.entries(day).map(([k, v]) => `<b>${esc(LK[k] || k)}</b><span style="color:${v >= 0 ? '#1a7f37' : '#c33'}">${v >= 0 ? '+' : ''}${fmt(v)} X</span>`).join('') || '<span class="muted small">なし</span>'}</div>
      <h4 style="margin:10px 0 4px">記録</h4><div class="mp-list">${rows.map(r => `<div class="mp-item"><small>${new Date(r.at).toLocaleString('ja-JP', { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' })}・${esc(LK[r.k] || r.k)}</small><br>
        ${esc(r.memo || '')} <b style="float:right;color:${r.amount >= 0 ? '#1a7f37' : '#c33'}">${r.amount >= 0 ? '+' : ''}${fmt(r.amount)} X</b></div>`).join('')}</div>
      ${d.rows.length === 50 ? '<button class="btn wide" data-more>もっと見る</button>' : ''}`, b => { const x = b.querySelector('[data-more]'); if (x) x.onclick = more; });
  };
  more();
}

/* ---- 管理 ---- */
const RATE_NAME = { land_P: '地価のもと：平地', land_F: '地価のもと：林', land_B: '地価のもと：砂浜', land_H: '地価のもと：丘', land_M: '地価のもと：山', land_K: '地価のもと：高い山',
  dens_k: '地価：人の多さの効き', road_mul: '地価：道路ぞい', sta_mul: '地価：駅の近く', sta_r: '駅の近く（マス）', lease: '使用料（他人の土地・1日・地価の）', lease_gov: '使用料（国の土地・1日・地価の）',
  prop_tax: '固定資産税（1日・地価の）', rail: '線路（1マス）', road: '道路（1マス・1車線）', dbl_mul: '複線の倍率', elec: '電化（1マス）', sta_base: '駅のもと', sta_m: '駅：ホーム1m・1番線',
  stop: 'バス停', dep_S: '車両基地 S', dep_M: '車両基地 M', dep_L: '車両基地 L', bdep_S: '営業所 S', bdep_M: '営業所 M', up_rail: '維持費：線路1マス・1日', up_road: '維持費：私道1マス・1日',
  up_sta: '維持費：駅・1日', up_stop: '維持費：バス停・1日', up_dep: '維持費：車両基地・1日', up_bdep: '維持費：営業所・1日', g_rail: '鉄道に乗る人（駅のまわりの人の・1日）', g_bus: 'バスに乗る人（同）',
  fare_base: '運賃：はじめ', fare_km: '運賃：1kmごと', bus_fare: 'バス運賃', bus_km: 'バス：3kmをこえて1kmごと', catch_rail: '駅のまわり（マス）', catch_bus: 'バス停のまわり（マス）',
  max_tiles: '一度にひける線（マス）', grow: 'まちの成長（1日）', grow_sta: '駅の近くのまちの成長（1日）', urb_k: 'まちの中の工事費の倍率', urb_sta: 'まちの中の駅の工事費の倍率' };
async function openAdmin() {
  const m = modal(['国土の管理', '<p class="muted small">読みこんでいます…</p>']);
  const st = await api('mp_admin_state', {}); const rates = await api('mp_admin_rates', { p_set: null }); if (!st || !rates) return;
  m.set('国土の管理', `<div class="mp-kv"><b>チャンク</b><span>${fmt(st.chunks)}</span><b>道路・線路</b><span>${fmt(st.segs)}（国 ${fmt(st.gov_segs)}・線路 ${fmt(st.rail_segs)}）</span><b>土地</b><span>${fmt(st.land)}筆</span><b>建物</b><span><span>${fmt(st.blds || 0)}棟</span>・<span>入居 ${fmt(st.occ || 0)}/${fmt(st.units || 0)}室</span></span>
      <b>駅</b><span>${fmt(st.stations)}</span><b>車両</b><span>${fmt(st.cars)}</span><b>系統・列車</b><span>${fmt(st.routes)}・${fmt(st.trains)}</span><b>時計</b><span>${st.last_tick ? new Date(st.last_tick).toLocaleString('ja-JP') : '—'}</span>
      <b>未払いの合計</b><span>${X(st.owed)}</span></div>
    <h4 style="margin:10px 0 4px">この24時間（ぜんぶ）</h4><div class="mp-kv">${Object.entries(st.day || {}).map(([k, v]) => `<b>${esc(LK[k] || k)}</b><span>${fmt(v)} X</span>`).join('')}</div>
    <h4 style="margin:10px 0 4px">名前・町字</h4><div class="mp-row"><button class="btn" data-names>地図で名前・町字をなおす</button></div>
    <h4 style="margin:10px 0 4px">用途地域をぬる</h4><div class="mp-row"><select class="mp-inp" style="width:auto" data-z>${Object.entries(PAL.ZN).map(([k, v]) => `<option value="${k}">${v}</option>`).join('')}<option value="-">なし</option><option value="">もとにもどす</option></select>
      <button class="btn" data-paint>地図でぬる</button></div>
    <h4 style="margin:10px 0 4px">値段・設定</h4>
    <div class="mp-kv">${Object.keys(rates).map(k => `<b>${esc(RATE_NAME[k] || k)}</b><span><input class="mp-inp" style="width:140px" data-rate="${k}" value="${rates[k]}"></span>`).join('')}</div>
    <div class="mp-row"><button class="btn main" data-save>設定を保存</button></div>`, b => {
    b.querySelector('[data-save]').onclick = async () => {
      const set = {}; b.querySelectorAll('[data-rate]').forEach(i => { const v = Number(i.value); if (Number.isFinite(v) && String(v) !== String(rates[i.dataset.rate])) set[i.dataset.rate] = v; });
      if (!Object.keys(set).length) return toast('変わったところがありません');
      if (await api('mp_admin_rates', { p_set: set }, '保存しました')) m.close();
    };
    b.querySelector('[data-paint]').onclick = () => { const z = b.querySelector('[data-z]').value; m.close(); zonePaint(z || null); };
    b.querySelector('[data-names]').onclick = () => { m.close(); namesTool(); };
  });
}
// マスの四角をえらぶ（管理：用途地域・町字の分割）。2か所タップ → onPick([x0, y0, x1, y1])
function tileRect(msg, onPick) {
  setTool('look');
  const st = S.toolState = { a: null, b: null };
  hint(msg);
  S.drawTool = (g, z) => {
    if (!st.a) return;
    const b = st.b || st.a, x0 = Math.min(st.a[0], b[0]), y0 = Math.min(st.a[1], b[1]), x1 = Math.max(st.a[0], b[0]) + 1, y1 = Math.max(st.a[1], b[1]) + 1;
    g.fillStyle = 'rgba(160,40,200,.16)'; g.fillRect(sx(x0), sy(y0), (x1 - x0) * z, (y1 - y0) * z);
    g.strokeStyle = '#8a2fb8'; g.lineWidth = 2; g.setLineDash([6, 4]); g.strokeRect(sx(x0), sy(y0), (x1 - x0) * z, (y1 - y0) * z); g.setLineDash([]);
  };
  S.tapHook = (x, y) => {
    const t = [Math.floor(x), Math.floor(y)];
    if (!st.a || st.b) { st.a = t; st.b = null; } else { st.b = t; onPick([Math.min(st.a[0], st.b[0]), Math.min(st.a[1], st.b[1]), Math.max(st.a[0], st.b[0]), Math.max(st.a[1], st.b[1])], st.a); }
    S.dirty = true;
  };
  S.toolEnd = () => { S.tapHook = null; S.toolState = null; S.drawTool = null; };
  S.dirty = true;
}
const rectTiles = (r, first) => { const out = first ? [first[0], first[1]] : []; for (let y = r[1]; y <= r[3]; y++) for (let x = r[0]; x <= r[2]; x++) if (!first || x !== first[0] || y !== first[1]) out.push(x, y); return out; };
function zonePaint(z) {
  tileRect(`用途地域（${z ? PAL.ZN[z] || 'なし' : 'もとにもどす'}）：2か所タップして四角くえらびます`, r => {
    const tiles = rectTiles(r); if (tiles.length / 2 > 2000) return sheet('<p class="mp-warn">2000マスまでです</p>');
    sheet(`<h4>${z ? `${tiles.length / 2}マスを「${PAL.ZN[z] || 'なし'}」に` : `${tiles.length / 2}マスを、もとの用途地域に`}</h4><div class="mp-row"><button class="btn main" data-ok>ぬる</button></div>`, s => {
      s.querySelector('[data-ok]').onclick = async () => {
        if (await api('mp_admin_zone', { p_tiles: tiles, p_z: z }, 'ぬりました')) {
          for (let cy = Math.floor(r[1] / CS); cy <= Math.floor(r[3] / CS); cy++) for (let cx = Math.floor(r[0] / CS); cx <= Math.floor(r[2] / CS); cx++) S.chunks.delete(ckey(cx, cy));
          S.dirty = true; sheet(null);
        }
      };
    });
  });
}
// 管理：名前・町字（地図をタップ → 県・郡・市区町村・区・町・丁目／大字・字。名前を変える・町字を分ける・合併する）
function namesTool() {
  setTool('look');
  hint('名前・町字：地図をタップすると、その場所の名前が出ます');
  const show = async (tx, ty) => {
    S.sel = { kind: 'cell', x: tx * 5 + 2, y: ty * 5 + 2 }; S.dirty = true;
    const d = await api('mp_admin_place_at', { p_x: tx, p_y: ty }); if (!d) return;
    const subName = d.sub ? (d.sub.kind === 'aza' ? '字' : '丁目') : null, choName = d.cho ? (d.cho.kind === 'oaza' ? '大字' : '町') : null;
    const rows = [[(d.pref && d.pref.type) || '県', d.pref, 'place', (d.pref && d.pref.type) || '県'], ['郡', d.gun, 'gun', '郡'], ['市区町村', d.muni, 'place', d.muni && d.muni.type], ['区', d.ward, 'place', '区'],
                  [choName || '町', d.cho, 'cho', ''], [subName || '丁目', d.sub, 'cho', '']].filter(r => r[1]);
    sheet(`<h4>${esc(d.text || '')}</h4><div class="mp-kv">${rows.map((r, i) => `<b>${esc(r[0])}</b><span><b>${esc(r[1].name + (r[0] === '郡' ? '郡' : r[3] || ''))}</b>
        ${r[1].gen ? `<small class="muted">（もとは ${esc(r[1].gen)}）</small>` : ''} <button class="btn" style="padding:2px 8px" data-ren="${i}">名前を変える</button></span>`).join('')}</div>
      ${d.cho ? `<div class="mp-row"><button class="btn" data-split>この${esc(subName || choName)}を分ける</button>
        ${d.sub ? `<button class="btn" data-merge="sub">${esc(subName)}をとなりと合併</button>` : ''}<button class="btn" data-merge="cho">${esc(choName)}をとなりと合併</button></div>` : ''}`, s => {
      s.querySelectorAll('[data-ren]').forEach(b => b.onclick = async () => {
        const r = rows[Number(b.dataset.ren)];
        const nm = prompt(T('新しい名前（「県」「市」「区」「郡」などはつけない）'), r[1].name); if (!nm) return;
        if (await api('mp_admin_rename', { p_kind: r[2], p_id: r[1].id, p_name: nm }, '名前を変えました')) { for (const c of S.cells.values()) c.stale = true; show(tx, ty); }
      });
      const sp = s.querySelector('[data-split]'); if (sp) sp.onclick = () => {
        tileRect(`分ける：新しい町字にするマスを、2か所タップして四角くえらびます（${d.sub ? d.sub.name : d.cho.name}のところだけ）`, async r => {
          const tiles = rectTiles(r, [tx, ty]);
          const nm = prompt(T('新しい町字の名前（丁目なら空でもよい）'), ''); if (nm == null) return;
          const x = await api('mp_admin_cho_split', { p_tiles: tiles, p_name: nm });
          if (x) { toast(T(`「${x.name}」をつくりました（${x.tiles}マス・筆 ${x.parcels}）`)); dropCho(r); namesTool(); }
        });
      };
      s.querySelectorAll('[data-merge]').forEach(b => b.onclick = () => {
        const lv = b.dataset.merge, from = lv === 'sub' ? d.sub : d.cho;
        hint('合併：入れる先の町字のマスをタップしてください');
        S.tapHook = async (x2, y2) => {
          const e = await api('mp_admin_place_at', { p_x: Math.floor(x2), p_y: Math.floor(y2) }); if (!e) return;
          const into = lv === 'sub' ? e.sub : e.cho;
          if (!into || into.id === from.id) return toast('ちがう町字をタップしてください');
          if (!confirm(T(`「${from.name}」を「${into.name}」に合併します。よろしいですか？`))) return;
          const x = await api('mp_admin_cho_merge', { p_from: from.id, p_into: into.id });
          if (x) { toast(T(`合併しました（筆 ${x.parcels}）`)); dropCho([Math.min(tx, Math.floor(x2)) - 64, Math.min(ty, Math.floor(y2)) - 64, Math.max(tx, Math.floor(x2)) + 64, Math.max(ty, Math.floor(y2)) + 64]); namesTool(); }
        };
      });
    });
  };
  S.tapHook = (x, y) => show(Math.floor(x), Math.floor(y));
  S.toolEnd = () => { S.tapHook = null; };
}
// 町字のデータを読みなおす（まわりのチャンク）
function dropCho(r) {
  for (let cy = Math.floor(r[1] / CS) - 1; cy <= Math.floor(r[3] / CS) + 1; cy++) for (let cx = Math.floor(r[0] / CS) - 1; cx <= Math.floor(r[2] / CS) + 1; cx++) { S.cho.delete(ckey(cx, cy)); const n = S.chunks.get(ckey(cx, cy)); if (n) n.bnd = null; }
  for (const c of S.cells.values()) c.stale = true;
  S.dirty = true;
}

/* ---------- ひらく・とじる ---------- */
async function open(root) {
  if (S.open && S.root === root && S.wrap && root.contains(S.wrap)) { resume(); return; }
  S.root = root;
  root.innerHTML = '<p class="muted small">国土を読みこんでいます…</p>';
  try { S.boot = await call('mp_boot', {}); } catch (e) { root.innerHTML = `<p class="small">${esc(e.message)}</p>`; return; }
  S.admin = !!S.boot.admin;
  if (!S.ov) {
    try {
      const inf = await (await fetch('map/overview.json', { cache: 'no-cache' })).json();
      const img = new Image(); img.onload = () => { S.ov = img; S.ovInfo = inf; S.dirty = true; }; img.src = 'map/overview.png?v=' + (inf.v || '1');
    } catch (e) { console.warn('overview', e); }
  }
  loadCam();
  build(root);
  if (!localStorage.getItem('mp_cam')) setCam(0, 0, 4);
  S.open = true; S.dirty = true;
  requestAnimationFrame(frame);
  clearInterval(S.pollT); S.pollT = setInterval(poll, 15000);
}
function resume() { if (!S.wrap) return; S.open = true; S.dirty = true; resize(); requestAnimationFrame(frame); clearInterval(S.pollT); S.pollT = setInterval(poll, 15000); }
function pause() { if (!S.open) return; S.open = false; clearInterval(S.pollT); if (S.wrap) S.wrap.classList.remove('mp-full'); }

/* ---------- 建物（t50）：プリセット・形・階数・部屋（入居募集・テナント募集・自分で使う） ---------- */
// 色：[屋根, 南の壁, 東の壁]
const BK = {
  house: ['#c47b4e', '#efe6da', '#d6c8b6'], apart: ['#9aa7b3', '#efe9e1', '#d3cbc0'], mansion: ['#d9d4cc', '#f4f1ec', '#d2cbc0'],
  tower: ['#cfd6de', '#e8edf2', '#b8c3ce'], shop: ['#e6a06e', '#f3e6d6', '#d9c6ae'], zakkyo: ['#c9b8a6', '#eee6dc', '#cdbfae'],
  office: ['#aebdd0', '#e1e8f0', '#a7b6c7'], sky: ['#9fb3cc', '#d3dfeb', '#8ea4bc'], mall: ['#e8d2b0', '#f6ecdc', '#dcc9aa'],
  factory: ['#b8b8b0', '#e4e4dc', '#c4c4ba'], warehouse: ['#c2b59b', '#ece4d2', '#cfc2a6'], port: ['#9ab3c0', '#dde8ee', '#a9bcc6'],
  farm: ['#a9cf73'], parking: ['#bdbdbd'], pkbld: ['#b0b0b0', '#e2e2e2', '#c2c2c2'],
  cityhall: ['#c9b48c', '#f1e8d6', '#d8c6a3'], plaza: ['#e6dfcf']   // 国の建物（t54g）：市役所・広場
};
const USE_NAME = { home: '住居', shop: '店舗', office: '事務所', factory: '工場', warehouse: '倉庫', port: '港湾', farm: '田畑', parking: '駐車場', plaza: '広場' };
const SHAPE_NAME = { full: 'ぜんぶ', slab: '板状', tower: '塔状', L: 'L字', ko: 'コの字', ro: 'ロの字' };
const MODE_NAME = { npc: '入居募集', corp: 'テナント募集', self: '自分で使う' };
const kindName = k => { const p = (S.boot.bld || []).find(b => b.k === k); return p ? p.n : k; };
// 高さで屋根をずらす（北西へ。見下ろしている感じ）
const bldShift = f => { const h = Math.max(0, f) * 3.5; return [-h * 0.25 / 50, -h * 0.45 / 50]; };
// 建物：[id, 筆, 種類, 階, 区画 [X0, Y0, …], 名前, 入っている%, 1 他人・2 自分]
function prepBld(a) {
  const b = { id: a[0], parcel: a[1], kind: a[2], floors: a[3], name: a[5] || '', occ: a[6], own: a[7], set: new Set() };
  const c = a[4] || [];
  for (let i = 0; i + 1 < c.length; i += 2) b.set.add(c[i] + ',' + c[i + 1]);
  const [dx, dy] = bldShift(b.floors); b.dx = dx; b.dy = dy;
  const base = new Path2D(), baseEdge = new Path2D(), roof = new Path2D(), edge = new Path2D(), wallS = new Path2D(), wallE = new Path2D();
  let n = 0, mx = 0, my = 0, x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const k of b.set) {
    const [x, y] = k.split(',').map(Number); n++; mx += x; my += y;
    x0 = Math.min(x0, x); y0 = Math.min(y0, y); x1 = Math.max(x1, x); y1 = Math.max(y1, y);
    const X0 = x / 5, Y0 = y / 5, X1 = (x + 1) / 5, Y1 = (y + 1) / 5;
    base.rect(X0, Y0, 0.2, 0.2); roof.rect(X0 + dx, Y0 + dy, 0.2, 0.2);
    const W = !b.set.has((x - 1) + ',' + y), E = !b.set.has((x + 1) + ',' + y), N = !b.set.has(x + ',' + (y - 1)), Sd = !b.set.has(x + ',' + (y + 1));
    if (Sd) { wallS.moveTo(X0, Y1); wallS.lineTo(X1, Y1); wallS.lineTo(X1 + dx, Y1 + dy); wallS.lineTo(X0 + dx, Y1 + dy); wallS.closePath(); }
    if (E) { wallE.moveTo(X1, Y0); wallE.lineTo(X1, Y1); wallE.lineTo(X1 + dx, Y1 + dy); wallE.lineTo(X1 + dx, Y0 + dy); wallE.closePath(); }
    for (const [on, ax, ay, bx, by] of [[W, X0, Y0, X0, Y1], [E, X1, Y0, X1, Y1], [N, X0, Y0, X1, Y0], [Sd, X0, Y1, X1, Y1]]) {
      if (!on) continue;
      baseEdge.moveTo(ax, ay); baseEdge.lineTo(bx, by);
      edge.moveTo(ax + dx, ay + dy); edge.lineTo(bx + dx, by + dy);
    }
  }
  Object.assign(b, { base, baseEdge, roof, edge, wallS, wallE, n });
  b.cx = (mx / Math.max(n, 1) + 0.5) / 5; b.cy = (my / Math.max(n, 1) + 0.5) / 5;
  b.lx = b.cx + dx; b.ly = b.cy + dy;
  b.bb = [Math.min(x0 / 5, x0 / 5 + dx), Math.min(y0 / 5, y0 / 5 + dy), (x1 + 1) / 5, (y1 + 1) / 5];
  return b;
}
function drawBlds(g, it, z, v) {
  const bs = [...it.blds.values()].filter(b => b.bb[2] >= v.x0 && b.bb[0] <= v.x1 && b.bb[3] >= v.y0 && b.bb[1] <= v.y1);
  if (!bs.length) return;
  bs.sort((a, b) => ((a.floors > 0) - (b.floors > 0)) || ((a.cy + a.cx * 0.3) - (b.cy + b.cx * 0.3)));   // 平らなもの（広場・駐車場・田畑）を先に。あとは北西から（手前のものをあとで）
  const walls = S.b25 && z >= 9, selP = S.sel && S.sel.kind === 'cell' ? S.sel.parcel : null;   // 2D のときは壁を描かない（上から見たまま）
  worldT(g);
  for (const b of bs) {
    const col = BK[b.kind] || ['#bbb', '#eee', '#ccc'];
    if (b.floors <= 0) {   // 田畑・駐車場（平ら）
      g.fillStyle = col[0]; g.fill(b.base);
      if (z >= 14) {
        g.save(); g.clip(b.base); g.strokeStyle = b.kind === 'farm' ? 'rgba(90,130,40,.55)' : b.kind === 'plaza' ? 'rgba(160,150,130,.45)' : 'rgba(255,255,255,.85)'; g.lineWidth = (b.kind === 'farm' ? 1 : 1.2) / z;
        g.beginPath(); const step = b.kind === 'farm' ? 0.04 : 0.05;
        for (let x = Math.floor(b.bb[0] / step) * step; x <= b.bb[2]; x += step) { g.moveTo(x, b.bb[1]); g.lineTo(x, b.bb[3]); }
        if (b.kind === 'plaza') for (let y = Math.floor(b.bb[1] / step) * step; y <= b.bb[3]; y += step) { g.moveTo(b.bb[0], y); g.lineTo(b.bb[2], y); }   // 広場：石だたみ
        g.stroke(); g.restore();
      }
      g.strokeStyle = b.own === 2 ? '#1f5bd6' : 'rgba(60,60,60,.55)'; g.lineWidth = (b.own === 2 ? 1.6 : 1) / z; g.stroke(b.baseEdge);
      if (b.kind === 'plaza' && z >= 9) { g.fillStyle = 'rgba(110,170,90,.55)'; for (const k of b.set) { const [x, y] = k.split(',').map(Number); if ((x * 7 + y * 13) % 9 === 0) { g.beginPath(); g.arc((x + 0.5) / 5, (y + 0.5) / 5, 0.045, 0, Math.PI * 2); g.fill(); } } }   // 広場の木
    } else if (walls) {
      g.fillStyle = col[1]; g.fill(b.wallS); g.fillStyle = col[2]; g.fill(b.wallE);
      g.strokeStyle = 'rgba(60,60,60,.35)'; g.lineWidth = 0.8 / z; g.stroke(b.wallS); g.stroke(b.wallE);
      g.fillStyle = col[0]; g.fill(b.roof);
      g.strokeStyle = b.own === 2 ? '#1f5bd6' : 'rgba(50,50,50,.6)'; g.lineWidth = (b.own === 2 ? 1.8 : 1) / z; g.stroke(b.edge);
    } else {
      g.fillStyle = col[0]; g.fill(b.base);
      g.strokeStyle = b.own === 2 ? '#1f5bd6' : 'rgba(50,50,50,.6)'; g.lineWidth = 1 / z; g.stroke(b.baseEdge);
    }
    if (selP && b.parcel === selP) { g.strokeStyle = '#d23'; g.lineWidth = 3 / z; g.stroke(walls && b.floors > 0 ? b.edge : b.baseEdge); }
  }
  screenT(g);
  if (z >= 24) for (const b of bs.slice().reverse()) {
    if (!b.name && b.floors <= 0) continue;
    const t = (b.name || '') + (b.floors > 0 ? (b.name ? ' ' : '') + b.floors + 'F' : '');
    label(g, t, sx(walls ? b.lx : b.cx), sy(walls ? b.ly : b.cy), { size: b.kind === 'cityhall' ? 12 : 10, color: b.own === 2 ? '#123c8c' : b.own === 3 ? '#5a3d0c' : '#333', bg: 'rgba(255,255,255,.82)' });
  }
}
// タップしたところの建物（屋根を押しても）
function hitBld(x, y) {
  if (!S.vis || !S.vis.blds) return null;
  const bs = [...S.vis.blds.values()].sort((a, b) => (b.cy + b.cx * 0.3) - (a.cy + a.cx * 0.3));
  for (const b of bs) {
    const g0 = Math.floor(x * 5) + ',' + Math.floor(y * 5);
    if (b.set.has(g0)) return { b, cell: g0 };
    if (b.floors > 0 && S.b25 && S.cam.z >= 9) { const k = Math.floor((x - b.dx) * 5) + ',' + Math.floor((y - b.dy) * 5); if (b.set.has(k)) return { b, cell: k }; }
  }
  return null;
}
// 区画をしらべたときの建物の行
function bldRow(B, mine) {
  return `<b>建物</b><span><span>${esc(B.name || kindName(B.kind))}</span><small>（<span>${esc(kindName(B.kind))}</span>${B.floors > 0 ? `・<span>${B.floors}階</span>` : ''}${B.n ? `・<span>入居 ${B.occ}/${B.n}</span>` : ''}）</small>${mine ? `<br><small>家賃 1日 ${X(B.rent)}</small>` : ''}</span>`;
}

/* ---- 建てる：プリセットをえらぶ ---- */
async function bldStart(P) {
  const m = modal(['建物を建てる', '<p class="muted small">読みこんでいます…</p>']);
  const ops = await api('mp_bld_options', { p_parcel: P.id, p_as: S.as }); if (!ops) return m.close();
  const pr = k => S.boot.bld.find(b => b.k === k) || {};
  m.set('建物を建てる', `<p class="small" style="margin:0 0 6px"><span>${esc(P.ban)}</span>・<span>${fmt(P.n * 100)}㎡</span></p>
    <div class="mp-list">${ops.map(o => { const p = pr(o.k); return `<button class="mp-item" style="text-align:left${o.ok ? '' : ';opacity:.55'}" data-k="${o.k}" ${o.ok ? '' : 'disabled'}>
      <b>${esc(p.n || o.k)}</b> ${o.ok ? `<span class="mp-cost">${X(o.cost)}</span>` : ''}
      <small><br>${o.ok ? `<span>${p.f1 > 0 ? `${p.f0}〜${o.f1}階` : '平ら'}</span>・<span>部屋 ${fmt(o.units)}</span>・<span>家賃の目安 1日 ${X(o.rent_day)}</span>` : `<span>${esc(o.why || '')}</span>`}</small></button>`; }).join('')}</div>
    <p class="muted small">工事費は床1㎡ごと。家賃の目安は満室・相場のとき。用途地域の建ぺい率・容積率で、建てられる広さと高さが決まります</p>`, b => {
    b.querySelectorAll('[data-k]').forEach(x => x.onclick = () => { m.close(); bldDesign(P, pr(x.dataset.k), ops.find(o => o.k === x.dataset.k)); });
  });
}
/* ---- 建てる：形・階数・名前 ---- */
async function bldDesign(P, pr, o) {
  const st = { shape: o.shape || pr.sh[0], floors: o.f1 || pr.f0, opt: '', name: '' };
  const m = modal([pr.n, '']);
  const flat = pr.f1 === 0;
  m.set(pr.n, `<canvas class="mp-bprev" width="300" height="200" style="width:100%;max-width:300px;height:auto;display:block;margin:0 auto 6px;border:1px solid var(--line,#ddd);border-radius:10px;background:#eef0ea"></canvas>
    ${flat ? '' : `<div class="mp-row" data-shapes>${pr.sh.map(s => `<button class="btn" data-sh="${s}">${SHAPE_NAME[s] || s}</button>`).join('')}</div>
      <div class="mp-row"><b style="white-space:nowrap">階数</b><input type="range" class="mp-fl" style="flex:1" min="${pr.f0}" max="${pr.f1}" value="${st.floors}"><b class="mp-fln" style="min-width:3.5em;text-align:right"></b></div>`}
    ${(pr.opt || []).includes('shop1') ? `<label class="mp-row small" style="gap:6px"><input type="checkbox" class="mp-opt"> <span>1階を店舗にする</span></label>` : ''}
    <div class="mp-row"><input class="mp-inp" maxlength="30" placeholder="名前（空ならおまかせ）"></div>
    <div class="mp-kv" data-q></div>
    <div class="mp-row"><button class="btn" data-est>見つもる</button><button class="btn main" data-go disabled>建てる</button></div>`, b => {
    const cv = b.querySelector('.mp-bprev'), fl = b.querySelector('.mp-fl'), fln = b.querySelector('.mp-fln'), qv = b.querySelector('[data-q]'), go = b.querySelector('[data-go]'), es = b.querySelector('[data-est]');
    let seq = 0, last = null, tmr = 0;
    const draw = q => {
      const g = cv.getContext('2d'), W = cv.width, H = cv.height; g.clearRect(0, 0, W, H);
      const cells = [...(S.vis && S.vis.parcels.get(P.id) ? S.vis.parcels.get(P.id).cells : [])].map(k => k.split(',').map(Number));
      if (!cells.length) return;
      const xs = cells.map(c => c[0]), ys = cells.map(c => c[1]);
      const x0 = Math.min(...xs), y0 = Math.min(...ys), x1 = Math.max(...xs) + 1, y1 = Math.max(...ys) + 1;
      const sc = Math.min((W - 30) / (x1 - x0), (H - 30) / (y1 - y0)), ox = (W - (x1 - x0) * sc) / 2, oy = (H - (y1 - y0) * sc) / 2;
      g.fillStyle = 'rgba(40,110,220,.18)'; g.strokeStyle = 'rgba(30,80,170,.5)'; g.lineWidth = 1;
      for (const [x, y] of cells) { g.fillRect(ox + (x - x0) * sc, oy + (y - y0) * sc, sc, sc); g.strokeRect(ox + (x - x0) * sc + 0.5, oy + (y - y0) * sc + 0.5, sc - 1, sc - 1); }
      if (q && q.cells) {
        g.fillStyle = flat ? '#7a9a4a' : '#3f5f8f';
        for (let i = 0; i + 1 < q.cells.length; i += 2) { const x = q.cells[i], y = q.cells[i + 1]; g.fillRect(ox + (x - x0) * sc + 1, oy + (y - y0) * sc + 1, sc - 2, sc - 2); }
        g.fillStyle = '#fff'; g.font = 'bold 12px system-ui, sans-serif'; g.textAlign = 'center'; g.textBaseline = 'middle';
        if (q.floors > 0) g.fillText(T(`${q.floors}階`), W / 2, H - 9 > oy + (y1 - y0) * sc ? H - 9 : 10);
      }
    };
    // 見つもりは「見つもる」を押してから。形・階数を変えたら、やりなおし
    const changed = () => { ++seq; last = null; go.disabled = true; qv.innerHTML = '<b>見つもり</b><span class="muted small">「見つもる」を押すと、工事費と部屋が出ます</span>'; draw(null); };
    const quote = async () => {
      const my = ++seq; go.disabled = true; qv.innerHTML = '<b>見つもり</b><span class="muted small">見つもり中…</span>';
      const q = await api('mp_bld_quote', { p_parcel: P.id, p_kind: pr.k, p_shape: st.shape, p_floors: st.floors, p_opt: st.opt, p_as: S.as });
      if (my !== seq) return;
      last = q; draw(q);
      if (!q) { qv.innerHTML = '<b>見つもり</b><span class="mp-warn">建てられません</span>'; return; }
      if (fl) { fl.min = q.f0; fl.max = q.f1; if (Number(fl.value) !== q.floors) fl.value = q.floors; st.floors = q.floors; }
      if (fln) fln.textContent = T(`${q.floors}階`);
      const uses = Object.entries(q.uses || {}).map(([u, n]) => `<span>${USE_NAME[u] || u}</span> <span>${n}</span>`).join('・');
      qv.innerHTML = `<b>延床面積</b><span>${fmt(q.total_m2)}㎡${q.floors > 0 ? `<small>（1階 ${fmt(q.fm2)}㎡）</small>` : ''}</span>
        <b>部屋</b><span><span>${fmt(q.units)}</span>${uses ? `<small>（${uses}）</small>` : ''}</span>
        <b>工事費</b><span class="mp-cost">${X(q.cost)}</span>
        <b>家賃の目安</b><span>1日 ${X(q.rent_day)}<small>（満室・相場）</small></span>`;
      go.disabled = false;
    };
    const sync = () => { b.querySelectorAll('[data-sh]').forEach(x => x.classList.toggle('main', x.dataset.sh === st.shape)); };
    b.querySelectorAll('[data-sh]').forEach(x => x.onclick = () => { st.shape = x.dataset.sh; st.floors = 999; sync(); changed(); });
    if (fl) fl.oninput = () => { st.floors = Number(fl.value); if (fln) fln.textContent = T(`${st.floors}階`); changed(); };
    const op = b.querySelector('.mp-opt'); if (op) op.onchange = () => { st.opt = op.checked ? 'shop1' : ''; changed(); };
    es.onclick = () => quote();
    b.querySelector('.mp-inp').oninput = e => { st.name = e.target.value; };
    go.onclick = async () => {
      if (!last) return;
      const msg = last.floors > 0 ? T(`${pr.n}（${last.floors}階・${fmt(last.total_m2)}㎡）を建てます（${fmt(last.cost)} X）。よろしいですか？`)
        : T(`${pr.n}（${fmt(last.total_m2)}㎡）を建てます（${fmt(last.cost)} X）。よろしいですか？`);
      if (!confirm(msg)) return;
      go.disabled = true;
      const r = await api('mp_bld_build', { p_parcel: P.id, p_kind: pr.k, p_shape: st.shape, p_floors: st.floors, p_opt: st.opt, p_name: st.name, p_as: S.as }, '建てました');
      go.disabled = false;
      if (r) { m.close(); refreshP(P); sheet(null); openBld(r.id); }
    };
    sync(); changed(); if (fln) fln.textContent = T(`${st.floors}階`);
  });
}

/* ---- 建物を見る：部屋・テナント・家賃の水準 ---- */
async function openBld(bid) {
  const m = modal(['建物', '<p class="muted small">読みこんでいます…</p>'], null, 'mp-wide');
  const sel = new Set();
  const load = async () => {
    const d = await api('mp_bld_get', { p_bld: bid }); if (!d) return m.close();
    const floors = [...new Set(d.units.map(u => u.f))];
    const stat = u => u.tk === 'corp' ? `<span>${esc(u.tn || '')}</span><small>（テナント）</small>` : u.tk === 'npc' ? `<span>${esc(u.tn || '')}</span>`
      : u.mode === 'self' ? '<span>自分で使う</span>' : u.mode === 'corp' ? `<span class="mp-warn">テナント募集中</span>` : '<span class="muted">空き</span>';
    const row = u => `<div class="mp-urow" data-u="${u.id}">
        ${d.mine ? `<input type="checkbox" data-c="${u.id}" ${sel.has(u.id) ? 'checked' : ''}>` : ''}
        <b>${esc(u.room)}</b><span><span>${USE_NAME[u.use] || u.use}</span>・<span>${fmt(u.m2)}㎡</span>${d.mine ? `・<small>${MODE_NAME[u.mode]}</small>` : ''}</span>
        <span class="st">${stat(u)}</span>
        <span class="rt">${u.tk ? `1日 ${X(u.rent)}` : u.mode === 'corp' ? `1日 ${X(u.ask)}` : ''}</span>
        ${d.mine && u.tk === 'corp' ? `<button class="btn" data-out="${u.id}">退去してもらう</button>` : ''}
        ${!d.mine && u.mode === 'corp' && !u.tk ? `<button class="btn main" data-lease="${u.id}">借りる</button>` : ''}
        ${!d.mine && u.tk === 'corp' && u.tmine ? `<button class="btn" data-leave="${u.id}">退去する</button>` : ''}</div>`;
    const dm = d.dem || {}, star = v => '★'.repeat(Math.max(1, Math.min(5, Math.round((v || 0) * 2.5))));
    const mainUses = [...new Set(d.units.map(u => u.use))];
    m.set(d.name || kindName(d.kind), `<div class="mp-kv">
        <b>種類</b><span><span>${esc(d.kname)}</span>${d.floors > 0 ? `・<span>${d.floors}階</span>・<span>${SHAPE_NAME[d.shape] || d.shape}</span>` : ''}</span>
        <b>住所</b><span translate="no">${esc(d.addr)}</span>
        <b>持ち主</b><span><span>${esc(d.owner)}</span>${d.mine ? '<small>（あなた）</small>' : ''}</span>
        <b>延床面積</b><span>${fmt(d.fm2 * Math.max(1, d.floors))}㎡</span>
        ${mainUses.length ? `<b>入りやすさ</b><span>${mainUses.map(u => `<span>${USE_NAME[u] || u}</span> <span style="color:#d89a00">${star(dm[u])}</span>`).join('・')}</span>` : ''}
        ${d.mine ? `<b>入居</b><span>${d.day.occ} / ${d.day.n}</span><b>家賃</b><span>1日 ${X(d.day.rent)}</span>
          <b>家賃の水準</b><span><input type="range" min="50" max="200" step="5" value="${Math.round(d.rent_lv * 100)}" class="mp-lv" style="width:55%;vertical-align:middle"> <b class="mp-lvn">${Math.round(d.rent_lv * 100)}%</b> <button class="btn" data-lvset style="padding:2px 8px">決める</button></span>` : ''}
      </div>
      ${d.gov ? `<p class="muted small" style="margin:2px 0 6px">国の建物です（税・家賃はありません）</p>` : ''}
      ${d.mine ? `<p class="muted small" style="margin:2px 0 6px">家賃の水準は入居募集の部屋の家賃（相場の何%か）。高いと入りにくく、出ていきやすくなります。店・事務所などを自分で使うか会社が借りると、売上が入ります</p>
        <div class="mp-row" data-bulk><small data-n>${sel.size}室えらんでいます</small>
          <button class="btn" data-all>ぜんぶえらぶ</button><button class="btn" data-none>えらばない</button></div>
        <div class="mp-row"><button class="btn" data-mode="npc">入居募集にする</button><button class="btn" data-mode="self">自分で使う</button>
          <button class="btn" data-mode="corp">テナント募集にする</button><input class="mp-inp mp-num" data-ask inputmode="numeric" placeholder="家賃/日" style="width:110px"></div>` : ''}
      <div data-units>${floors.map((f, i) => { const us = d.units.filter(u => u.f === f); return `<details ${i < 3 || floors.length <= 6 ? 'open' : ''} class="mp-floor">
        <summary><b>${f > 0 ? T(`${f}階`) : T('地上')}</b> <small><span>${us.length}室</span>・<span>入居 ${us.filter(u => u.tk || u.mode === 'self').length}</span></small></summary>
        ${us.map(row).join('')}</details>`; }).join('')}</div>
      ${d.mine ? `<div class="mp-row"><button class="btn" data-ren>名前を変える</button><button class="btn" data-del style="color:#c33">こわす</button></div>` : ''}`, b => {
      const nEl = b.querySelector('[data-n]');
      const upd = () => { if (nEl) nEl.textContent = T(`${sel.size}室えらんでいます`); };
      b.querySelectorAll('[data-c]').forEach(x => x.onchange = () => { const id = Number(x.dataset.c); if (x.checked) sel.add(id); else sel.delete(id); upd(); });
      const q = k => b.querySelector(k);
      if (q('[data-all]')) q('[data-all]').onclick = () => { d.units.forEach(u => sel.add(u.id)); b.querySelectorAll('[data-c]').forEach(x => x.checked = true); upd(); };
      if (q('[data-none]')) q('[data-none]').onclick = () => { sel.clear(); b.querySelectorAll('[data-c]').forEach(x => x.checked = false); upd(); };
      b.querySelectorAll('[data-mode]').forEach(x => x.onclick = async () => {
        if (!sel.size) return toast(T('部屋をえらんでください'));
        const mode = x.dataset.mode, ask = q('[data-ask]') && q('[data-ask]').value.replace(/[^\d]/g, '');
        if (await api('mp_unit_set', { p_units: [...sel], p_mode: mode, p_ask: mode === 'corp' && ask ? Number(ask) : null, p_as: S.as }, '変えました')) { sel.clear(); load(); }
      });
      const lv = q('.mp-lv'); if (lv) { lv.oninput = () => { q('.mp-lvn').textContent = lv.value + '%'; }; q('[data-lvset]').onclick = async () => { if (await api('mp_bld_set', { p_bld: bid, p_name: null, p_rent_lv: Number(lv.value) / 100, p_as: S.as }, '家賃の水準を変えました')) load(); }; }
      b.querySelectorAll('[data-out]').forEach(x => x.onclick = async () => { if (!confirm(T('テナントの会社に退去してもらいます。よろしいですか？'))) return; if (await api('mp_unit_leave', { p_unit: Number(x.dataset.out), p_as: S.as }, '退去してもらいました')) load(); });
      b.querySelectorAll('[data-lease]').forEach(x => x.onclick = () => leaseUnit(Number(x.dataset.lease), d.units.find(u => u.id === Number(x.dataset.lease)), load));
      b.querySelectorAll('[data-leave]').forEach(x => x.onclick = async () => { if (!confirm(T('この部屋から退去します。よろしいですか？'))) return; const u = d.units.find(z => z.id === Number(x.dataset.leave)); if (await api('mp_unit_leave', { p_unit: u.id, p_as: corpOf(u) }, '退去しました')) load(); });
      if (q('[data-ren]')) q('[data-ren]').onclick = async () => { const nm = prompt(T('建物の名前（30文字まで）'), d.name); if (nm == null) return; if (await api('mp_bld_set', { p_bld: bid, p_name: nm, p_rent_lv: null, p_as: S.as }, '名前を変えました')) { load(); refreshBld(d); } };
      if (q('[data-del]')) q('[data-del]').onclick = async () => {
        if (!confirm(T(`「${d.name || d.kname}」をこわします（工事費はもどりません。テナントの会社には知らせます）。よろしいですか？`))) return;
        if (await api('mp_bld_demolish', { p_bld: bid, p_as: S.as }, 'こわしました')) { m.close(); refreshBld(d); sheet(null); }
      };
    });
  };
  load();
}
function refreshBld(d) { const P = S.vis && S.vis.parcels.get(d.parcel); if (P) refreshP(P); else { for (const c of S.cells.values()) c.stale = true; S.dirty = true; } }
// 自分の会社のうち、この部屋を借りている会社（名義）
function corpOf(u) { const a = (S.boot.as || []).find(x => x.as !== 'me' && x.as !== 'gov' && x.name === u.tn); return a ? a.as : S.as; }
// 会社で借りる（名義が会社でなければ、えらぶ）
async function leaseUnit(id, u, after) {
  const corps = (S.boot.as || []).filter(a => a.as !== 'me' && a.as !== 'gov');
  if (!corps.length) return toast(T('テナントとして借りられるのは会社だけです（会社をつくると借りられます）'));
  let as = corps.some(a => a.as === S.as) ? S.as : null;
  if (!as) {
    if (corps.length === 1) as = corps[0].as;
    else {
      const k = prompt(T('借りる会社の番号：') + '\n' + corps.map((a, i) => `${i + 1}. ${asLabel(a)}`).join('\n'), '1'); if (k == null) return;
      const a = corps[Number(k) - 1]; if (!a) return toast(T('番号がちがいます')); as = a.as;
    }
  }
  const nm = asLabel(corps.find(a => a.as === as));
  if (!confirm(T(`${nm}が借ります（家賃 1日 ${fmt(u ? u.ask : 0)} X・1時間ごとに会社から払います）。よろしいですか？`))) return;
  if (await api('mp_unit_lease', { p_unit: id, p_as: as }, '借りました')) { if (after) after(); }
}

/* ---- テナント募集（会社で借りる）・借りている部屋 ---- */
async function openTenants() {
  const m = modal(['テナント募集', '<p class="muted small">読みこんでいます…</p>'], null, 'mp-wide');
  let use = '', tab = 'find';
  const v = view(), box = [Math.floor(v.x0) - 20, Math.floor(v.y0) - 20, Math.ceil(v.x1) + 20, Math.ceil(v.y1) + 20];
  const load = async () => {
    const corps = (S.boot.as || []).filter(a => a.as !== 'me' && a.as !== 'gov');
    const head = `<div class="mp-row"><div class="mp-seg"><button data-tab="find" class="${tab === 'find' ? 'on' : ''}">さがす</button><button data-tab="mine" class="${tab === 'mine' ? 'on' : ''}">借りている部屋</button></div></div>`;
    if (tab === 'find') {
      const near = await api('mp_unit_market', { p_box: box, p_use: use || null }) || [];
      const all = near.length ? near : await api('mp_unit_market', { p_box: null, p_use: use || null }) || [];
      m.set('テナント募集', `${head}
        <div class="mp-row"><select class="mp-inp" data-use style="width:auto">${['', 'shop', 'office', 'factory', 'warehouse', 'port', 'parking', 'farm'].map(u => `<option value="${u}" ${u === use ? 'selected' : ''}>${u ? USE_NAME[u] : T('ぜんぶの用途')}</option>`).join('')}</select>
          <small class="muted">${near.length ? T('いま見ているあたり') : T('ぜんぶの地域')}</small></div>
        ${corps.length ? '' : '<p class="mp-warn">テナントとして借りられるのは会社だけです</p>'}
        <div class="mp-list">${all.map(x => `<div class="mp-item"><b>${esc(x.bname || x.kname)}</b> <span>${esc(x.room)}</span>
            <small><br><span>${USE_NAME[x.use] || x.use}</span>・<span>${fmt(x.m2)}㎡</span>・<span>家賃 1日 ${X(x.ask)}</span><small>（相場の${Math.round(100 * x.ask / Math.max(1, x.mr))}%）</small>・<span>入りやすさ</span> <span style="color:#d89a00">${'★'.repeat(Math.max(1, Math.min(5, Math.round((x.dem || 0) * 2.5))))}</span>
            <br><span translate="no">${esc(x.addr || '')}</span>・<span>${esc(x.owner)}</span></small>
            <div class="mp-row"><button class="btn" data-go="${x.id}">地図で見る</button>${corps.length ? `<button class="btn main" data-lease="${x.id}">借りる</button>` : ''}</div></div>`).join('') || '<p class="muted small">いまテナント募集をしている部屋はありません</p>'}</div>`, b => bind(b, all));
    } else {
      const lists = await Promise.all(corps.map(a => api('mp_unit_mine', { p_as: a.as }).then(r => (r ? r.leases : []).map(l => ({ ...l, as: a.as, cn: asLabel(a) })))));
      const ls = lists.flat();
      m.set('テナント募集', `${head}<div class="mp-list">${ls.map(l => `<div class="mp-item"><b>${esc(l.bname)}</b> <span>${esc(l.room)}</span>
          <small><br><span>${esc(l.cn)}</span>・<span>${USE_NAME[l.use] || l.use}</span>・<span>${fmt(l.m2)}㎡</span>・<span>家賃 1日 ${X(l.rent)}</span>・<span>${esc(l.owner)}</span></small>
          <div class="mp-row"><button class="btn" data-go2="${l.x},${l.y}">地図で見る</button><button class="btn" data-out="${l.id}" data-as="${l.as}">退去する</button></div></div>`).join('') || '<p class="muted small">借りている部屋はありません</p>'}</div>`, b => {
        b.querySelectorAll('[data-tab]').forEach(x => x.onclick = () => { tab = x.dataset.tab; load(); });
        b.querySelectorAll('[data-go2]').forEach(x => x.onclick = () => { const [cx, cy] = x.dataset.go2.split(',').map(Number); m.close(); setCam((cx + 0.5) / 5, (cy + 0.5) / 5, Math.max(S.cam.z, 30)); });
        b.querySelectorAll('[data-out]').forEach(x => x.onclick = async () => { if (!confirm(T('この部屋から退去します。よろしいですか？'))) return; if (await api('mp_unit_leave', { p_unit: Number(x.dataset.out), p_as: x.dataset.as }, '退去しました')) load(); });
      });
    }
  };
  const bind = (b, all) => {
    b.querySelectorAll('[data-tab]').forEach(x => x.onclick = () => { tab = x.dataset.tab; load(); });
    const us = b.querySelector('[data-use]'); if (us) us.onchange = () => { use = us.value; load(); };
    b.querySelectorAll('[data-go]').forEach(x => x.onclick = () => { const u = all.find(z => z.id === Number(x.dataset.go)); m.close(); setCam((u.x + 0.5) / 5, (u.y + 0.5) / 5, Math.max(S.cam.z, 30)); openBld(u.bld); });
    b.querySelectorAll('[data-lease]').forEach(x => x.onclick = () => leaseUnit(Number(x.dataset.lease), all.find(z => z.id === Number(x.dataset.lease)), load));
  };
  load();
}
/* ---- 自分（名義）の建物 ---- */
async function openMyBlds() {
  const m = modal(['自分の建物', '<p class="muted small">読みこんでいます…</p>']);
  const d = await api('mp_unit_mine', { p_as: S.as }); if (!d) return m.close();
  m.set('自分の建物', `<p class="small" style="margin:0 0 6px">${esc(asName())}</p><div class="mp-list">${d.blds.map(b => `<button class="mp-item" style="text-align:left" data-b="${b.id}" data-xy="${b.x},${b.y}">
      <b>${esc(b.name || kindName(b.kind))}</b> <small><span>${esc(kindName(b.kind))}</span>${b.floors > 0 ? `・<span>${b.floors}階</span>` : ''}<br><span>入居 ${b.occ}/${b.n}</span>・<span>家賃 1日 ${X(b.rent)}</span></small></button>`).join('')
      || '<p class="muted small">建物はまだありません。自分の筆をタップして「建物を建てる」から建てられます</p>'}</div>`, b => {
    b.querySelectorAll('[data-b]').forEach(x => x.onclick = () => { const [cx, cy] = x.dataset.xy.split(',').map(Number); m.close(); setCam((cx + 0.5) / 5, (cy + 0.5) / 5, Math.max(S.cam.z, 30)); openBld(Number(x.dataset.b)); });
  });
}
window.MapApp = { open, pause, state: S, spline, setCam, landReqs: () => openLandReqs(), xfers: () => openXfers() };
})();
