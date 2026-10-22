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
  cells: new Map(), cellBusy: 0, ver: 0, pollT: 0,
  ov: null, ovInfo: null,
  layer: { zone: false, own: true, label: true },
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
        S.chunks.set(k, { cx: c.cx, cy: c.cy, t: c.t, e: c.e, z: c.z, a: c.a, ap: c.ap, zo: zoMap(c), lo: null, hi: null, zc: null, used: now() });
      }
      for (const [cx, cy] of batch) {
        const k = ckey(cx, cy); S.pend.delete(k);
        if (!got.has(k)) S.chunks.set(k, { cx, cy, sea: true, used: now() });
        // となりの絵をつくりなおす（境目をなめらかに）
        for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1], [1, 1], [-1, -1], [1, -1], [-1, 1]]) { const n = S.chunks.get(ckey(cx + dx, cy + dy)); if (n && !n.sea) { n.hi = null; } }
      }
      S.dirty = true;
    }).catch(e => { for (const [cx, cy] of batch) S.pend.delete(ckey(cx, cy)); console.warn(e); })
      .finally(() => { S.chunkBusy--; pumpChunks(); });
  }
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
// 読んだものを描きやすく（点をマスの小数に）
function prepArea(d) {
  for (const s of d.segs) {
    const p = s.p, n = p.length / 2, P = new Float32Array(p.length);
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    for (let i = 0; i < p.length; i += 2) { const x = p[i] / 100, y = p[i + 1] / 100; P[i] = x; P[i + 1] = y; if (x < x0) x0 = x; if (y < y0) y0 = y; if (x > x1) x1 = x; if (y > y1) y1 = y; }
    s.P = P; s.bb = [x0, y0, x1, y1]; s.np = n;
  }
  for (const s of d.stas) { s.fx = s.x / 100; s.fy = s.y / 100; }
  for (const s of d.deps) { s.fx = s.x / 100; s.fy = s.y / 100; }
  for (const n of d.nodes) { n.fx = n.x / 100; n.fy = n.y / 100; }
}
// 見えているセルのもの（id でまとめる）
function visibleItems() {
  const [lod, cs] = lodOf(S.cam.z), v = view();
  const i0 = Math.floor(v.x0 / cs), j0 = Math.floor(v.y0 / cs), i1 = Math.floor(v.x1 / cs), j1 = Math.floor(v.y1 / cs);
  const segs = new Map(), stas = new Map(), deps = new Map(), nodes = new Map(), land = new Map(), places = new Map(), names = {};
  const take = d => {
    for (const s of d.segs) segs.set(s.id, s);
    for (const s of d.stas) stas.set(s.id, s);
    for (const s of d.deps) deps.set(s.id, s);
    for (const n of d.nodes) nodes.set(n.id, n);
    for (const l of d.land) land.set(l[0] + ',' + l[1], l);
    for (const p of d.places) places.set(p.id, p);
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
  return { segs, stas, deps, nodes, land, places, names };
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
  // 土地（持ち主）
  if (S.layer.own && z >= 5) {
    for (const l of it.land.values()) {
      const x = sx(l[0]), y = sy(l[1]);
      if (x > S.W || y > S.H || x + z < 0 || y + z < 0) continue;
      g.fillStyle = l[2] === 2 ? 'rgba(40,110,220,.30)' : 'rgba(230,120,30,.22)';
      g.fillRect(x, y, z, z);
      if (l[3] != null && z >= 10) { g.strokeStyle = '#d23'; g.lineWidth = 1.5; g.strokeRect(x + 1, y + 1, z - 2, z - 2); }
      if (l[4] && z >= 8) { g.fillStyle = BLD_COL[l[4]] || '#999'; const m = z * 0.18; g.fillRect(x + m, y + m, z - 2 * m, z - 2 * m); }
    }
  }
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
  // 系統（めだたせる）
  if (S.routeHi) drawRouteHi(g, z, it);
  // 車庫・駅
  for (const d of it.deps.values()) drawDepot(g, d, z);
  for (const s of it.stas.values()) drawStation(g, s, z);
  // えらんだもの
  if (S.sel && S.sel.kind === 'seg') { const s = it.segs.get(S.sel.id); if (s) { g.strokeStyle = 'rgba(220,40,60,.75)'; g.lineWidth = Math.max(4, s.w * z + 4); pathSeg(g, s); g.stroke(); } }
  if (S.sel && S.sel.kind === 'tile') { g.strokeStyle = '#d23'; g.lineWidth = 2; g.strokeRect(sx(S.sel.x), sy(S.sel.y), z, z); }
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
const BLD_COL = { house: '#c98b5a', apt: '#a3765a', shop: '#e07a7a', office: '#7a8fe0', factory: '#8a8a8a', warehouse: '#b0a080', port: '#5a8ab0', farm: '#9cc06a', parking: '#c8c8c8' };
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
function depPoly(d) {
  const sz = (DEP_SIZE[d.k] || DEP_SIZE.rail)[d.sz] || [5, 2], lt = sz[0], wt = sz[1];
  const c = Math.cos(d.a), s = Math.sin(d.a), nx = -s * d.side, ny = c * d.side;
  const pts = [];
  for (const [a, b] of [[-lt / 2, 0.9], [lt / 2, 0.9], [lt / 2, 0.9 + wt], [-lt / 2, 0.9 + wt]]) pts.push([d.fx + c * a + nx * b, d.fy + s * a + ny * b]);
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
    const sz = (DEP_SIZE.rail[d.sz] || [5, 2]), n = Math.round(sz[1] / 0.35);
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
  const ps = [...it.places.values()];
  const show = p => p.k === 'pref' ? z < 0.45 : p.k === 'muni' ? (z >= 0.3 && z < 12 && (z > 1.2 || (p.pop || 0) > 150000 || p.t === '市')) : p.k === 'ward' ? z >= 1.2 && z < 14 : p.k === 'dist' ? z >= 7 : p.k === 'river' ? z >= 2.5 : false;
  const rank = p => p.k === 'pref' ? 0 : p.k === 'muni' ? 1 + (p.pop > 500000 ? 0 : 1) : p.k === 'ward' ? 3 : p.k === 'river' ? 4 : 5;
  ps.filter(show).sort((a, b) => rank(a) - rank(b) || (b.pop || 0) - (a.pop || 0)).forEach(p => {
    const x = sx(p.x + 0.5), y = sy(p.y + 0.5);
    if (x < -60 || y < -30 || x > S.W + 60 || y > S.H + 30) return;
    if (p.k === 'pref') label(g, p.n + '県', x, y, { size: 18, bold: true, color: '#3a3a3a' });
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
    needChunks(); needCells(); trimChunks();
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
.mp-list{display:flex;flex-direction:column;gap:6px;margin:6px 0}
.mp-item{border:1px solid var(--line,#ddd);border-radius:10px;padding:8px 10px;background:var(--panel,#fff)}
.mp-item small{color:var(--muted,#777)}
.mp-cars{display:flex;flex-wrap:wrap;gap:4px;margin:4px 0}
.mp-car{border:1px solid var(--line,#ccc);border-radius:7px;padding:4px 7px;font-size:12px;font-weight:700;background:var(--bg,#f6f6f6);cursor:pointer}
.mp-car.on{background:#1f5fbf;color:#fff;border-color:#1f5fbf}
.mp-car.busy{opacity:.55}
.mp-car .n{display:block;font-size:10px;font-weight:600;opacity:.8}
.mp-dia{width:100%;height:360px;border:1px solid var(--line,#ddd);border-radius:10px;background:#fff;touch-action:pan-x pan-y}
.mp-tt{width:100%;border-collapse:collapse;font-size:12px}
.mp-tt th,.mp-tt td{border-top:1px solid var(--line,#ddd);padding:4px 3px;text-align:center;white-space:nowrap;font-variant-numeric:tabular-nums}
.mp-tt th{font-size:11px;color:var(--muted,#666)}
.mp-tt td.st{text-align:left;font-weight:700}
.mp-scroll{overflow-x:auto}
.mp-inp{width:100%;box-sizing:border-box;font-size:15px;padding:8px 10px;border:1px solid var(--line,#ccc);border-radius:9px;background:var(--bg,#fff);color:inherit}
.mp-num{width:90px}
`;
function el(html) { const d = document.createElement('div'); d.innerHTML = html.trim(); return d.firstChild; }
function build(root) {
  if (!document.getElementById('mpCss')) { const st = document.createElement('style'); st.id = 'mpCss'; st.textContent = CSS; document.head.appendChild(st); }
  root.innerHTML = `<div class="mp-wrap" id="mpWrap">
    <canvas class="mp-cv"></canvas>
    <div class="mp-top">
      <select class="mp-as" title="だれの名前で"></select>
      <button data-lay="zone">用途地域</button><button data-lay="own" class="on">持ち主</button>
      <span class="mp-addr" hidden></span>
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
  S.wrap.querySelector('[data-full]').onclick = () => { S.wrap.classList.toggle('mp-full'); resize(); };
  S.wrap.querySelector('[data-zin]').onclick = () => zoomAt(S.W / 2, S.H / 2, 1.6);
  S.wrap.querySelector('[data-zout]').onclick = () => zoomAt(S.W / 2, S.H / 2, 1 / 1.6);
  S.wrap.querySelector('[data-home]').onclick = () => setCam(0, 0, 6);
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
  return S.sheet;
}
const asLabel = a => String((a && a.name) || '').replace(/（自分）$/, '');   // 自分は 👤 で見分ける（名前だけ出す）
const asName = () => asLabel(S.boot.as.find(a => a.as === S.as));
async function api(fn, args, okMsg) {
  try { const r = await call(fn, args); if (okMsg) toast(okMsg); return r; }
  catch (e) { toast(e.message); return null; }
}

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
  look: '', land: '土地：2か所タップして四角くえらびます（1か所なら1マス）',
  rail: '線路：タップして点をおくと、なめらかな線になります。点はドラッグで動かせます', road: '道路：タップして点をおくと、なめらかな線になります。点はドラッグで動かせます',
  sta: '駅：自分の線路の上をタップ（バス停：道路の上をタップ）', dep: '車庫：自分の線路（バスは道路）の横をタップ', del: 'こわす：自分の線・駅・車庫・建物をタップ'
};
function setTool(t) {
  if (S.toolEnd) { const f = S.toolEnd; S.toolEnd = null; f(); }
  S.tool = t; S.drawTool = null; S.addr.hidden = true; S.grab = S.grabMove = S.grabEnd = null; S.onLong = null; S.sel = null; S.routeHi = S.routeHi && S.keepRoute ? S.routeHi : null;
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
  const sg = nearSeg(x, y, 8);
  if (sg && (S.cam.z >= 3 || sg.s.k === 'rail' || ['exp', 'nat'].includes(sg.s.c))) return showSeg(sg.s, sg);
  return showTile(Math.floor(x), Math.floor(y));
}
// マスの上にあるもの（「駅：名前」「線路（路線名）・持ち主」など）：種類と名前を分けて出す（種類のことばだけ訳せるように）
function onH(n) {
  n = String(n || '');
  let m = /^(駅|バス停|車庫)：(.*)$/.exec(n);
  if (m) return `<span>${esc(m[1])}</span>：<span>${esc(m[2])}</span>`;
  m = /^(高速道路|国道|県道|市道|私道|線路)(?:（(.*?)）)?(?:・(.*))?$/.exec(n);
  if (m) return `<span>${esc(m[1])}</span>${m[2] ? `（<span>${esc(m[2])}</span>）` : ''}${m[3] ? `・<span>${esc(m[3])}</span>` : ''}`;
  return esc(n);
}
const CLS_NAME = { exp: '高速道路', nat: '国道', pref: '県道', city: '市道', lane: '市道（細い道）', priv: '私道', rail: '線路' };
async function showTile(tx, ty) {
  S.sel = { kind: 'tile', x: tx, y: ty }; S.dirty = true;
  const sh = sheet(`<h4>${tx}, ${ty}</h4><p class="muted small">しらべています…</p>`);
  const d = await api('mp_tile', { p_x: tx, p_y: ty }); if (!d || S.sheet !== sh || !S.sel || S.sel.x !== tx || S.sel.y !== ty) return;
  if (d.none) return sheet(`<h4>地図の外です</h4>`);
  const on = (d.on || []).map(o => onH(o.name)).join('<br>');
  sheet(`<h4>${esc(d.addr.text)}</h4>
    <div class="mp-kv"><b>地形</b><span><span>${esc(d.ter)}</span>${d.elev ? `<small>（標高 約${d.elev}m）</small>` : ''}</span><b>地目</b><span>${esc(d.chimoku)}</span>
      <b>用途地域</b><span>${esc(d.zname)}</span><b>人の多さ</b><span>${fmt(d.dens)} 人/km²</span>
      ${d.value != null ? `<b>地価</b><span>${X(d.value)}（1マス・約2,500m²）</span>` : ''}
      <b>持ち主</b><span>${d.owner ? `<span>${esc(d.owner)}</span>${d.mine ? '<small>（あなた）</small>' : ''}` : '国'}</span>
      ${d.sale != null ? `<b>売り出し</b><span>${X(d.sale)}</span>` : ''}
      ${d.bld ? `<b>建物</b><span><span>${esc(BLD_NAME[d.bld] || d.bld)}</span>${d.rent ? `<small>（家賃 1日 ${X(d.rent)}）</small>` : ''}</span>` : ''}
      ${on ? `<b>あるもの</b><span>${on}</span>` : ''}
      ${(d.leases || []).length ? `<b>使用料</b><span>${d.leases.map(l => `<span>${esc(l.who)}</span>：<span>1日 ${X(l.fee)}</span>`).join('<br>')}</span>` : ''}
    </div>
    <div class="mp-row">${d.buy ? `<button class="btn main" data-buy>この土地を買う（${X(d.sale != null ? Math.ceil(d.sale * 1.03) : d.value)}）</button>` : (d.why ? `<span class="muted small">${esc(d.why)}</span>` : '')}
      ${d.mine ? `<button class="btn" data-sell>${d.sale != null ? '売り出しをやめる' : '売りに出す'}</button><button class="btn" data-bld>建物</button>` : ''}</div>`, s => {
    const b = s.querySelector('[data-buy]'); if (b) b.onclick = () => landBuy([tx, ty]);
    const se = s.querySelector('[data-sell]'); if (se) se.onclick = () => landSell([tx, ty], d.sale != null);
    const bl = s.querySelector('[data-bld]'); if (bl) bl.onclick = () => bldPick([tx, ty]);
  });
  S.addr.hidden = false; S.addr.textContent = d.addr.text;
}
const BLD_NAME = { house: '住宅', apt: 'マンション', shop: '商店', office: 'オフィスビル', factory: '工場', warehouse: '倉庫', port: '港湾施設', farm: '田畑', parking: '駐車場' };
function showSeg(s, hit) {
  S.sel = { kind: 'seg', id: s.id }; S.dirty = true;
  const own = s.o === 'gov' ? '国' : (S.vis.names[s.o] || '');
  sheet(`<h4><span>${esc(CLS_NAME[s.c] || s.c)}</span>${s.n ? `・<span>${esc(s.n)}</span>` : ''}</h4><p class="small muted" data-addr style="margin:0"></p>
    <div class="mp-kv"><b>持ち主</b><span><span>${esc(own)}</span>${s.mine && s.o !== 'gov' ? '<small>（あなた）</small>' : ''}</span>
      <b>長さ</b><span>${fmt(Math.round(s.len * 50))} m</span>
      ${s.k === 'road' ? `<b>車線</b><span>${s.l ? '片側' + s.l + '車線' : '中央線なし'}</span>` : `<b>線路</b><span>${s.dbl ? '複線' : '単線'}・${s.el ? '電化' : '非電化'}</span>`}
      <b>制限速度</b><span>${s.v} km/h</span></div>
    ${s.mine ? `<div class="mp-row"><button class="btn" data-edit>形を直す</button><button class="btn" data-split>ここで分ける</button><button class="btn" data-opt>${s.k === 'rail' ? '複線・電化・名前' : '車線・名前'}</button><button class="btn" data-del>こわす</button></div>` : ''}`, sh => {
    const q = k => sh.querySelector(k);
    if (q('[data-edit]')) q('[data-edit]').onclick = () => startEdit(s);
    if (q('[data-split]')) q('[data-split]').onclick = async () => { if (await api('mp_seg_split', { p_id: s.id, p_x: hit.x, p_y: hit.y }, '分けました')) { refreshBox(...s.bb); sheet(null); } };
    if (q('[data-opt]')) q('[data-opt]').onclick = () => segOpts(s);
    if (q('[data-del]')) q('[data-del]').onclick = () => segDel(s);
  });
  if (hit) addrInto(Math.floor(hit.x), Math.floor(hit.y), () => S.sel && S.sel.kind === 'seg' && S.sel.id === s.id);
}
// 住所をシートと上の帯に
async function addrInto(tx, ty, still) {
  const d = await api('mp_tile', { p_x: tx, p_y: ty }); if (!d || !d.addr || !still()) return;
  const e = S.sheet.querySelector('[data-addr]'); if (e) e.textContent = d.addr.text;
  S.addr.hidden = false; S.addr.textContent = d.addr.text;
}
function segOpts(s) {
  const st = { dbl: s.dbl, el: s.el, l: s.l, name: s.n || '' };
  const draw = async () => {
    const q = await api('mp_seg_opts', { p_id: s.id, p_dbl: st.dbl, p_elec: st.el, p_name: st.name, p_dry: true, p_lanes: st.l });
    sheet(`<h4>${s.k === 'rail' ? '線路' : '道路'}の設定</h4>
      ${s.k === 'rail' ? `<div class="mp-row"><span class="mp-seg"><button data-d="0" class="${!st.dbl ? 'on' : ''}">単線</button><button data-d="1" class="${st.dbl ? 'on' : ''}">複線</button></span>
        <span class="mp-seg"><button data-e="0" class="${!st.el ? 'on' : ''}">非電化</button><button data-e="1" class="${st.el ? 'on' : ''}">電化</button></span></div>`
      : `<div class="mp-row">片側 <span class="mp-seg">${[0, 1, 2, 3].map(n => `<button data-l="${n}" class="${st.l === n ? 'on' : ''}">${n ? n + '車線' : '細い道'}</button>`).join('')}</span></div>`}
      <div class="mp-row"><input class="mp-inp" data-nm placeholder="名前（路線名など）" value="${esc(st.name)}"></div>
      <p class="mp-cost">${q ? (q.cost > 0 ? '工事費 ' + X(q.cost) : '工事費なし') : ''}</p><p class="muted small">もとにもどしても（単線にする・車線をへらす）お金はもどりません</p>
      <div class="mp-row"><button class="btn main" data-ok>この設定にする</button></div>`, sh => {
      sh.querySelectorAll('[data-d]').forEach(b => b.onclick = () => { st.dbl = b.dataset.d === '1'; draw(); });
      sh.querySelectorAll('[data-e]').forEach(b => b.onclick = () => { st.el = b.dataset.e === '1'; draw(); });
      sh.querySelectorAll('[data-l]').forEach(b => b.onclick = () => { st.l = Number(b.dataset.l); draw(); });
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
  sheet(`<h4>${s.k === 'rail' ? '🚉 ' : '🚏 '}<span>${esc(s.n)}</span>${s.k === 'rail' ? '<span>駅</span>' : ''}</h4><p class="small muted" data-addr style="margin:0"></p>
    <div class="mp-kv"><b>持ち主</b><span><span>${esc(S.vis.names[s.o] || '')}</span>${s.mine ? '<small>（あなた）</small>' : ''}</span>
      ${s.k === 'rail' ? `<b>ホーム</b><span>${s.pl} m・${s.tr}番線まで</span>` : ''}
      <b>系統</b><span>${(s.rt || []).map(r => `<a href="#" data-rt="${r.id}" style="color:${esc(r.c)};font-weight:800">■ ${esc(r.n)}</a>`).join('<br>') || 'なし'}</span></div>
    ${s.mine ? `<div class="mp-row"><button class="btn" data-ren>名前を変える</button><button class="btn" data-del>こわす</button></div>` : ''}`, sh => {
    sh.querySelectorAll('[data-rt]').forEach(a => a.onclick = ev => { ev.preventDefault(); openDia(Number(a.dataset.rt)); });
    const r = sh.querySelector('[data-ren]'); if (r) r.onclick = async () => { const nm = prompt(T('新しい名前'), s.n); if (nm && await api('mp_sta_edit', { p_id: s.id, p_name: nm, p_del: false }, '名前を変えました')) refreshBox(s.fx - 3, s.fy - 3, s.fx + 3, s.fy + 3); };
    const d = sh.querySelector('[data-del]'); if (d) d.onclick = async () => { if (confirm(T('こわしますか？（工事費はもどりません）')) && await api('mp_sta_edit', { p_id: s.id, p_name: null, p_del: true }, 'こわしました')) { refreshBox(s.fx - 3, s.fy - 3, s.fx + 3, s.fy + 3); sheet(null); } };
  });
  addrInto(Math.floor(s.fx), Math.floor(s.fy), () => S.sel && S.sel.kind === 'sta' && S.sel.id === s.id);
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

/* ---- 土地 ---- */
function startLand() {
  S.toolState = { a: null, b: null };
  S.drawTool = (g, z) => {
    const st = S.toolState; if (!st || !st.a) return;
    const b = st.b || st.a, x0 = Math.min(st.a[0], b[0]), y0 = Math.min(st.a[1], b[1]), x1 = Math.max(st.a[0], b[0]) + 1, y1 = Math.max(st.a[1], b[1]) + 1;
    g.fillStyle = 'rgba(30,110,230,.18)'; g.fillRect(sx(x0), sy(y0), (x1 - x0) * z, (y1 - y0) * z);
    g.strokeStyle = '#1f5fbf'; g.lineWidth = 2; g.setLineDash([6, 4]); g.strokeRect(sx(x0), sy(y0), (x1 - x0) * z, (y1 - y0) * z); g.setLineDash([]);
  };
  S.tapHook = (x, y) => {
    const st = S.toolState, t = [Math.floor(x), Math.floor(y)];
    if (!st.a || st.b) { st.a = t; st.b = null; landSheet(); }
    else { st.b = t; landSheet(); }
    S.dirty = true;
  };
  S.toolEnd = () => { S.tapHook = null; S.toolState = null; };
}
function landTiles() {
  const st = S.toolState; if (!st || !st.a) return [];
  const b = st.b || st.a, out = [];
  for (let y = Math.min(st.a[1], b[1]); y <= Math.max(st.a[1], b[1]); y++) for (let x = Math.min(st.a[0], b[0]); x <= Math.max(st.a[0], b[0]); x++) out.push(x, y);
  return out;
}
async function landSheet() {
  const tiles = landTiles(), n = tiles.length / 2;
  if (n > 400) return sheet(`<h4>${n}マス</h4><p class="mp-warn">一度にえらべるのは400マス（20×20）までです</p>`);
  sheet(`<h4>${n}マス えらびました</h4><p class="muted small">見つもっています…</p>`);
  const q = await api('mp_land_buy', { p_tiles: tiles, p_as: S.as, p_dry: true });
  if (!q || landTiles().length / 2 !== n) return;
  const why = q.why || {}, sk = [why.water && `水の上 ${why.water}`, why.park && `公園 ${why.park}`, why.road && `公道 ${why.road}`, why.owned && `持ち主がいる ${why.owned}`].filter(Boolean).map(t => `<span>${esc(t)}</span>`).join('・');
  const mine = (S.vis ? [...S.vis.land.values()] : []).filter(l => l[2] === 2 && tiles.some((v, i) => i % 2 === 0 && v === l[0] && tiles[i + 1] === l[1]));
  sheet(`<h4>${n}マス えらびました</h4>
    <div class="mp-kv"><b>買える</b><span>${q.n}マス・<span class="mp-cost">${X(q.total)}</span>（${esc(asName())}）</span>${sk ? `<b>買えない</b><span>${sk}</span>` : ''}
    <b>固定資産税</b><span>1日 約${X(q.tax_day)}</span></div>
    <div class="mp-row">${q.n ? `<button class="btn main" data-buy>買う</button>` : ''}${mine.length ? `<button class="btn" data-sell>売りに出す（${mine.length}マス）</button><button class="btn" data-bld>建物を建てる</button>` : ''}</div>
    <p class="muted small">もう一度2か所タップすると、えらびなおせます</p>`, s => {
    const b = s.querySelector('[data-buy]'); if (b) b.onclick = () => landBuy(tiles);
    const se = s.querySelector('[data-sell]'); if (se) se.onclick = () => landSell(mine.flatMap(l => [l[0], l[1]]), false);
    const bl = s.querySelector('[data-bld]'); if (bl) bl.onclick = () => bldPick(mine.flatMap(l => [l[0], l[1]]));
  });
}
async function landBuy(tiles) {
  const r = await api('mp_land_buy', { p_tiles: tiles, p_as: S.as, p_dry: false });
  if (r) { toast(`${r.n}マス買いました（${fmt(r.total)} X）`); boxOf(tiles); sheet(null); }
}
async function landSell(tiles, stop) {
  let price = null;
  if (!stop) { const v = prompt(T('1マスの値段（X）'), ''); if (!v) return; price = Number(String(v).replace(/[^\d]/g, '')); if (!price) return; }
  if (await api('mp_land_sell', { p_tiles: tiles, p_price: price, p_as: S.as }, stop ? '売り出しをやめました' : '売りに出しました')) { boxOf(tiles); sheet(null); }
}
function boxOf(tiles) { let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity; for (let i = 0; i < tiles.length; i += 2) { x0 = Math.min(x0, tiles[i]); y0 = Math.min(y0, tiles[i + 1]); x1 = Math.max(x1, tiles[i]); y1 = Math.max(y1, tiles[i + 1]); } refreshBox(x0, y0, x1 + 1, y1 + 1); }
async function bldPick(tiles) {
  const types = S.boot.bld;
  sheet(`<h4>建物を建てる（${tiles.length / 2}マス）</h4><div class="mp-list">${types.map(b => `<button class="mp-item" style="text-align:left" data-b="${b.k}"><b>${esc(b.n)}</b>
      <small>　1マス ${X(b.cost)}・家賃 1日 建てた額の約${(b.rate * 100).toFixed(1)}%（地価で上下）・建てられる用途地域：${b.z.split('').map(z => PAL.ZN[z]).join('・')}</small></button>`).join('')}
    <button class="mp-item" style="text-align:left" data-b=""><b>こわす（更地にする）</b></button></div>`, s => {
    s.querySelectorAll('[data-b]').forEach(b => b.onclick = async () => {
      const k = b.dataset.b || null;
      const q = await api('mp_bld', { p_tiles: tiles, p_type: k, p_as: S.as, p_dry: true }); if (!q) return;
      if (!confirm(T((k ? `${q.n}マスに建てます（${fmt(q.cost)} X）。よろしいですか？` : `${q.n}マスの建物をこわします。よろしいですか？`) + (q.skip ? '\nできないマスがあります' : '')))) return;
      if (await api('mp_bld', { p_tiles: tiles, p_type: k, p_as: S.as, p_dry: false }, k ? '建てました' : 'こわしました')) { boxOf(tiles); sheet(null); }
    });
  });
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
  const st = S.toolState = { kind, ctrl: [], A: null, B: null, curve: [], quote: null, err: null, opts: { dbl: false, elec: false, lanes: admin ? 2 : 1, cls: admin ? 'nat' : 'priv', name: '' }, qt: 0 };
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
function drawUpdate(fast) {
  const st = S.toolState; if (!st) return;
  const [A, B] = phantoms(st);
  st.curve = st.ctrl.length >= 2 ? spline(st.ctrl, A, B) : [];
  st.rmin = st.curve.length > 6 ? minRadius(st.curve) : 1e9;
  st.quote = null; st.err = null;
  S.dirty = true;
  if (!fast) { clearTimeout(st.qt); st.qt = setTimeout(() => quoteDraw(st), 350); }
  drawSheet();
}
async function quoteDraw(st) {
  if (S.toolState !== st || st.curve.length < 3) return;
  const args = drawArgs(st, true);
  try { st.quote = await call(st.edit ? 'mp_seg_edit' : 'mp_seg_build', args); st.err = null; }
  catch (e) { st.quote = null; st.err = e.message; }
  if (S.toolState === st) drawSheet();
}
function drawArgs(st, dry) {
  if (st.edit) return { p_id: st.edit.id, p_ctl: toInts(st.ctrl), p_pts: toInts(st.curve), p_dry: dry };
  const o = st.opts;
  return { p_kind: st.kind, p_cls: st.kind === 'road' ? o.cls : null, p_ctl: toInts(st.ctrl), p_pts: toInts(st.curve),
    p_opts: { dbl: o.dbl, elec: o.elec, name: o.name, lanes: o.lanes }, p_as: S.as, p_from: st.A ? st.A.att : null, p_to: st.B ? st.B.att : null, p_dry: dry };
}
function drawSheet() {
  const st = S.toolState; if (!st) return;
  const o = st.opts, rail = st.kind === 'rail', gov = S.as === 'gov', lenM = st.curve.length > 1 ? Math.round((st.curve.length - 1) * 0.5 * 50) : 0;
  const rminM = Math.round(st.rmin * 50), tight = rail ? st.rmin < 3 : st.rmin < 0.7;
  const q = st.quote;
  sheet(`<h4>${st.edit ? (rail ? '線路の形を直す' : '道路の形を直す') : rail ? '線路をひく' : '道路をひく'}</h4>
    <p class="small" style="margin:0 0 4px"><span>点 ${st.ctrl.length}・長さ 約${fmt(lenM)} m</span>${st.curve.length > 6 ? `<span>・いちばんきついカーブ 半径 ${rminM >= 50000 ? '—' : fmt(rminM) + ' m'}</span>` : ''}${st.A ? '<span>・はじめ：つなぐ</span>' : ''}${st.B ? '<span>・おわり：つなぐ</span>' : ''}</p>
    ${tight ? `<p class="mp-warn">${rail ? 'カーブがきつすぎます（線路は半径150m以上）' : 'カーブがきつすぎます'}</p>` : ''}
    ${st.edit ? '' : rail ? `<div class="mp-row"><span class="mp-seg"><button data-d="0" class="${!o.dbl ? 'on' : ''}">単線</button><button data-d="1" class="${o.dbl ? 'on' : ''}">複線</button></span>
        <span class="mp-seg"><button data-e="0" class="${!o.elec ? 'on' : ''}">非電化</button><button data-e="1" class="${o.elec ? 'on' : ''}">電化</button></span></div>`
      : `<div class="mp-row">${gov ? `<select class="mp-inp" style="width:auto" data-cls>${[['exp', '高速道路'], ['nat', '国道'], ['pref', '県道'], ['city', '市道'], ['lane', '細い道']].map(c => `<option value="${c[0]}" ${o.cls === c[0] ? 'selected' : ''}>${c[1]}</option>`).join('')}</select>` : ''}
        片側 <span class="mp-seg">${(gov ? [0, 1, 2, 3] : [0, 1, 2]).map(n => `<button data-l="${n}" class="${o.lanes === n ? 'on' : ''}">${n ? n + '車線' : '細い道'}</button>`).join('')}</span></div>`}
    ${st.edit ? '' : `<div class="mp-row"><input class="mp-inp" data-nm placeholder="${rail ? '路線名（なくてもよい）' : '道路の名前（なくてもよい）'}" value="${esc(o.name)}"></div>`}
    <div class="mp-row">${q ? `<span class="mp-cost">工事費 ${X(q.cost)}</span><span class="small"><span>使用料 1日 ${X(q.lease || 0)}</span>${q.tunnel ? `<span>・トンネル ${q.tunnel}マス</span>` : ''}${q.bridge ? `<span>・橋 ${q.bridge}マス</span>` : ''}<span>・最高 ${q.vlim} km/h</span></span>`
      : st.err ? `<span class="mp-warn">${esc(st.err)}</span>` : st.curve.length > 2 ? '<span class="muted small">見つもり中…</span>' : '<span class="muted small">地図をタップして点をおいてください（2つ以上）。はしを線の近くにおくと、つながります</span>'}</div>
    <div class="mp-row"><button class="btn" data-undo ${st.ctrl.length ? '' : 'disabled'}>1つもどす</button><button class="btn" data-cancel>キャンセル</button>
      <button class="btn main" data-ok ${q && !tight ? '' : 'disabled'}>${st.edit ? 'この形にする' : `つくる（${esc(asName())}）`}</button></div>
    <p class="muted small" style="margin:6px 0 0">点はドラッグで動かせます。長押しで消せます</p>`, s => {
    s.querySelectorAll('[data-d]').forEach(b => b.onclick = () => { o.dbl = b.dataset.d === '1'; drawUpdate(); });
    s.querySelectorAll('[data-e]').forEach(b => b.onclick = () => { o.elec = b.dataset.e === '1'; drawUpdate(); });
    s.querySelectorAll('[data-l]').forEach(b => b.onclick = () => { o.lanes = Number(b.dataset.l); drawUpdate(); });
    const cl = s.querySelector('[data-cls]'); if (cl) cl.onchange = () => { o.cls = cl.value; drawUpdate(); };
    const nm = s.querySelector('[data-nm]'); if (nm) nm.onchange = () => { o.name = nm.value; };
    s.querySelector('[data-undo]').onclick = () => { if (st.edit && st.ctrl.length <= 2) return; st.ctrl.pop(); if (!st.edit) st.B = null; if (!st.ctrl.length) st.A = null; drawUpdate(); };
    s.querySelector('[data-cancel]').onclick = () => setTool(st.edit ? 'look' : st.kind);
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
function nearDist(x, y) {
  let best = null, bd = Infinity;
  for (const p of (S.vis ? S.vis.places.values() : [])) { if (p.k !== 'dist') continue; const d = (p.x - x) ** 2 + (p.y - y) ** 2; if (d < bd) { bd = d; best = p; } }
  return best ? best.n : '';
}
function staTap(x, y) {
  const hr = nearSeg(x, y, 14, s => s.k === 'rail' && s.mine);
  if (hr) return staSheet('rail', hr, x, y);
  const hb = nearSeg(x, y, 12, s => s.k === 'road' && s.c !== 'exp');
  if (hb) return staSheet('bus', hb, x, y);
  toast('自分の線路か、道路の上をタップしてください');
}
function staSheet(kind, hit, x, y) {
  const st = { plat: 160, tracks: 2, name: nearDist(x, y), q: null, err: null };
  S.sel = { kind: 'seg', id: hit.s.id }; S.dirty = true;
  const quote = async () => {
    try { st.q = await call('mp_sta_build', { p_kind: kind, p_seg: hit.s.id, p_x: hit.x, p_y: hit.y, p_plat: st.plat, p_tracks: st.tracks, p_name: st.name || '仮', p_as: S.as, p_dry: true }); st.err = null; }
    catch (e) { st.q = null; st.err = e.message; }
    draw();
  };
  const draw = () => sheet(`<h4>${kind === 'rail' ? '🚉 駅をつくる' : '🚏 バス停をつくる'}</h4>
    <div class="mp-row"><input class="mp-inp" data-nm placeholder="${kind === 'rail' ? '駅の名前（「駅」はつけない）' : 'バス停の名前'}" value="${esc(st.name)}"></div>
    ${kind === 'rail' ? `<div class="mp-row">ホーム <span class="mp-seg">${[80, 120, 160, 200, 240, 320].map(m => `<button data-p="${m}" class="${st.plat === m ? 'on' : ''}">${m}m</button>`).join('')}</span></div>
      <div class="mp-row">番線 <span class="mp-seg">${[1, 2, 3, 4, 6].map(n => `<button data-t="${n}" class="${st.tracks === n ? 'on' : ''}">${n}</button>`).join('')}</span>
      <span class="muted small">20m の車両 ${Math.floor(st.plat / 20)}両まで</span></div>` : ''}
    <div class="mp-row">${st.q ? `<span class="mp-cost">工事費 ${X(st.q.cost)}</span><span class="small">維持費 1日 ${X(st.q.up_day)}</span>` : st.err ? `<span class="mp-warn">${esc(st.err)}</span>` : '<span class="muted small">見つもり中…</span>'}</div>
    <div class="mp-row"><button class="btn main" data-ok ${st.q ? '' : 'disabled'}>つくる（${esc(asName())}）</button></div>`, s => {
    s.querySelector('[data-nm]').onchange = e => { st.name = e.target.value; };
    s.querySelectorAll('[data-p]').forEach(b => b.onclick = () => { st.plat = Number(b.dataset.p); quote(); });
    s.querySelectorAll('[data-t]').forEach(b => b.onclick = () => { st.tracks = Number(b.dataset.t); quote(); });
    s.querySelector('[data-ok]').onclick = async () => {
      st.name = s.querySelector('[data-nm]').value.trim(); if (!st.name) return toast('名前をつけてください');
      if (await api('mp_sta_build', { p_kind: kind, p_seg: hit.s.id, p_x: hit.x, p_y: hit.y, p_plat: st.plat, p_tracks: st.tracks, p_name: st.name, p_as: S.as, p_dry: false }, 'つくりました')) {
        refreshBox(hit.x - 6, hit.y - 6, hit.x + 6, hit.y + 6); sheet(null); S.sel = null;
      }
    };
  });
  draw(); quote();
}

/* ---- 車庫 ---- */
function depTap(x, y) {
  const hr = nearSeg(x, y, 14, s => s.k === 'rail' && s.mine);
  const hb = hr ? null : nearSeg(x, y, 12, s => s.k === 'road' && s.c !== 'exp');
  const hit = hr || hb; if (!hit) return toast('自分の線路（バスは道路）の近くをタップしてください');
  const kind = hr ? 'rail' : 'bus';
  // タップした側
  const side = ((x - hit.x) * -Math.sin(hit.ang) + (y - hit.y) * Math.cos(hit.ang)) >= 0 ? 1 : -1;
  const st = { size: 'S', side, name: nearDist(x, y) + (kind === 'rail' ? '車両基地' : '営業所'), q: null, err: null };
  const prev = () => ({ fx: hit.x, fy: hit.y, a: hit.ang, side: st.side, sz: st.size, k: kind });
  S.drawTool = (g, z) => { const P = depPoly(prev()); g.beginPath(); P.forEach((p, i) => i ? g.lineTo(sx(p[0]), sy(p[1])) : g.moveTo(sx(p[0]), sy(p[1]))); g.closePath(); g.fillStyle = st.err ? 'rgba(220,40,40,.35)' : 'rgba(30,110,230,.3)'; g.fill(); g.strokeStyle = '#1f5fbf'; g.lineWidth = 2; g.stroke(); };
  S.dirty = true;
  const quote = async () => {
    try { st.q = await call('mp_dep_build', { p_kind: kind, p_seg: hit.s.id, p_x: hit.x, p_y: hit.y, p_side: st.side, p_size: st.size, p_name: st.name || '仮', p_as: S.as, p_dry: true }); st.err = null; }
    catch (e) { st.q = null; st.err = e.message; }
    draw(); S.dirty = true;
  };
  const sizes = kind === 'rail' ? [['S', '小（16両）'], ['M', '中（48両）'], ['L', '大（120両）']] : [['S', '小（20台）'], ['M', '中（60台）']];
  const draw = () => sheet(`<h4>${kind === 'rail' ? '🏭 車両基地をつくる' : '🏭 バスの営業所をつくる'}</h4>
    <div class="mp-row"><input class="mp-inp" data-nm value="${esc(st.name)}"></div>
    <div class="mp-row"><span class="mp-seg">${sizes.map(s => `<button data-s="${s[0]}" class="${st.size === s[0] ? 'on' : ''}">${s[1]}</button>`).join('')}</span>
      <button class="btn" data-side>反対側にする</button></div>
    <div class="mp-row">${st.q ? `<span class="mp-cost">工事費 ${X(st.q.cost)}</span><span class="small">使用料 1日 ${X(st.q.lease)}・維持費 1日 ${X(st.q.up_day)}</span>` : st.err ? `<span class="mp-warn">${esc(st.err)}</span>` : '<span class="muted small">見つもり中…</span>'}</div>
    <div class="mp-row"><button class="btn main" data-ok ${st.q ? '' : 'disabled'}>つくる（${esc(asName())}）</button></div>`, s => {
    s.querySelector('[data-nm]').onchange = e => { st.name = e.target.value; };
    s.querySelectorAll('[data-s]').forEach(b => b.onclick = () => { st.size = b.dataset.s; quote(); });
    s.querySelector('[data-side]').onclick = () => { st.side = -st.side; quote(); };
    s.querySelector('[data-ok]').onclick = async () => {
      st.name = s.querySelector('[data-nm]').value.trim();
      if (await api('mp_dep_build', { p_kind: kind, p_seg: hit.s.id, p_x: hit.x, p_y: hit.y, p_side: st.side, p_size: st.size, p_name: st.name, p_as: S.as, p_dry: false }, 'つくりました')) {
        refreshBox(hit.x - 12, hit.y - 12, hit.x + 12, hit.y + 12); sheet(null); S.drawTool = null;
      }
    };
  });
  S.onSheetClose = () => { S.drawTool = null; S.dirty = true; };
  draw(); quote();
}

/* ---- こわす ---- */
async function delTap(x, y) {
  const st = nearSta(x, y, 14); if (st && st.s.mine) return showSta(st.s);
  const dp = nearDep(x, y); if (dp && dp.mine) return showDep(dp);
  const sg = nearSeg(x, y, 10, s => s.mine); if (sg) return segDel(sg.s);
  const l = S.vis && S.vis.land.get(Math.floor(x) + ',' + Math.floor(y));
  if (l && l[2] === 2 && l[4]) { if (confirm(T('この建物をこわしますか？'))) { if (await api('mp_bld', { p_tiles: [l[0], l[1]], p_type: null, p_as: S.as, p_dry: false }, 'こわしました')) refreshBox(l[0], l[1], l[0] + 1, l[1] + 1); } return; }
  toast('こわせるもの（自分の線・駅・車庫・建物）がありません');
}

/* ---------- メニュー（車両・系統・ダイヤ・お金・管理） ---------- */
function modal(html, bind, cls) {
  const m = document.createElement('div'); m.className = 'modal mp-modal';
  m.innerHTML = `<div class="sheet ${cls || ''}"><div class="row" style="display:flex;align-items:center;gap:8px"><b style="font-size:18px" data-title></b><button class="btn" style="margin-left:auto" data-x>とじる</button></div><div data-body></div></div>`;
  const body = m.querySelector('[data-body]');
  m.onclick = ev => { if (ev.target === m || ev.target.hasAttribute('data-x')) close(); };
  const close = () => { m.remove(); if (m.onclose) m.onclose(); };
  m.set = (title, h, b) => { m.querySelector('[data-title]').textContent = T(title); body.innerHTML = h; if (b) b(body); };
  m.close = close;
  document.body.appendChild(m);
  if (html) m.set(html[0], html[1], bind);
  return m;
}
function openMenu() {
  const m = modal(['国土のメニュー', `<div class="mp-list">
    <button class="mp-item" style="text-align:left" data-k="cars"><b>🚃 車両と編成</b><br><small>注文（1両から）・編成を組む・改造・検査・更新・転属・廃車</small></button>
    <button class="mp-item" style="text-align:left" data-k="routes"><b>🗺 系統とダイヤ</b><br><small>止まる駅の順番・列車の時刻（採時駅）・ダイヤグラム・運用</small></button>
    <button class="mp-item" style="text-align:left" data-k="ledger"><b>💴 お金の記録</b><br><small>運賃・家賃・維持費・使用料・工事費（${esc(asName())}）</small></button>
    ${S.admin ? `<button class="mp-item" style="text-align:left" data-k="admin"><b>🛠 管理</b><br><small>値段の設定・用途地域・ようす</small></button>` : ''}
    <button class="mp-item" style="text-align:left" data-k="help"><b>❓ あそびかた</b></button></div>`], b => {
    b.querySelectorAll('[data-k]').forEach(x => x.onclick = () => { m.close(); ({ cars: () => openCars(), routes: openRoutes, ledger: openLedger, admin: openAdmin, help: openHelp })[x.dataset.k](); });
  });
}
function openHelp() {
  modal(['国土のあそびかた', `<div class="small" style="line-height:1.8">
    <p><b>地図</b>：瑠璃市中里区がまん中。北西が山、南東が海です。指2本で拡大・縮小、ドラッグで動かします。タップすると住所・地目・用途地域・地価がわかります。</p>
    <p><b>土地</b>：国の土地は地価で買えます。売りに出ている土地は、その値段（＋取得税3%）。毎日、地価の0.01%の固定資産税。建物を建てると毎時間家賃が入ります。</p>
    <p><b>線路・道路</b>：点をおくと、なめらかな線になります。他人の土地や国の土地の上につくると、毎日使用料がかかります（国・県・市の道路の上はかかりません）。まちの中は工事費が高くなります。</p>
    <p><b>駅と車庫</b>：駅はホームの長さと番線の数を決めます（20mの車両がホームに入る両数まで）。車両は車庫に車籍をおきます。</p>
    <p><b>車両</b>：122系0番台は国鉄103系とほぼ同じ性能（最高100km/h）。1両ずつ注文して、両はしに運転台つきの Tc（奇数向き・偶数向き）、まん中に Mp（パンタグラフつき）と M をはさんで編成にします。</p>
    <p><b>系統とダイヤ</b>：止まる駅を順にえらんで系統をつくり、列車を入れます。時刻を決めるのは、会社が決めた採時駅だけ（着・発・番線）。ほかの駅は走る時間から自動で決まります。「運用を自動で組む」で、編成を列車にわりあてられます。</p>
    <p><b>お金</b>：1時間ごとに運賃（駅のまわりの人・本数・速さ・冷暖房で決まる）が入り、維持費・使用料をはらいます。</p></div>`]);
}

/* ---- 車両と編成 ---- */
async function openCars(depFocus) {
  const m = modal(['車両と編成', '<p class="muted small">読みこんでいます…</p>']);
  const st = { dep: depFocus || null, pick: [], form: null, mode: 'view' };
  const load = async () => {
    const d = await api('mp_cars_list', { p_as: S.as }); if (!d) return;
    st.d = d;
    if (!st.dep || !d.depots.some(x => x.id === st.dep)) st.dep = d.depots.length ? d.depots[0].id : null;
    draw();
  };
  const carChip = (c, on) => `<span class="mp-car ${on ? 'on' : ''} ${c.busy ? 'busy' : ''}" data-car="${c.id}">${esc(c.num)}<span class="n">${c.busy ? esc({ deliver: '納車まち', move: '転属中', ac: '冷房工事', heat: '暖房工事', toilet: 'トイレ工事', inspect: '検査中', renew: '更新工事' }[c.busy] || c.busy) : `<span>状態${c.cond}</span>${c.ac ? '❄' : ''}${c.toilet ? '🚻' : ''}`}</span></span>`;
  const draw = () => {
    const d = st.d, deps = d.depots, dep = deps.find(x => x.id === st.dep);
    if (!deps.length) return m.set('車両と編成', `<p class="small">まず地図で車庫（🏭）をつくってください。車両は車庫に車籍をおきます（${esc(asName())}）。</p>`);
    const cars = d.cars.filter(c => c.depot === st.dep), forms = d.forms.filter(f => f.depot === st.dep), loose = cars.filter(c => !c.form);
    const typeOpts = d.types.filter(t => (t.role === 'Bus') === (dep.kind === 'bus'));
    m.set('車両と編成', `
      <div class="tabs-s">${deps.map(x => `<button data-dep="${x.id}" class="${x.id === st.dep ? 'on' : ''}">${esc(x.name)} ${x.n}/${x.cap}</button>`).join('')}</div>
      <h4 style="margin:12px 0 4px">編成（${forms.length}）</h4>
      ${forms.map(f => { const p = f.perf || {}; const fc = cars.filter(c => c.form === f.id).sort((a, b) => a.pos - b.pos); return `<div class="mp-item">
        <b>${esc(f.name)}</b> <small><span>${p.n}両・${p.len}m・定員${fmt(p.cap)}人・加速 ${p.acc}km/h/s・最高${p.vmax}km/h</span>${p.ac ? '<span>・冷房</span>' : ''}${p.toilet ? '<span>・トイレ</span>' : ''}<span>・状態${p.cond}・列車 ${f.trains}本</span></small>
        <div class="mp-cars">${fc.map(c => carChip(c, st.pick.includes(c.id))).join('')}</div>
        ${dep.kind === 'rail' ? `<div class="mp-row"><button class="btn" data-reform="${f.id}">組みかえる</button><button class="btn" data-split="${f.id}">ばらす</button></div>` : ''}</div>`; }).join('') || '<p class="muted small">まだありません</p>'}
      ${dep.kind === 'rail' ? `<h4 style="margin:12px 0 4px">編成に入っていない車両（${loose.length}）</h4><div class="mp-cars">${loose.map(c => carChip(c, st.pick.includes(c.id))).join('') || '<span class="muted small">なし</span>'}</div>` : ''}
      <div class="mp-item" style="margin-top:8px">${st.pick.length ? `<b>えらんだ車両（${st.pick.length}）</b>：${st.pick.map(id => esc((d.cars.find(c => c.id === id) || {}).num || '')).join(' → ')}
          <div class="mp-row">${dep.kind === 'rail' ? `<input class="mp-inp" style="flex:1 1 120px" data-fname placeholder="編成の名前" value="${esc(st.form ? (d.forms.find(f => f.id === st.form) || {}).name || '' : '')}"><button class="btn main" data-mkform>${st.form ? 'この順に組みかえる' : 'この順で編成にする'}</button>` : ''}</div>
          <div class="mp-row"><button class="btn" data-w="ac">冷房をつける</button><button class="btn" data-w="heat">暖房をつける</button><button class="btn" data-w="toilet">トイレをつける</button>
            <button class="btn" data-w="inspect">検査</button><button class="btn" data-w="renew">更新工事</button><button class="btn" data-move>転属</button><button class="btn" data-scrap>廃車</button><button class="btn" data-clear>えらびなおす</button></div>`
        : '<small class="muted">車両をタップしてえらぶと、編成・改造・検査・転属・廃車ができます。編成は、えらんだ順（先頭から）になります</small>'}</div>
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
    if (st.stops.length && st.stops[st.stops.length - 1].id === h.s.id) return;
    st.stops.push({ id: h.s.id, n: h.s.n, x: h.s.fx, y: h.s.fy }); if (st.stops.length === 1 || st.stops.length === 2) st.timing.add(h.s.id); draw();
  };
  S.drawTool = (g, z) => {
    g.strokeStyle = st.color; g.lineWidth = 3; g.setLineDash([8, 6]); g.beginPath();
    let k = 0; for (const s of st.stops) { const it = S.vis && S.vis.stas.get(s.id); const x = it ? it.fx : s.x, y = it ? it.fy : s.y; if (x == null) continue; if (k++) g.lineTo(sx(x), sy(y)); else g.moveTo(sx(x), sy(y)); } g.stroke(); g.setLineDash([]);
  };
  S.toolEnd = () => { S.tapHook = null; };
  const draw = () => {
    sheet(`<h4>${edit ? '系統を直す' : kind === 'rail' ? '鉄道の系統をつくる' : 'バスの系統をつくる'}</h4>
      <div class="mp-row"><input class="mp-inp" style="flex:1 1 150px" data-nm placeholder="系統の名前（例：瑠璃本線）" value="${esc(st.name)}"><input type="color" data-col value="${esc(st.color)}" style="width:44px;height:36px;border:0;background:none"></div>
      <div class="mp-list">${st.stops.map((s, i) => `<div class="mp-item" style="display:flex;align-items:center;gap:6px"><b>${i + 1}.</b> ${esc(s.n)}
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
        if (r) { toast(edit ? '直しました' : '系統をつくりました。列車を入れましょう'); setTool('look'); openDia(r.id); }
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
const KIND_COL = { 普通: '#222', 各停: '#222', 快速: '#e07020', 急行: '#d42', 特急: '#c0186a', 回送: '#999' };
const kindL = k => k === '普通' ? '各停' : k;   // 種別の見せ方（データは「普通」のまま）
async function openDia(rid) {
  const m = modal(['系統', '<p class="muted small">読みこんでいます…</p>'], null, 'mp-wide');
  let D = null, tab = 'dia';
  const load = async () => { D = await api('mp_dia', { p_route: rid }); if (!D) return m.close(); S.routeHi = { legs: D.legs, color: D.color }; S.dirty = true; draw(); };
  m.onclose = () => { S.routeHi = null; S.dirty = true; };
  const draw = () => {
    const idx = new Map(D.stops.map((s, i) => [s.id, i]));
    m.set(D.name, `<p class="small" style="margin:0"><b style="color:${esc(D.color)}">■</b> <span>${D.kind === 'rail' ? '鉄道' : 'バス'}</span>・<span>${esc(D.owner)}</span>・<span>${D.km[D.km.length - 1]}km・停車 ${D.dwell}秒</span>
        ${D.ok ? '' : `<br><span class="mp-warn"><span>走れません：</span> <span>${esc(D.why || '')}</span></span>`}${D.last && D.last.revenue != null ? `<br>さいきんの1時間：${fmt(D.last.served || 0)}人・${X(D.last.revenue || 0)}・${D.last.tph}本・混み具合${D.last.load}%・平均${D.last.speed}km/h` : ''}</p>
      <div class="tabs-s" style="margin-top:8px">${[['dia', 'ダイヤグラム'], ['tt1', '時刻表（下り）'], ['tt2', '時刻表（上り）'], ['list', '列車']].map(t => `<button data-tab="${t[0]}" class="${tab === t[0] ? 'on' : ''}">${t[1]}</button>`).join('')}</div>
      <div data-pane style="margin-top:8px"></div>
      ${D.mine ? `<div class="mp-row"><button class="btn main" data-add>＋ 列車</button><button class="btn" data-bulk>＋ まとめて</button><button class="btn" data-auto>運用を自動で組む</button>
        <button class="btn" data-edit>駅の順を直す</button><button class="btn" data-del>系統を消す</button></div>` : ''}`, b => {
      b.querySelectorAll('[data-tab]').forEach(x => x.onclick = () => { tab = x.dataset.tab; draw(); });
      const pane = b.querySelector('[data-pane]');
      if (tab === 'dia') diaCanvas(pane, D, t => trainEdit(D, t, load));
      if (tab === 'tt1' || tab === 'tt2') pane.innerHTML = ttTable(D, tab === 'tt1' ? 1 : -1, idx);
      if (tab === 'list') {
        pane.innerHTML = `<div class="mp-list">${D.trains.map(t => `<button class="mp-item" style="text-align:left" data-t="${t.id}"><b>${esc(t.num)}</b> <span>${esc(kindL(t.kind))}・${t.dir === 1 ? '下り' : '上り'}・${hms(t.dep)}発</span>・${t.fname ? `<span>${esc(t.fname)}</span>` : '<span class="mp-warn">編成なし</span>'}${t.warn ? `<br><small class="mp-warn">${warnH(t.warn)}</small>` : ''}</button>`).join('') || '<p class="muted small">列車はまだありません</p>'}</div>`;
        pane.querySelectorAll('[data-t]').forEach(x => x.onclick = () => trainEdit(D, D.trains.find(t => t.id === Number(x.dataset.t)), load));
      }
      const q = k => b.querySelector(k);
      if (q('[data-add]')) q('[data-add]').onclick = () => trainEdit(D, null, load);
      if (q('[data-bulk]')) q('[data-bulk]').onclick = () => trainBulk(D, load);
      if (q('[data-auto]')) q('[data-auto]').onclick = () => autoForm(D, load);
      if (q('[data-edit]')) q('[data-edit]').onclick = () => { m.close(); routeBuild(D.kind, D); };
      if (q('[data-del]')) q('[data-del]').onclick = async () => { if (confirm(T('この系統と、列車をぜんぶ消しますか？')) && await api('mp_route_del', { p_id: D.id, p_as: S.as }, '消しました')) m.close(); };
    });
  };
  load();
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
  return `<div class="mp-scroll"><table class="mp-tt"><tr><th></th>${trs.map(t => `<th style="color:${KIND_COL[t.kind] || '#222'}">${esc(t.num)}<br>${esc(kindL(t.kind))}</th>`).join('')}</tr>
    ${ord.map(s => `<tr><td class="st">${esc(s.name)}${D.timing.includes(s.id) ? ' ◎' : ''}</td>${trs.map(t => `<td>${cell(t, s)}</td>`).join('')}</tr>`).join('')}
    <tr><td class="st">編成</td>${trs.map(t => `<td><small>${t.fname ? esc(t.fname) : '—'}</small></td>`).join('')}</tr></table></div><p class="muted small">◎ 採時駅（太字の時刻）・レ 通過</p>`;
}
// ダイヤグラム（よこ：時刻・たて：駅）。ドラッグでよこに動く・ピンチでよこに拡大
function diaCanvas(pane, D, onTrain) {
  pane.innerHTML = `<canvas class="mp-dia"></canvas><p class="muted small" style="margin:4px 0 0">よこにドラッグで動かす・2本指でよこに拡大・列車の線をタップで編集</p>`;
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
      const pts = [];
      for (const e of t.sched || []) { const k = km[idx.get(e[0])]; if (e[1] != null) pts.push([X(e[1]), Y(k)]); if (e[2] != null) pts.push([X(e[2]), Y(k)]); }
      if (pts.length < 2) continue;
      g.strokeStyle = t.form && !t.warn ? (KIND_COL[t.kind] || '#222') : t.form ? '#d23' : '#aaa'; g.lineWidth = 1.4; g.setLineDash(t.form ? [] : [4, 3]);
      g.beginPath(); pts.forEach((p, i) => i ? g.lineTo(p[0], p[1]) : g.moveTo(p[0], p[1])); g.stroke(); g.setLineDash([]);
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
async function trainEdit(D, t, reload) {
  if (!D.mine) return;
  const cl = await api('mp_cars_list', { p_as: S.as }); if (!cl) return;
  const forms = cl.forms.filter(f => f.perf && f.perf.rail === (D.kind === 'rail'));
  const tm = D.stops.filter(s => D.timing.includes(s.id));
  const st = t ? { ...t, tt: { ...(t.tt || {}) }, skip: new Set(t.skip || []) } : { dir: 1, num: '', kind: D.kind === 'rail' ? '普通' : '', dep: 7 * 3600, form: forms.length ? forms[0].id : null, tt: {}, skip: new Set() };
  const m = modal([t ? `列車 ${t.num}` : '列車をつくる', '']);
  const draw = () => {
    const ord = st.dir === 1 ? D.stops : D.stops.slice().reverse();
    m.set(t ? `列車 ${t.num}` : '列車をつくる', `
      <div class="mp-row"><input class="mp-inp" style="flex:1 1 90px" data-num placeholder="列車番号" value="${esc(st.num)}">
        <select class="mp-inp" style="flex:1 1 90px" data-kind>${['普通', '快速', '急行', '特急', '回送'].map(k => `<option value="${k}" ${st.kind === k ? 'selected' : ''}>${kindL(k)}</option>`).join('')}</select>
        <span class="mp-seg"><button data-dir="1" class="${st.dir === 1 ? 'on' : ''}">下り</button><button data-dir="-1" class="${st.dir === -1 ? 'on' : ''}">上り</button></span></div>
      <div class="mp-row">始発（${esc(ord[0].name)}）の発車 <input class="mp-inp mp-num" data-dep value="${hms(st.dep)}"></div>
      <div class="mp-row">編成 <select class="mp-inp" style="flex:1" data-form><option value="">（決めない）</option>${forms.map(f => `<option value="${f.id}" ${st.form === f.id ? 'selected' : ''}>${esc(f.name)}（${f.perf.n}両・${f.perf.len}m）</option>`).join('')}</select></div>
      <h4 style="margin:10px 0 4px">採時駅の時刻・番線</h4>
      ${tm.map(s => { const v = st.tt[s.id] || {}; return `<div class="mp-row"><b style="min-width:5em">${esc(s.name)}</b>到着<input class="mp-inp mp-num" data-a="${s.id}" value="${v.a != null ? hms(v.a) : ''}" placeholder="—">
          発車<input class="mp-inp mp-num" data-d="${s.id}" value="${v.d != null ? hms(v.d) : ''}" placeholder="—">
          <select class="mp-inp" style="width:auto" data-tr="${s.id}"><option value="">番線</option>${Array.from({ length: s.tracks }, (_, i) => `<option ${v.t === i + 1 ? 'selected' : ''} value="${i + 1}">${i + 1}番線</option>`).join('')}</select></div>`; }).join('')}
      <p class="muted small">空のところは、走る時間から自動で決まります（いちばん早い時刻）。遅くするときだけ入れます</p>
      ${ord.length > 2 ? `<h4 style="margin:10px 0 4px">止まる駅</h4><div class="mp-cars">${ord.slice(1, -1).map(s => `<span class="mp-car ${st.skip.has(s.id) ? '' : 'on'}" data-sk="${s.id}">${esc(s.name)}<span class="n">${st.skip.has(s.id) ? '通過' : '停車'}</span></span>`).join('')}</div>` : ''}
      ${t && t.warn ? `<p class="mp-warn">${warnH(t.warn)}</p>` : ''}
      <div class="mp-row">${t ? '<button class="btn" data-del>消す</button>' : ''}<button class="btn main" data-ok>${t ? '保存' : 'つくる'}</button></div>`, b => {
      const q = k => b.querySelector(k);
      const keep = () => {
        st.num = q('[data-num]').value; st.kind = q('[data-kind]').value; st.dep = parseHM(q('[data-dep]').value) ?? st.dep; st.form = q('[data-form]').value ? Number(q('[data-form]').value) : null;
        for (const s of tm) { const a = parseHM(q(`[data-a="${s.id}"]`).value), d = parseHM(q(`[data-d="${s.id}"]`).value), r = q(`[data-tr="${s.id}"]`).value;
          const o = {}; if (a != null) o.a = a; if (d != null) o.d = d; if (r) o.t = Number(r); if (Object.keys(o).length) st.tt[s.id] = o; else delete st.tt[s.id]; }
      };
      b.querySelectorAll('[data-dir]').forEach(x => x.onclick = () => { keep(); st.dir = Number(x.dataset.dir); draw(); });
      b.querySelectorAll('[data-sk]').forEach(x => x.onclick = () => { keep(); const id = Number(x.dataset.sk); if (st.skip.has(id)) st.skip.delete(id); else st.skip.add(id); draw(); });
      if (q('[data-del]')) q('[data-del]').onclick = async () => { if (await api('mp_train_del', { p_ids: [t.id], p_as: S.as }, '消しました')) { m.close(); reload(); } };
      q('[data-ok]').onclick = async () => {
        keep(); if (!st.num.trim()) return toast('列車番号を入れてください');
        const r = await api('mp_train_save', { p_id: t ? t.id : null, p_route: D.id, p_dir: st.dir, p_num: st.num, p_kind: st.kind, p_dep: st.dep, p_form: st.form, p_tt: st.tt, p_skip: [...st.skip], p_as: S.as });
        if (r) { toast(r.warn ? '保存しました（注意があります）' : '保存しました'); m.close(); reload(); }
      };
    });
  };
  draw();
}
function trainBulk(D, reload) {
  const m = modal(['まとめて列車をつくる', `
    <div class="mp-row"><span class="mp-seg"><button data-dir="1" class="on">下り</button><button data-dir="-1">上り</button></span>
      <select class="mp-inp" style="width:auto" data-kind>${['普通', '快速', '急行', '特急'].map(k => `<option value="${k}">${kindL(k)}</option>`).join('')}</select></div>
    <div class="mp-row"><label class="small">はじめの列車 <input class="mp-inp mp-num" data-from value="06:00"></label> <label class="small">さいごの列車 <input class="mp-inp mp-num" data-to value="23:00"></label> <label class="small">何分おき <input class="mp-inp mp-num" type="number" data-ev value="10" min="2" max="240"></label></div>
    <div class="mp-row"><input class="mp-inp" data-pre placeholder="列車番号の頭（例：A。なくてもよい）"></div>
    <div class="mp-row"><button class="btn main" data-ok>つくる</button></div>
    <p class="muted small">編成はあとで「運用を自動で組む」でわりあてられます</p>`], b => {
    let dir = 1;
    b.querySelectorAll('[data-dir]').forEach(x => x.onclick = () => { dir = Number(x.dataset.dir); b.querySelectorAll('[data-dir]').forEach(y => y.classList.toggle('on', y === x)); });
    b.querySelector('[data-ok]').onclick = async () => {
      const r = await api('mp_train_bulk', { p_route: D.id, p_dir: dir, p_from: parseHM(b.querySelector('[data-from]').value), p_to: parseHM(b.querySelector('[data-to]').value),
        p_every: Number(b.querySelector('[data-ev]').value), p_kind: b.querySelector('[data-kind]').value, p_prefix: b.querySelector('[data-pre]').value, p_form: null, p_as: S.as });
      if (r) { toast(`${r.n}本つくりました`); m.close(); reload(); }
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

/* ---- お金の記録 ---- */
const LK = { fare: '運賃', rent: '家賃', lease: '使用料（はらう）', lease_in: '使用料（受けとり）', upkeep: '維持費', tax: '固定資産税', land: '土地', bld: '建物', car: '車両', rail: '線路の工事', road: '道路の工事', sta: '駅', dep: '車庫', owed: '未払い' };
async function openLedger() {
  const m = modal(['お金の記録', '<p class="muted small">読みこんでいます…</p>']);
  let rows = [], before = null, head = null;
  const more = async () => {
    const d = await api('mp_ledger_page', { p_as: S.as, p_before: before }); if (!d) return;
    if (!head) head = d; rows = rows.concat(d.rows); before = d.rows.length ? d.rows[d.rows.length - 1].id : before;
    const day = head.day || {}, a = head.assets;
    m.set('お金の記録', `<p class="small" style="margin:0">${esc(asName())}</p>
      <div class="mp-kv"><b>土地</b><span>${a.land}マス（地価 ${X(a.land_val)}）</span><b>線路</b><span>${a.rail_km} km</span><b>駅・バス停</b><span>${a.stations}</span><b>車両</b><span>${a.cars}両（台）</span>
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
  m.set('国土の管理', `<div class="mp-kv"><b>チャンク</b><span>${fmt(st.chunks)}</span><b>道路・線路</b><span>${fmt(st.segs)}（国 ${fmt(st.gov_segs)}・線路 ${fmt(st.rail_segs)}）</span><b>土地</b><span>${fmt(st.land)}マス</span>
      <b>駅</b><span>${fmt(st.stations)}</span><b>車両</b><span>${fmt(st.cars)}</span><b>系統・列車</b><span>${fmt(st.routes)}・${fmt(st.trains)}</span><b>時計</b><span>${st.last_tick ? new Date(st.last_tick).toLocaleString('ja-JP') : '—'}</span>
      <b>未払いの合計</b><span>${X(st.owed)}</span></div>
    <h4 style="margin:10px 0 4px">この24時間（ぜんぶ）</h4><div class="mp-kv">${Object.entries(st.day || {}).map(([k, v]) => `<b>${esc(LK[k] || k)}</b><span>${fmt(v)} X</span>`).join('')}</div>
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
  });
}
function zonePaint(z) {
  setTool('land');
  hint(`用途地域（${z ? PAL.ZN[z] || 'なし' : 'もとにもどす'}）：2か所タップして四角くえらびます`);
  const tap0 = S.tapHook;
  S.tapHook = (x, y) => {
    tap0(x, y);
    const st = S.toolState; if (!st || !st.b) return;
    const tiles = landTiles(); if (tiles.length / 2 > 2000) return sheet('<p class="mp-warn">2000マスまでです</p>');
    sheet(`<h4>${z ? `${tiles.length / 2}マスを「${PAL.ZN[z] || 'なし'}」に` : `${tiles.length / 2}マスを、もとの用途地域に`}</h4><div class="mp-row"><button class="btn main" data-ok>ぬる</button></div>`, s => {
      s.querySelector('[data-ok]').onclick = async () => {
        if (await api('mp_admin_zone', { p_tiles: tiles, p_z: z }, 'ぬりました')) {
          let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity; for (let i = 0; i < tiles.length; i += 2) { x0 = Math.min(x0, tiles[i]); y0 = Math.min(y0, tiles[i + 1]); x1 = Math.max(x1, tiles[i]); y1 = Math.max(y1, tiles[i + 1]); }
          for (let cy = Math.floor(y0 / CS); cy <= Math.floor(y1 / CS); cy++) for (let cx = Math.floor(x0 / CS); cx <= Math.floor(x1 / CS); cx++) S.chunks.delete(ckey(cx, cy));
          S.dirty = true; sheet(null);
        }
      };
    });
  };
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
window.MapApp = { open, pause, state: S, spline, setCam };
})();
