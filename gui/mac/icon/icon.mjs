#!/usr/bin/env node
// AppIcon 的唯一几何事实源。用法：node icon.mjs <px> > out.svg
//
// 设计要点（改之前先读）：
//   · 容器是 superellipse n=7、body 824/1024 —— Apple 的图标模板规格，不是随意的圆角矩形。
//   · 纸是 A 系 1:√2。比例即语义：这个 app 讲的就是真实物理尺寸，纸一旦被拉伸或卷角，
//     这层意思就没了。所以不做卷角、翻页、撕边。
//   · 版心地脚 > 天头，文字块落在视觉中心而非几何中心。
//   · 页外是尚未成行的词（矢量的干脆），页内是排定的字（有印痕）。阈值是纸的左边界。
//   · 质感取向是「工艺」不是「材质」：双层影、纸的厚度、墨色不匀、亚像素的洇。
//     不做底噪肌理 —— 渲染器差异 + 小尺寸抖动脏点。
//
// 分档：大档有工艺，小档有轮廓。16/32 是重排过的，不是缩放。

const P = {
  a: '#527874', b: '#284341', lift: '#DCEFE8', liftOp: 0.20,
  sheet0: '#FBF7ED', sheet1: '#EFE7D6',
  ink: '#2A3B39', mark: '#F3ECDC', accent: '#C0472C',
  edge: '#FFFFFF', edgeOp: 0.14, shadow: 0.30,
};

// ---- superellipse n=7，824×824 居中于 1024 ----------------------------------
function squircle(n = 7, a = 412, cx = 512, cy = 512, SEG = 32) {
  const OFF = Math.PI / SEG, e = 2 / n;
  const pt = t => { const c = Math.cos(t), s = Math.sin(t);
    return [cx + Math.sign(c) * Math.abs(c) ** e * a, cy + Math.sign(s) * Math.abs(s) ** e * a]; };
  const dv = t => { const c = Math.cos(t), s = Math.sin(t);
    return [a * e * Math.abs(c) ** (e - 1) * -s, a * e * Math.abs(s) ** (e - 1) * c]; };
  const r = v => Math.round(v * 100) / 100;
  let d = '';
  for (let i = 0; i < SEG; i++) {
    const t0 = OFF + 2 * Math.PI * i / SEG, t1 = OFF + 2 * Math.PI * (i + 1) / SEG, h = (t1 - t0) / 3;
    const p0 = pt(t0), p1 = pt(t1), d0 = dv(t0), d1 = dv(t1);
    if (i === 0) d += `M${r(p0[0])} ${r(p0[1])}`;
    d += `C${r(p0[0] + h * d0[0])} ${r(p0[1] + h * d0[1])} ${r(p1[0] - h * d1[0])} ${r(p1[1] - h * d1[1])} ${r(p1[0])} ${r(p1[1])}`;
  }
  return d + 'Z';
}
const SQ = squircle();

// ---- 分档 -------------------------------------------------------------------
// scale 放大纸：小尺寸下纸要占更多面积，否则轮廓吃不住。
const TIERS = [
  { at: 512, scale: 1.00, rows: 7, inkH: 15, gap: 17, titleH: 26, ruleH: 5,
    flow: 1.00, blur: true,  jitter: true,  folio: true,  edge: true,  inkOp: 0.55, contact: 1.00 },
  { at: 256, scale: 1.00, rows: 7, inkH: 15, gap: 18, titleH: 26, ruleH: 6,
    flow: 1.00, blur: false, jitter: true,  folio: true,  edge: true,  inkOp: 0.56, contact: 1.05 },
  { at: 128, scale: 1.02, rows: 6, inkH: 17, gap: 21, titleH: 28, ruleH: 7,
    flow: 0.85, blur: false, jitter: true,  folio: false, edge: true,  inkOp: 0.58, contact: 1.12 },
  { at: 64,  scale: 1.06, rows: 5, inkH: 21, gap: 28, titleH: 30, ruleH: 9,
    flow: 0.42, blur: false, jitter: false, folio: false, edge: true,  inkOp: 0.62, contact: 1.25 },
  // 32 与 16 是重排，不是缩放：页外的词全部撤掉（小档读成锯齿），
  // 标题收窄或取消（否则并成一块墨），只保留「一张纸 + 几行字 + 一道朱线」。
  { at: 32,  scale: 1.10, rows: 3, inkH: 27, gap: 42, titleH: 33, ruleH: 12,
    flow: 0,    blur: false, jitter: false, folio: false, edge: true,  inkOp: 0.68, contact: 1.45 },
  { at: 0,   scale: 1.16, rows: 3, inkH: 31, gap: 54, titleH: 0,  ruleH: 30,
    flow: 0,    blur: false, jitter: false, folio: false, edge: false, inkOp: 0.74, contact: 1.70 },
];
const tierFor = px => TIERS.find(t => px >= t.at);

// ---- 版心几何 ---------------------------------------------------------------
function geom(scale) {
  const PW = Math.round(372 * scale), PH = Math.round(PW * Math.SQRT2);
  const PX = Math.round(512 - PW / 2), PY = Math.round(512 - PH / 2);
  return { PW, PH, PX, PY,
    BX: PX + 0.1237 * PW, BR: PX + PW - 0.1559 * PW,   // 切口 左 / 右
    BT: PY + 0.1141 * PH, BB: PY + PH - 0.1882 * PH }; // 天头 / 地脚（地脚更大）
}

const lcg = s0 => { let s = s0 >>> 0; return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296); };
const r1 = v => Math.round(v * 10) / 10;
const clamp = (v, a, b) => v < a ? a : v > b ? b : v;

export function svgFor(px) {
  const t = tierFor(px), g = geom(t.scale);
  const { PW, PH, PX, PY, BX, BR, BT, BB } = g;
  const ruleY = BT + 0.108 * PH;
  const body0 = BT + (t.titleH > 0 ? 0.181 : 0.181) * PH;
  const breakAt = t.rows >= 5 ? Math.ceil(t.rows * 0.57) : Infinity;
  const BRK = breakAt < t.rows ? 0.55 : 0;
  const lead = (BB - t.inkH / 2 - body0) / (t.rows - 1 + BRK);
  const rowY = i => body0 + i * lead + (i >= breakAt ? BRK * lead : 0);
  const ROWS = Array.from({ length: t.rows }, (_, i) => rowY(i));
  const blockW = BR - BX;

  const rnd = lcg(77002);
  const run = (x0, x1, y, h, op) =>
    `<rect x="${r1(x0)}" y="${r1(y - h / 2)}" width="${r1(x1 - x0)}" height="${r1(h)}" `
    + `rx="${r1(h * 0.35)}" fill="${P.ink}" opacity="${r1(op)}"/>`;

  // 标题：长短不一的词。小档只留一个，否则并成一团。
  let type = '';
  const tw = t.titleH === 0 ? [] : t.rows >= 5 ? [[0, .26], [.31, .47], [.53, .83]] : [[0, .44]];
  tw.forEach(([a, b]) => {
    type += run(BX + a * blockW, BX + b * blockW, BT + t.titleH / 2, t.titleH,
                t.jitter ? 0.84 + rnd() * 0.12 : 0.90);
  });

  // 正文：行末齐右；段首缩进两字；末行短。逐行上墨基数 + 逐词墨色抖动。
  ROWS.forEach((y, i) => {
    const last = i === ROWS.length - 1;
    const base = t.jitter ? 0.95 + rnd() * 0.13 : 1;
    const indent = (t.rows >= 5 && (i === 0 || i === breakAt)) ? t.inkH * 2.4 : 0;
    const xL = BX + indent, xE = last ? BX + blockW * 0.43 : BR;
    let x = xE;
    while (x > xL) {
      const w = t.inkH * 1.7 + rnd() * t.inkH * 4.1;
      const x0 = Math.max(xL, x - w);
      if (x - x0 > t.inkH * 0.6)
        type += run(x0, x, y, t.inkH,
          t.jitter ? Math.min(0.70, base * (t.inkOp * 0.87 + rnd() * 0.13)) : t.inkOp);
      x = x0 - t.gap;
    }
  });

  // 页外：尚未成行的词。矢量的干脆 —— 没落纸的还没被印。
  let flow = '';
  if (t.flow > 0) {
    const fr = lcg(20260904), X0 = 132, X1 = PX - 14;
    const rows = [ROWS[0] - lead * 1.9, ...ROWS, ROWS[ROWS.length - 1] + lead * 1.15];
    rows.forEach(y => {
      let x = X1;
      while (x > X0) {
        const u = clamp((x - X0) / (X1 - X0), 0, 1), e = u * u * (3 - 2 * u);
        const w = (t.inkH * 2.3 + fr() * t.inkH * 4.1) * (0.62 + 0.38 * e) * t.flow;
        const x0 = Math.max(X0, x - w), ww = x - x0;
        if (ww > t.inkH * 0.9) {
          const cx = (x0 + x) / 2, h = t.inkH * 1.07;
          const rot = r1((1 - e) * (fr() * 2 - 1) * 24);
          const dy = r1((1 - e) * (fr() * 2 - 1) * lead * 0.85);
          const yy = r1(y - h / 2 + dy);
          flow += `<rect x="${r1(x0)}" y="${yy}" width="${r1(ww)}" height="${r1(h)}" rx="${r1(h / 2)}" `
                + `fill="${P.mark}" opacity="${r1(0.06 + 0.42 * e)}" `
                + `transform="rotate(${rot} ${r1(cx)} ${r1(yy + h / 2)})"/>`;
        }
        x = x0 - (t.gap + (1 - u) * t.gap * 3.6);
      }
    });
  }

  const folio = t.folio
    ? `<rect x="${r1(PX + PW / 2 - 13)}" y="${r1(PY + PH - 52)}" width="26" height="9" rx="4.5" fill="${P.ink}" opacity=".30"/>`
    : '';
  const edge = t.edge
    ? `<rect x="${r1(PX + 1.5)}" y="${r1(PY + 1.5)}" width="${r1(PW - 3)}" height="${r1(PH - 3)}" rx="4" fill="none" stroke="url(#ed)" stroke-width="3"/>`
    : '';

  return `<svg xmlns="http://www.w3.org/2000/svg" width="${px}" height="${px}" viewBox="0 0 1024 1024">
<defs>
  <linearGradient id="bg" x1="0.1" y1="0" x2="0.9" y2="1"><stop offset="0" stop-color="${P.a}"/><stop offset="1" stop-color="${P.b}"/></linearGradient>
  <radialGradient id="lf" cx="0.24" cy="0.14" r="0.8"><stop offset="0" stop-color="${P.lift}" stop-opacity="${P.liftOp}"/><stop offset="1" stop-color="${P.lift}" stop-opacity="0"/></radialGradient>
  <linearGradient id="pg" x1="0.15" y1="0" x2="0.85" y2="1"><stop offset="0" stop-color="${P.sheet0}"/><stop offset="1" stop-color="${P.sheet1}"/></linearGradient>
  <linearGradient id="ed" x1="0.08" y1="0" x2="0.92" y2="1">
    <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.70"/><stop offset="0.42" stop-color="#FFFFFF" stop-opacity="0.16"/>
    <stop offset="0.58" stop-color="#000000" stop-opacity="0.05"/><stop offset="1" stop-color="#000000" stop-opacity="0.18"/></linearGradient>
  <filter id="amb" x="-40%" y="-40%" width="180%" height="180%"><feGaussianBlur stdDeviation="24"/></filter>
  <filter id="con" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="4.5"/></filter>
  ${t.blur ? `<filter id="ink" x="-3%" y="-3%" width="106%" height="106%"><feGaussianBlur stdDeviation="1.1"/></filter>` : ''}
  <clipPath id="cp"><path d="${SQ}"/></clipPath>
</defs>
<path d="${SQ}" fill="url(#bg)"/>
<path d="${SQ}" fill="url(#lf)"/>
<g clip-path="url(#cp)">
  ${flow}
  <rect x="${r1(PX + 8)}" y="${r1(PY + 22)}" width="${PW}" height="${PH}" rx="5" fill="#000000" opacity="${r1(P.shadow * 0.62)}" filter="url(#amb)"/>
  <rect x="${r1(PX + 2)}" y="${r1(PY + 5)}" width="${PW}" height="${PH}" rx="5" fill="#000000" opacity="${r1(P.shadow * 1.25 * t.contact)}" filter="url(#con)"/>
  <rect x="${PX}" y="${PY}" width="${PW}" height="${PH}" rx="5" fill="url(#pg)"/>
  ${edge}
  ${t.blur ? `<g filter="url(#ink)">${type}</g>` : type}
  <rect x="${r1(BX)}" y="${r1(ruleY)}" width="${r1(blockW)}" height="${t.ruleH}" fill="${P.accent}" opacity=".92"/>
  ${folio}
</g>
<path d="${SQ}" fill="none" stroke="${P.edge}" stroke-opacity="${P.edgeOp}" stroke-width="4"/>
</svg>
`;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const px = Number(process.argv[2] || 1024);
  if (!Number.isFinite(px) || px < 8) { console.error('用法: node icon.mjs <px>'); process.exit(1); }
  process.stdout.write(svgFor(px));
}
