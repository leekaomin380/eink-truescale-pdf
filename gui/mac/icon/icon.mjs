#!/usr/bin/env node
// AppIcon 的唯一几何事实源。用法：node icon.mjs <px> > out.svg
//
// 设计要点（改之前先读）：
//   · 容器是 superellipse n=7、body 824/1024 —— Apple 的图标模板规格，不是随意的圆角矩形。
//   · 主体是一本横格本（quaderno）：米色纸面 + 下沿书页厚度 + 一条竖向松紧带。不画封皮、不画字。
//   · 纸面是 A 系 1:√2。比例即语义：这个 app 讲的就是按屏幕真实物理尺寸出版，纸一旦被拉伸，
//     这层意思就没了。
//   · 色彩结构「深底 + 浅纸 + 单点强调」（2026-10-26 定稿，方向 B1）：
//       - 底是云杉青，明度压低、色相偏蓝绿、渐变为同色相上浅下深。上一版浅灰青底与白机身
//         明度挤在一起，整体发软；偏黄的墨绿则显浑。
//       - 全图只有松紧带一处高饱和色（赭红，与云杉青近互补），其余大面积保持低彩度。
//       - 投影色取底色的深青，不用纯黑，否则会把底色压脏。
//
// 分档：大档有双层投影 + 横格线，小档去线、加宽松紧带。16/32 是重排过的，不是缩放。

import { pathToFileURL } from 'node:url';

const P = {
  ground0: '#23817A', ground1: '#155E5A',   // 底：云杉青，上浅下深
  paper0: '#F8F3EA', paper1: '#EEE6D7',     // 纸面
  stack0: '#E7DECD', stack1: '#D6CAB4',     // 下沿书页厚度，由浅到深两层
  rule: '#D5CAB6', crease: '#CDBFA8',       // 横格线 / 松紧带在纸面上的接触影
  band0: '#BE4A31', band1: '#DA6043', band2: '#B5452D', // 松紧带，横向三段表现圆柱感
  shade: '#022A27', outline: '#0B3431',
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
// scale   放大本子：小尺寸下主体要占更多面积，否则轮廓吃不住。
// rules   横格线条数；rule 线宽（1024 坐标）。小档减线加粗，16px 去线。
// band    松紧带宽；小档加宽，否则在 16px 下不足一像素、强调色消失。
// shadow  双层投影强度（0 = 只用一块硬边接触影）；glow 底板顶部的白色径向光。
const TIERS = [
  { at: 128, scale: 1.00, rules: 8, rule: 5,  band: 36, shadow: 1.00, glow: 0.10 },
  { at: 64,  scale: 1.04, rules: 6, rule: 9,  band: 44, shadow: 0.80, glow: 0.08 },
  { at: 32,  scale: 1.10, rules: 4, rule: 18, band: 70, shadow: 0,    glow: 0 },
  { at: 0,   scale: 1.16, rules: 0, rule: 0,  band: 100, shadow: 0,   glow: 0 },
];
const tierFor = px => TIERS.find(t => px >= t.at);

const r1 = v => Math.round(v * 10) / 10;

// 本子，1024 坐标、以 (512,512) 为中心、视觉中心略上移给投影留位。
// groupAttrs 由调用方决定是否挂投影 filter。
function notebook(t, groupAttrs = '') {
  const W = 390 * t.scale, H = W * Math.SQRT2;
  const X = 512 - W / 2, Y = 512 - H / 2 - 8 * t.scale;
  const R = 28 * t.scale, s = t.scale;

  // 横格：左右内缩纸宽 10.4% / 9.4%，从纸高 16.7% 起排到 87.7%。
  const rules = t.rules > 0 ? Array.from({ length: t.rules }, (_, i) => {
    const y = Y + H * (0.167 + (t.rules > 1 ? i * 0.71 / (t.rules - 1) : 0));
    return `<line x1="${r1(X + 0.104 * W)}" y1="${r1(y)}" x2="${r1(X + 0.906 * W)}" y2="${r1(y)}"/>`;
  }).join('') : '';

  // 松紧带：中线在纸宽 82% 处，上下各探出 8，读作绕过本子边缘。
  const BW = t.band * s, BX = X + 0.82 * W - BW / 2, over = 8 * s;
  // 硬边接触影：只在不挂 filter 的小档出现，代替模糊投影把纸从底上托起。
  const contact = t.shadow > 0 ? ''
    : `<rect x="${r1(X)}" y="${r1(Y + 18 * s)}" width="${r1(W)}" height="${r1(H)}" rx="${r1(R)}" fill="${P.shade}" opacity="0.45"/>`;

  return `<g${groupAttrs}>
  ${contact}
  <rect x="${r1(X)}" y="${r1(Y + 10 * s)}" width="${r1(W)}" height="${r1(H)}" rx="${r1(R)}" fill="${P.stack1}"/>
  <rect x="${r1(X)}" y="${r1(Y + 5 * s)}" width="${r1(W)}" height="${r1(H)}" rx="${r1(R)}" fill="${P.stack0}"/>
  <rect x="${r1(X)}" y="${r1(Y)}" width="${r1(W)}" height="${r1(H)}" rx="${r1(R)}" fill="url(#paper)"/>
  ${rules ? `<g stroke="${P.rule}" stroke-width="${r1(t.rule * s)}" stroke-linecap="round">${rules}</g>` : ''}
  <rect x="${r1(BX - 6 * s)}" y="${r1(Y)}" width="${r1(10 * s)}" height="${r1(H)}" fill="${P.crease}" opacity="0.7"/>
  <rect x="${r1(BX)}" y="${r1(Y - over)}" width="${r1(BW)}" height="${r1(H + 2 * over)}" rx="${r1(4 * s)}" fill="url(#band)"/>
</g>`;
}

function defs(t) {
  const glow = t.glow > 0
    ? `<radialGradient id="glow" cx="0.5" cy="0.12" r="0.8"><stop offset="0" stop-color="#FFFFFF" stop-opacity="${t.glow}"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/></radialGradient>`
    : '';
  // 双层投影：大范围环境影 + 贴地接触影。
  const shadow = t.shadow > 0
    ? `<filter id="sh" x="-35%" y="-25%" width="170%" height="160%">
    <feGaussianBlur in="SourceAlpha" stdDeviation="28" result="b1"/><feOffset in="b1" dy="30" result="o1"/>
    <feFlood flood-color="${P.shade}" flood-opacity="${r1(0.75 * t.shadow * 100) / 100}"/><feComposite in2="o1" operator="in" result="s1"/>
    <feGaussianBlur in="SourceAlpha" stdDeviation="6" result="b2"/><feOffset in="b2" dy="8" result="o2"/>
    <feFlood flood-color="${P.shade}" flood-opacity="${r1(0.45 * t.shadow * 100) / 100}"/><feComposite in2="o2" operator="in" result="s2"/>
    <feMerge><feMergeNode in="s1"/><feMergeNode in="s2"/><feMergeNode in="SourceGraphic"/></feMerge>
  </filter>`
    : '';
  return `<defs>
  <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${P.ground0}"/><stop offset="1" stop-color="${P.ground1}"/></linearGradient>
  <linearGradient id="paper" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${P.paper0}"/><stop offset="1" stop-color="${P.paper1}"/></linearGradient>
  <linearGradient id="band" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="${P.band0}"/><stop offset="0.45" stop-color="${P.band1}"/><stop offset="1" stop-color="${P.band2}"/></linearGradient>
  ${glow}
  ${shadow}
</defs>`;
}

export function svgFor(px) {
  const t = tierFor(px);
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${px}" height="${px}" viewBox="0 0 1024 1024">
${defs(t)}
<path d="${SQ}" fill="url(#bg)"/>
${t.glow > 0 ? `<path d="${SQ}" fill="url(#glow)"/>` : ''}
${notebook(t, t.shadow > 0 ? ' filter="url(#sh)"' : '')}
<path d="${SQ}" fill="none" stroke="${P.outline}" stroke-opacity="${px < 64 ? 0.30 : 0.15}" stroke-width="${px < 64 ? 12 : 3}"/>
</svg>
`;
}

// ---- macOS 26+ 的 Icon Composer 格式（AppIcon.icon）---------------------------
// 系统只给老式 .icns 套一块灰色底板（「不合规图标」的待遇）；要去掉它，必须提供 .icon
// 经 actool 编进 Assets.car。.icon 的画布是满版 1024：圆角容器由系统画、底色由 icon.json
// 的 fill 给，所以图层里只有本子本身，按 1024/824 放大，使它在容器内的占比与 .icns 一致。
// 投影交给系统（group 的 shadow），图层内不画 filter。
export function layerSvg() {
  const k = 1024 / 824, t = { ...TIERS[0], shadow: 1, glow: 0 };
  return `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
${defs({ ...t, shadow: 0 })}
<g transform="translate(512 512) scale(${r1(k * 1000) / 1000}) translate(-512 -512)">
${notebook(t)}
</g>
</svg>
`;
}

const srgb = hex => 'srgb:' + [1, 3, 5].map(i => (parseInt(hex.slice(i, i + 2), 16) / 255).toFixed(5)).join(',') + ',1.00000';
export function iconJson() {
  return JSON.stringify({
    fill: { 'linear-gradient': [srgb(P.ground0), srgb(P.ground1)] },
    groups: [{
      layers: [{ 'image-name': 'device.svg', name: 'notebook', glass: false }],
      shadow: { kind: 'neutral', opacity: 0.45 },
      translucency: { enabled: false, value: 0.5 },
    }],
    'supported-platforms': { squares: ['macOS'] },
  }, null, 2) + '\n';
}

// 用 pathToFileURL 比较：手拼 `file://${path}` 不做百分号编码，仓库路径含中文（如「归档」）时永不相等，
// 脚本静默输出空串，下游渲染出空白 PNG。
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  if (process.argv[2] === '--layer') { process.stdout.write(layerSvg()); process.exit(0); }
  if (process.argv[2] === '--icon-json') { process.stdout.write(iconJson()); process.exit(0); }
  const px = Number(process.argv[2] || 1024);
  if (!Number.isFinite(px) || px < 8) { console.error('用法: node icon.mjs <px>'); process.exit(1); }
  process.stdout.write(svgFor(px));
}
