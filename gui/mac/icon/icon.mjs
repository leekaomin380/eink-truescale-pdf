#!/usr/bin/env node
// AppIcon 的唯一几何事实源。用法：node icon.mjs <px> > out.svg
//
// 设计要点（改之前先读）：
//   · 容器是 superellipse n=7、body 824/1024 —— Apple 的图标模板规格，不是随意的圆角矩形。
//   · 主体是一台电子纸设备：白色机身框 + 暖灰屏 + 三行字。不画按键、不画品牌字、不画状态栏。
//   · 屏是 A 系 1:√2。比例即语义：这个 app 讲的就是按屏幕真实物理尺寸出版，屏一旦被拉伸，
//     这层意思就没了。机身框不受此约束，只按屏外扩固定边宽。
//   · 少色：底 / 机身 / 屏 / 墨，四色封顶。深色只留给字，不给大面积。
//     上一版（深青渐变底 + 纸 + 标题 + 朱线 + 七行字 + 页外散词）被判定为颜色过重、元素过多。
//   · 底色不能再浅：#E8EFEC 一档在 Dock 尺寸下白机身与底几乎无对比（2026-09-24 实测），
//     现为中浅灰青，让白机身靠明度差分离。字行实墨，不加透明度。
//
// 分档：大档有投影，小档有轮廓。16/32 是重排过的，不是缩放。

const P = {
  ground0: '#AFC4BC', ground1: '#98B0A7',   // 底：中浅灰青，上亮下暗一档
  bezel: '#FFFFFF', screen: '#F1EEE6',      // 机身 / 电子纸屏
  ink: '#2B3634', outline: '#1F2A28',
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
// scale  放大设备：小尺寸下主体要占更多面积，否则轮廓吃不住。
// lines  每行 [左起比例, 右止比例]；小档减到两行，行高加粗，否则在 16px 下不足一像素。
// line   行高（1024 坐标）；outline 机身描边宽（0 = 不描，只靠投影分离）。
const L3 = [[0, 1], [0, 1], [0, 0.63]], L2 = [[0, 1], [0, 0.58]];
const TIERS = [
  { at: 128, scale: 1.00, bezel: 32, lines: L3, line: 30, lead: 64, outline: 0,  shadow: 0.12, ol: 0 },
  { at: 64,  scale: 1.04, bezel: 32, lines: L3, line: 38, lead: 76, outline: 5,  shadow: 0.14, ol: 0.14 },
  { at: 32,  scale: 1.10, bezel: 36, lines: L2, line: 60, lead: 110, outline: 12, shadow: 0,   ol: 0.22 },
  { at: 0,   scale: 1.16, bezel: 40, lines: L2, line: 84, lead: 140, outline: 24, shadow: 0,   ol: 0.30 },
];
const tierFor = px => TIERS.find(t => px >= t.at);

const r1 = v => Math.round(v * 10) / 10;

// 机身 + 屏 + 字，1024 坐标、以 (512,512) 为中心。bezelAttrs 由调用方决定投影 / 描边。
function device(t, bezelAttrs = '') {
  // 屏 1:√2，机身按固定边宽外扩；整体在容器里居中。
  const SW = 380 * t.scale, SH = SW * Math.SQRT2;
  const B = t.bezel * t.scale, BW = SW + 2 * B, BH = SH + 2 * B;
  const BX = 512 - BW / 2, BY = 512 - BH / 2, SX = BX + B, SY = BY + B;
  const bezelR = 40 * t.scale, screenR = 10 * t.scale;

  // 文字块：左右内缩屏宽的 12.6%，从屏高的 14.5% 处起排 —— 上重下空，像读到一半的页。
  const TX = SX + 0.126 * SW, TW = SW * (1 - 2 * 0.126), TY = SY + 0.145 * SH;
  const lead = t.lead * t.scale, lh = t.line * t.scale;
  const lines = t.lines.map(([a, b], i) =>
    `<rect x="${r1(TX + a * TW)}" y="${r1(TY + i * lead)}" width="${r1((b - a) * TW)}" height="${r1(lh)}" rx="${r1(lh / 2)}" fill="${P.ink}"/>`
  ).join('\n  ');
  return `<rect x="${r1(BX)}" y="${r1(BY)}" width="${r1(BW)}" height="${r1(BH)}" rx="${r1(bezelR)}" fill="${P.bezel}"${bezelAttrs}/>
<rect x="${r1(SX)}" y="${r1(SY)}" width="${r1(SW)}" height="${r1(SH)}" rx="${r1(screenR)}" fill="${P.screen}"/>
  ${lines}`;
}

export function svgFor(px) {
  const t = tierFor(px);
  const shadow = t.shadow > 0
    ? `<filter id="sh" x="-30%" y="-30%" width="160%" height="160%"><feDropShadow dx="0" dy="12" stdDeviation="16" flood-color="${P.outline}" flood-opacity="${t.shadow}"/></filter>`
    : '';
  const bezelAttrs = (t.shadow > 0 ? ' filter="url(#sh)"' : '')
    + (t.outline > 0 ? ` stroke="${P.outline}" stroke-opacity="${t.ol}" stroke-width="${t.outline}"` : '');

  return `<svg xmlns="http://www.w3.org/2000/svg" width="${px}" height="${px}" viewBox="0 0 1024 1024">
<defs>
  <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${P.ground0}"/><stop offset="1" stop-color="${P.ground1}"/></linearGradient>
  ${shadow}
</defs>
<path d="${SQ}" fill="url(#bg)"/>
${device(t, bezelAttrs)}
<path d="${SQ}" fill="none" stroke="${P.outline}" stroke-opacity="${px < 64 ? 0.18 : 0.10}" stroke-width="${px < 64 ? 12 : 3}"/>
</svg>
`;
}

// ---- macOS 26+ 的 Icon Composer 格式（AppIcon.icon）---------------------------
// 系统只给老式 .icns 套一块灰色底板（「不合规图标」的待遇）；要去掉它，必须提供 .icon
// 经 actool 编进 Assets.car。.icon 的画布是满版 1024：圆角容器由系统画、底色由 icon.json
// 的 fill 给，所以图层里只有设备本身，按 1024/824 放大，使它在容器内的占比与 .icns 一致。
// 投影交给系统（group 的 shadow），图层内不画 filter。
export function layerSvg() {
  const k = 1024 / 824;
  return `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<g transform="translate(512 512) scale(${r1(k * 1000) / 1000}) translate(-512 -512)">
${device(TIERS[0])}
</g>
</svg>
`;
}

const srgb = hex => 'srgb:' + [1, 3, 5].map(i => (parseInt(hex.slice(i, i + 2), 16) / 255).toFixed(5)).join(',') + ',1.00000';
export function iconJson() {
  return JSON.stringify({
    fill: { 'linear-gradient': [srgb(P.ground0), srgb(P.ground1)] },
    groups: [{
      layers: [{ 'image-name': 'device.svg', name: 'device', glass: false }],
      shadow: { kind: 'neutral', opacity: 0.35 },
      translucency: { enabled: false, value: 0.5 },
    }],
    'supported-platforms': { squares: ['macOS'] },
  }, null, 2) + '\n';
}

if (import.meta.url === `file://${process.argv[1]}`) {
  if (process.argv[2] === '--layer') { process.stdout.write(layerSvg()); process.exit(0); }
  if (process.argv[2] === '--icon-json') { process.stdout.write(iconJson()); process.exit(0); }
  const px = Number(process.argv[2] || 1024);
  if (!Number.isFinite(px) || px < 8) { console.error('用法: node icon.mjs <px>'); process.exit(1); }
  process.stdout.write(svgFor(px));
}
