#!/usr/bin/env node
// AppIcon 的唯一几何事实源。用法：node icon.mjs <px> > out.svg
//
// 设计要点（改之前先读）：
//   · 容器是 superellipse n=7、body 824/1024 —— Apple 的图标模板规格，不是随意的圆角矩形。
//   · 主体是一本横格本（quaderno）：米色纸面 + 下沿书页厚度 + 一条竖向松紧带 + 左上角一个斜体 q。
//   · 纸面是 A 系 1:√2。比例即语义：这个 app 讲的就是按屏幕真实物理尺寸出版，纸一旦被拉伸，
//     这层意思就没了。
//   · 色彩结构「深底 + 浅纸 + 单点强调」（2026-10-26 方向 B1，10-31 细化为 B3）：
//       - 底是云杉青，斜向四段渐变 + 右下暗角 + 左上光晕；只用两色线性渐变时整体发平。
//       - 全图只有松紧带一处高饱和色（赭红，与云杉青近互补）。
//       - 投影色取底色的深青，不用纯黑，否则会把底色压脏。
//   · 松紧带是【扁平】的：基本平涂、上亮下暗，两边平行、整体顺一条缓 S 弧，右侧暗边表现厚度，
//     纵向淡织纹，贴身窄接触影。不要画成横向「暗-亮-暗」+ 中线高光——那是圆柱体，读成红管子；
//     也不要让两条边各自起伏——读成香肠（2026-10-31 实测）。
//   · 横线长短不一，像写了几段字；第一行让给 q。
//   · q 是 Times New Roman Italic 的字形轮廓（CoreText 取出，单位 1/1000 em），以路径内嵌，
//     不依赖目标机器装有该字体。
//
// macOS 26+ 的 Dock 只用 Assets.car（由 AppIcon.icon 编译），那条路径没有分档：Dock 尺寸就是
// 1024 图层直接缩小。所以细节必须在 1024 母版上就够粗，128px 下仍读得出（10-31 实测：36 宽的
// 松紧带在 128px 只剩一道红线）。下面的分档只作用于 macOS 14/15 读的 .icns。

import { pathToFileURL } from 'node:url';

const P = {
  bg: ['#4CBDAB', '#2A9488', '#1A6F6A', '#103F4C'],  // 底：斜向四段，尾端微偏蓝
  vignette: '#08283A', glow: '#E9FFF6',
  paper0: '#FDF9F2', paper1: '#E8DCC6',             // 纸面
  stack0: '#E0D3BB', stack1: '#C9B99D',             // 下沿书页厚度，由浅到深两层
  rule: '#CDBFA5', ink: '#1C3533',
  band0: '#D4583B', band1: '#B7422A',               // 松紧带：上亮下暗
  bandEdge: '#8A2B19', bandEdgeR: '#6E200F',         // 左细边 / 右厚边
  ribLight: '#EE8466', ribDark: '#9A3420',
  wrapTop: '#8E2D1B', wrapBottom: '#9C3520',        // 绕到背面 / 压在书页厚度上的两段
  shade: '#011F1D', bandShade: '#3A2410', outline: '#0B3431',
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

// ---- 几何（1024 坐标，824 容器居中）------------------------------------------
const PAGE = { x: 312, y: 214, w: 400, h: 566, r: 30 };   // 400 × 566 ≈ 1:√2
// 横线：[起, 止]；第一行从 q 之后起，三、六、七行半途收住。
const RULE_Y = [356, 415, 475, 534, 594, 653, 713];
const RULES = [[474, 672], [352, 672], [352, 584], [352, 672], [352, 672], [352, 556], [352, 468]];
// Times New Roman Italic「q」，1/1000 em，基线 y=0。
const Q = 'M474.1 -441.9L314.5 109.9Q303.7 147.9 303.7 158.7Q303.7 169.9 309.3 178.0Q314.9 186.0 324.7 189.9Q339.8 195.8 364.3 195.8L359.4 213.9L125.5 213.9L130.4 195.8Q178.2 191.9 189.9 187.5Q208.5 180.2 220.5 163.6Q232.4 147.0 247.1 93.8L314.5 -147.0Q250.0 -52.7 194.3 -14.6Q154.8 12.2 120.6 12.2Q71.8 12.2 46.9 -27.6Q22.0 -67.4 22.0 -113.8Q22.0 -187.5 67.4 -268.6Q112.8 -349.6 187.0 -401.4Q244.6 -441.9 291.5 -441.9Q326.2 -441.9 348.6 -425.0Q371.1 -408.2 382.3 -371.1L397.5 -425.8ZM362.8 -346.7Q362.8 -377.9 343.8 -397.9Q324.7 -418.0 296.9 -418.0Q237.3 -418.0 171.4 -315.4Q105.5 -212.9 105.5 -122.1Q105.5 -85.4 121.8 -66.4Q138.2 -47.4 161.6 -47.4Q191.4 -47.4 229.0 -80.6Q286.1 -130.9 324.5 -209.7Q362.8 -288.6 362.8 -346.7Z';
// 松紧带：宽 56，两边平行、顺一条缓 S 弧；纸面上沿 214 处折到背面，下沿压过书页厚度到 798。
const BAND_L = 'M602 210 C606 340 610 440 604 560 C598 680 600 740 605 798';
const BAND_R = 'M658 210 C662 340 666 440 660 560 C654 680 656 740 661 798';
const BAND = 'M602 210 C606 340 610 440 604 560 C598 680 600 740 605 798 L661 798 C656 740 654 680 660 560 C666 440 662 340 658 210 Z';
const RIBS = [
  ['M616 212 C620 340 624 440 618 560 C612 680 614 740 619 796', P.ribLight, 0.3],
  ['M630 212 C634 340 638 440 632 560 C626 680 628 740 633 796', P.ribDark, 0.2],
  ['M644 212 C648 340 652 440 646 560 C640 680 642 740 647 796', P.ribLight, 0.3],
];

// ---- 分档（只作用于 .icns）-----------------------------------------------------
// scale  放大本子：小尺寸下主体要占更多面积。
// rule   横线宽；rules 为 false 时不画线。q / ribs 是否画。
// bandX  松紧带横向加宽倍数（绕带子中线），否则 16/32 下不足一像素。
// shadow 本子投影强度（0 = 改用硬边接触影）。
const TIERS = [
  { at: 128, scale: 1.00, rules: true,  rule: 7,  q: true,  ribs: true,  bandX: 1.0, shadow: 1.0 },
  { at: 64,  scale: 1.04, rules: true,  rule: 11, q: true,  ribs: false, bandX: 1.2, shadow: 0.9 },
  { at: 32,  scale: 1.10, rules: true,  rule: 20, q: false, ribs: false, bandX: 1.6, shadow: 0 },
  { at: 0,   scale: 1.16, rules: false, rule: 0,  q: false, ribs: false, bandX: 2.0, shadow: 0 },
];
const tierFor = px => TIERS.find(t => px >= t.at);
const MASTER = TIERS[0];

const r2 = v => Math.round(v * 100) / 100;
const around = (s, inner) => s === 1 ? inner
  : `<g transform="translate(512 512) scale(${r2(s)}) translate(-512 -512)">${inner}</g>`;

// ---- 各部件 ------------------------------------------------------------------
const DEFS = {
  bg: `<linearGradient id="bg" x1="0.15" y1="0" x2="0.8" y2="1">${P.bg.map((c, i) =>
    `<stop offset="${[0, 0.35, 0.7, 1][i]}" stop-color="${c}"/>`).join('')}</linearGradient>`,
  vig: `<radialGradient id="vig" cx="0.9" cy="0.95" r="0.65"><stop offset="0" stop-color="${P.vignette}" stop-opacity="0.5"/><stop offset="1" stop-color="${P.vignette}" stop-opacity="0"/></radialGradient>`,
  glow: `<radialGradient id="glow" cx="0.22" cy="0.08" r="0.7"><stop offset="0" stop-color="${P.glow}" stop-opacity="0.28"/><stop offset="1" stop-color="${P.glow}" stop-opacity="0"/></radialGradient>`,
  paper: `<linearGradient id="paper" x1="0" y1="0" x2="0.45" y2="1"><stop offset="0" stop-color="${P.paper0}"/><stop offset="1" stop-color="${P.paper1}"/></linearGradient>`,
  band: `<linearGradient id="band" x1="0" y1="210" x2="0" y2="798" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="${P.band0}"/><stop offset="1" stop-color="${P.band1}"/></linearGradient>`,
  // 本子投影：大范围环境影 + 贴地接触影，只输出影子本身（本子由 page 另画）。
  sh: s => `<filter id="sh" x="-40%" y="-30%" width="180%" height="170%">
    <feGaussianBlur in="SourceAlpha" stdDeviation="34" result="b1"/><feOffset in="b1" dx="6" dy="42" result="o1"/>
    <feFlood flood-color="${P.shade}" flood-opacity="${r2(0.72 * s)}"/><feComposite in2="o1" operator="in" result="s1"/>
    <feGaussianBlur in="SourceAlpha" stdDeviation="8" result="b2"/><feOffset in="b2" dy="12" result="o2"/>
    <feFlood flood-color="${P.shade}" flood-opacity="${r2(0.5 * s)}"/><feComposite in2="o2" operator="in" result="s2"/>
    <feMerge><feMergeNode in="s1"/><feMergeNode in="s2"/></feMerge>
  </filter>`,
  bsh: `<filter id="bsh" x="-30%" y="-5%" width="160%" height="110%"><feGaussianBlur stdDeviation="5"/></filter>`,
};
const defs = (...items) => `<defs>${items.join('')}</defs>`;

// 底：渐变 + 暗角 + 光晕，各填一次容器形状。
const ground = shape => ['bg', 'vig', 'glow'].map(id => shape(`url(#${id})`)).join('\n');

function notebookShadow(t) {
  if (t.shadow > 0)
    return `<rect x="${PAGE.x}" y="${PAGE.y}" width="${PAGE.w}" height="${PAGE.h + 14}" rx="${PAGE.r}" fill="#000" filter="url(#sh)"/>`;
  // 小档不挂模糊，用一块下移的硬边影把纸从底上托起。
  return `<rect x="${PAGE.x}" y="${PAGE.y + 24}" width="${PAGE.w}" height="${PAGE.h + 14}" rx="${PAGE.r}" fill="${P.shade}" opacity="0.45"/>`;
}

function page(t) {
  const { x, y, w, h, r } = PAGE;
  const rules = t.rules
    ? `<g stroke="${P.rule}" stroke-width="${t.rule}" stroke-linecap="round">${RULES.map(([a, b], i) =>
        `<line x1="${a}" y1="${RULE_Y[i]}" x2="${b}" y2="${RULE_Y[i]}"/>`).join('')}</g>`
    : '';
  const q = t.q ? `<path transform="translate(350 356) scale(0.2)" d="${Q}" fill="${P.ink}"/>` : '';
  return `<rect x="${x}" y="${y + 14}" width="${w}" height="${h}" rx="${r}" fill="${P.stack1}"/>
<rect x="${x}" y="${y + 7}" width="${w}" height="${h}" rx="${r}" fill="${P.stack0}"/>
<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="${r}" fill="url(#paper)"/>
${rules}
${q}`;
}

// 松紧带横向加宽：绕中线 x=632 缩放。
const widen = (t, inner) => t.bandX === 1 ? inner
  : `<g transform="translate(632 0) scale(${t.bandX} 1) translate(-632 0)">${inner}</g>`;

const bandShadow = t => widen(t, `<path d="${BAND}" transform="translate(6 8)" fill="${P.bandShade}" opacity="0.4" filter="url(#bsh)"/>`);

function band(t) {
  const ribs = t.ribs
    ? `<g fill="none" stroke-width="3">${RIBS.map(([d, c, o]) => `<path d="${d}" stroke="${c}" opacity="${o}"/>`).join('')}</g>`
    : '';
  return widen(t, `<path d="${BAND}" fill="url(#band)"/>
${ribs}
<path d="${BAND_L}" fill="none" stroke="${P.bandEdge}" stroke-width="4" opacity="0.7"/>
<path d="${BAND_R}" fill="none" stroke="${P.bandEdgeR}" stroke-width="7" opacity="0.8"/>
<path d="M602 214 L604 202 Q631 197 657 201 L658 214 Z" fill="${P.wrapTop}"/>
<path d="M604 780 L660 780 L661 797 Q633 802 605 797 Z" fill="${P.wrapBottom}"/>`);
}

// ---- .icns：每档一张完整图 ----------------------------------------------------
export function svgFor(px) {
  const t = tierFor(px);
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${px}" height="${px}" viewBox="0 0 1024 1024">
${defs(DEFS.bg, DEFS.vig, DEFS.glow, DEFS.paper, DEFS.band, t.shadow > 0 ? DEFS.sh(t.shadow) : '', DEFS.bsh)}
${ground(fill => `<path d="${SQ}" fill="${fill}"/>`)}
${around(t.scale, `${notebookShadow(t)}
${page(t)}
${bandShadow(t)}
${band(t)}`)}
<path d="${SQ}" fill="none" stroke="${P.outline}" stroke-opacity="${px < 64 ? 0.30 : 0.15}" stroke-width="${px < 64 ? 12 : 3}"/>
</svg>
`;
}

// ---- macOS 26+ 的 Icon Composer 格式（AppIcon.icon）---------------------------
// 系统只给老式 .icns 套一块灰色底板；要去掉它，必须提供 .icon 经 actool 编进 Assets.car。
// .icon 的画布是满版 1024，圆角容器由系统画，所以每层都按 1024/824 放大，使占比与 .icns 一致。
//
// Icon Composer 图层里的 SVG <filter> 不生效（2026-10-26 实测：系统 neutral 投影下，本子下方取样
// 与底色相同）。所以两层阴影由 build-icon.sh 光栅成带 alpha 的 PNG；group 的系统投影关掉。
// icon.json 的 fill 只能给两色线性渐变，四段底色 + 暗角 + 光晕也作为最底一层 SVG。
const K = 1024 / 824;
const fullBleed = body => `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
${body}
</svg>
`;
const scaled = inner => `<g transform="translate(512 512) scale(${r2(K * 1000) / 1000}) translate(-512 -512)">
${inner}
</g>`;

// 自上而下。kind = svg 直接入库；png 由 build-icon.sh 光栅化。
export const LAYERS = [
  { name: 'band',       kind: 'svg' },
  { name: 'bandshadow', kind: 'png' },
  { name: 'page',       kind: 'svg' },
  { name: 'shadow',     kind: 'png' },
  { name: 'ground',     kind: 'svg' },
];

export function layerSvg(name) {
  const t = MASTER;
  switch (name) {
    case 'ground':
      return fullBleed(`${defs(DEFS.bg, DEFS.vig, DEFS.glow)}
${scaled(ground(fill => `<rect x="100" y="100" width="824" height="824" fill="${fill}"/>`))}`);
    case 'shadow':
      return fullBleed(`${defs(DEFS.sh(t.shadow))}
${scaled(notebookShadow(t))}`);
    case 'page':
      return fullBleed(`${defs(DEFS.paper)}
${scaled(page(t))}`);
    case 'bandshadow':
      return fullBleed(`${defs(DEFS.bsh)}
${scaled(bandShadow(t))}`);
    case 'band':
      return fullBleed(`${defs(DEFS.band)}
${scaled(band(t))}`);
    default:
      throw new Error(`未知图层: ${name}`);
  }
}

const srgb = hex => 'srgb:' + [1, 3, 5].map(i => (parseInt(hex.slice(i, i + 2), 16) / 255).toFixed(5)).join(',') + ',1.00000';
export function iconJson() {
  return JSON.stringify({
    // ground 图层盖满画布；fill 只是它加载前 / 被系统忽略时的兜底。
    fill: { 'linear-gradient': [srgb(P.bg[1]), srgb(P.bg[3])] },
    groups: [{
      layers: LAYERS.map(({ name, kind }) => ({ 'image-name': `${name}.${kind}`, name, glass: false })),
      shadow: { kind: 'none', opacity: 0 },
      translucency: { enabled: false, value: 0.5 },
    }],
    'supported-platforms': { squares: ['macOS'] },
  }, null, 2) + '\n';
}

// 用 pathToFileURL 比较：手拼 `file://${path}` 不做百分号编码，仓库路径含中文（如「归档」）时永不相等，
// 脚本静默输出空串，下游渲染出空白 PNG。
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [arg, name] = process.argv.slice(2);
  if (arg === '--layers') { process.stdout.write(LAYERS.map(l => `${l.name} ${l.kind}`).join('\n') + '\n'); process.exit(0); }
  if (arg === '--layer') { process.stdout.write(layerSvg(name)); process.exit(0); }
  if (arg === '--icon-json') { process.stdout.write(iconJson()); process.exit(0); }
  const px = Number(arg || 1024);
  if (!Number.isFinite(px) || px < 8) { console.error('用法: node icon.mjs <px> | --layer <name> | --layers | --icon-json'); process.exit(1); }
  process.stdout.write(svgFor(px));
}
