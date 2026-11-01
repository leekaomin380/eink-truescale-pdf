#!/usr/bin/env node
// AppIcon 的唯一几何事实源。用法：node icon.mjs <px> > out.svg
//
// 设计要点（改之前先读）：
//   · 容器是 superellipse n=7、body 824/1024 —— Apple 的图标模板规格，不是随意的圆角矩形。
//   · 2026-11-01 起沿用作者另一个 App「阅读岛」（ReadIsland）的图标：浅灰底板 + 两张叠放的纸
//     （后页逆时针转 6°）。阅读岛纸面正中是大写 R；这里换成斜体小写 q，缩小后作为首字下沉放在
//     左上角，上三行横线从 q 右侧起排，其余照搬阅读岛。
//   · 只用灰阶和近黑（墨色 q）。上一版（云杉青底 + 赭红松紧带 + 米色纸）超过四种颜色，用户认为太吵。
//   · 几何取自阅读岛满版 1024 的坐标，按 824/1024 缩进模板：x' = 100 + 0.8047x。
//   · q 是 Times New Roman Italic 的字形轮廓（CoreText 取出，单位 1/1000 em），以路径内嵌，
//     不依赖目标机器装有该字体。
//
// macOS 26+ 的 Dock 只用 Assets.car（由 AppIcon.icon 编译），那条路径没有分档：Dock 尺寸就是
// 1024 图层直接缩小。所以细节必须在 1024 母版上就够粗，128px 下仍读得出。
// 下面的分档只作用于 macOS 14/15 读的 .icns。

import { pathToFileURL } from 'node:url';

const P = {
  bg0: '#EEF0F3', bg1: '#C9CCD3',                   // 底：上浅下深
  paper0: '#FFFFFF', paper1: '#F3F4F7',             // 前页
  back0: '#FBFBFD', back1: '#E7E9EE',               // 后页
  edge: '#14161E',                                  // 纸边描线（极低不透明度）
  rule: '#DCDEE3', ruleSoft: '#E2E4E9',             // 横线：q 旁 / 正文
  ink: '#16171A',
  shade: '#14161E', outline: '#000000',
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
const PAGE = { x: 242, y: 235, w: 541, h: 580, r: 32 };   // 阅读岛前页 672×720 @ (176,168)
const BACK = { w: 483, h: 580, r: 26, rot: -6 };          // 阅读岛后页 600×720，绕中心转 -6°
// 横线：[x, y, 宽, 高]。沿用阅读岛上三行的版式，行距不变，下方留白；
// 只是上三行从 q 右侧起排，右端仍对齐阅读岛的版心（x=731）。不要往中间加线：用户嫌乱。
const RULES_Q = [[430, 309, 301, 11], [430, 346, 200, 11], [430, 383, 251, 11]];
// 下方不画线：用户先后要求减少、再去掉，留白本身就是版式的一部分。
const RULES_BODY = [];
// Times New Roman Italic「q」，1/1000 em，基线 y=0；x 高 442，下伸 214。
const Q = 'M474.1 -441.9L314.5 109.9Q303.7 147.9 303.7 158.7Q303.7 169.9 309.3 178.0Q314.9 186.0 324.7 189.9Q339.8 195.8 364.3 195.8L359.4 213.9L125.5 213.9L130.4 195.8Q178.2 191.9 189.9 187.5Q208.5 180.2 220.5 163.6Q232.4 147.0 247.1 93.8L314.5 -147.0Q250.0 -52.7 194.3 -14.6Q154.8 12.2 120.6 12.2Q71.8 12.2 46.9 -27.6Q22.0 -67.4 22.0 -113.8Q22.0 -187.5 67.4 -268.6Q112.8 -349.6 187.0 -401.4Q244.6 -441.9 291.5 -441.9Q326.2 -441.9 348.6 -425.0Q371.1 -408.2 382.3 -371.1L397.5 -425.8ZM362.8 -346.7Q362.8 -377.9 343.8 -397.9Q324.7 -418.0 296.9 -418.0Q237.3 -418.0 171.4 -315.4Q105.5 -212.9 105.5 -122.1Q105.5 -85.4 121.8 -66.4Q138.2 -47.4 161.6 -47.4Q191.4 -47.4 229.0 -80.6Q286.1 -130.9 324.5 -209.7Q362.8 -288.6 362.8 -346.7Z';
// x 高从第一行顶（309）到第三行底附近：缩放 0.24 → x 高 106，基线 415。
const Q_AT = { x: 286, y: 415, s: 0.24 };

// ---- 分档（只作用于 .icns）-----------------------------------------------------
// scale  放大纸面：小尺寸下主体要占更多面积。
// rule   横线加粗倍数；body 为 false 时只留 q 旁三行。
// shadow 投影强度（0 = 改用硬边接触影）。
const TIERS = [
  { at: 128, scale: 1.00, rule: 1.0, body: true,  q: true,  shadow: 1.0 },
  { at: 64,  scale: 1.04, rule: 1.6, body: true,  q: true,  shadow: 1.0 },
  { at: 32,  scale: 1.08, rule: 2.4, body: true,  q: true,  shadow: 0 },
  { at: 0,   scale: 1.12, rule: 0,   body: false, q: true,  shadow: 0 },
];
const tierFor = px => TIERS.find(t => px >= t.at);
const MASTER = TIERS[0];

const r2 = v => Math.round(v * 100) / 100;
const around = (s, inner) => s === 1 ? inner
  : `<g transform="translate(512 512) scale(${r2(s)}) translate(-512 -512)">${inner}</g>`;

// ---- 各部件 ------------------------------------------------------------------
const grad = (id, a, b) => `<linearGradient id="${id}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${a}"/><stop offset="1" stop-color="${b}"/></linearGradient>`;
const DEFS = {
  bg: grad('bg', P.bg0, P.bg1),
  ring: `<linearGradient id="ring" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFFFFF" stop-opacity="0.3"/><stop offset="0.4" stop-color="#FFFFFF" stop-opacity="0"/></linearGradient>`,
  paper: grad('paper', P.paper0, P.paper1),
  back: grad('back', P.back0, P.back1),
  // 前页投影：贴身细影 + 大范围柔影，只输出影子本身。
  sh: s => `<filter id="sh" x="-20%" y="-20%" width="140%" height="145%">
    <feGaussianBlur in="SourceAlpha" stdDeviation="15" result="b1"/><feOffset in="b1" dy="13" result="o1"/>
    <feFlood flood-color="${P.shade}" flood-opacity="${r2(0.22 * s)}"/><feComposite in2="o1" operator="in" result="s1"/>
    <feGaussianBlur in="SourceAlpha" stdDeviation="2.5" result="b2"/><feOffset in="b2" dy="2" result="o2"/>
    <feFlood flood-color="${P.shade}" flood-opacity="${r2(0.18 * s)}"/><feComposite in2="o2" operator="in" result="s2"/>
    <feMerge><feMergeNode in="s1"/><feMergeNode in="s2"/></feMerge>
  </filter>`,
  bsh: s => `<filter id="bsh" x="-25%" y="-25%" width="150%" height="150%">
    <feGaussianBlur in="SourceAlpha" stdDeviation="11" result="b"/><feOffset in="b" dy="8" result="o"/>
    <feFlood flood-color="${P.shade}" flood-opacity="${r2(0.3 * s)}"/><feComposite in2="o" operator="in"/>
  </filter>`,
};
const defs = (...items) => `<defs>${items.join('')}</defs>`;

// 底：渐变 + 顶部高光，各填一次容器形状。
const ground = shape => ['bg', 'ring'].map(id => shape(`url(#${id})`)).join('\n');

const backRect = fill => `<g transform="translate(512 512) rotate(${BACK.rot}) translate(${-BACK.w / 2} ${-BACK.h / 2})">
<rect width="${BACK.w}" height="${BACK.h}" rx="${BACK.r}" ${fill}/></g>`;
const pageRect = fill => `<rect x="${PAGE.x}" y="${PAGE.y}" width="${PAGE.w}" height="${PAGE.h}" rx="${PAGE.r}" ${fill}/>`;

function shadows(t) {
  if (t.shadow > 0)
    return `${backRect('fill="#000" filter="url(#bsh)"')}\n${pageRect('fill="#000" filter="url(#sh)"')}`;
  // 小档不挂模糊，用一块下移的硬边影把纸从底上托起。
  return `<rect x="${PAGE.x}" y="${PAGE.y + 14}" width="${PAGE.w}" height="${PAGE.h}" rx="${PAGE.r}" fill="${P.shade}" opacity="0.18"/>`;
}

const back = () => backRect(`fill="url(#back)" stroke="${P.edge}" stroke-opacity="0.08" stroke-width="2"`);

function page(t) {
  const bar = ([x, y, w, h], k) => { const hh = h * k;
    return `<rect x="${x}" y="${r2(y + h / 2 - hh / 2)}" width="${w}" height="${r2(hh)}" rx="${r2(hh / 2)}"/>`; };
  const qRules = t.rule ? `<g fill="${P.rule}">${RULES_Q.map(r => bar(r, t.rule)).join('')}</g>` : '';
  const body = t.body && t.rule ? `<g fill="${P.ruleSoft}">${RULES_BODY.map(r => bar(r, t.rule)).join('')}</g>` : '';
  const q = t.q ? `<path transform="translate(${Q_AT.x} ${Q_AT.y}) scale(${Q_AT.s})" d="${Q}" fill="${P.ink}"/>` : '';
  return `${pageRect(`fill="url(#paper)" stroke="${P.edge}" stroke-opacity="0.09" stroke-width="2"`)}
${qRules}
${body}
${q}`;
}

// ---- .icns：每档一张完整图 ----------------------------------------------------
export function svgFor(px) {
  const t = tierFor(px);
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${px}" height="${px}" viewBox="0 0 1024 1024">
${defs(DEFS.bg, DEFS.ring, DEFS.paper, DEFS.back, t.shadow > 0 ? DEFS.sh(t.shadow) + DEFS.bsh(t.shadow) : '')}
${ground(fill => `<path d="${SQ}" fill="${fill}"/>`)}
${around(t.scale, `${shadows(t)}
${back()}
${page(t)}`)}
<path d="${SQ}" fill="none" stroke="${P.outline}" stroke-opacity="${px < 64 ? 0.16 : 0.07}" stroke-width="${px < 64 ? 12 : 3}"/>
</svg>
`;
}

// ---- macOS 26+ 的 Icon Composer 格式（AppIcon.icon）---------------------------
// 系统只给老式 .icns 套一块灰色底板；要去掉它，必须提供 .icon 经 actool 编进 Assets.car。
// .icon 的画布是满版 1024，圆角容器由系统画，所以每层都按 1024/824 放大，使占比与 .icns 一致。
//
// Icon Composer 图层里的 SVG <filter> 不生效（2026-10-26 实测）。所以阴影由 build-icon.sh
// 光栅成带 alpha 的 PNG；group 的系统投影关掉。
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
  { name: 'page',   kind: 'svg' },
  { name: 'back',   kind: 'svg' },
  { name: 'shadow', kind: 'png' },
  { name: 'ground', kind: 'svg' },
];

export function layerSvg(name) {
  const t = MASTER;
  switch (name) {
    case 'ground':
      return fullBleed(`${defs(DEFS.bg, DEFS.ring)}
${scaled(ground(fill => `<rect x="100" y="100" width="824" height="824" fill="${fill}"/>`))}`);
    case 'shadow':
      return fullBleed(`${defs(DEFS.sh(t.shadow), DEFS.bsh(t.shadow))}
${scaled(shadows(t))}`);
    case 'back':
      return fullBleed(`${defs(DEFS.back)}
${scaled(back())}`);
    case 'page':
      return fullBleed(`${defs(DEFS.paper)}
${scaled(page(t))}`);
    default:
      throw new Error(`未知图层: ${name}`);
  }
}

const srgb = hex => 'srgb:' + [1, 3, 5].map(i => (parseInt(hex.slice(i, i + 2), 16) / 255).toFixed(5)).join(',') + ',1.00000';
export function iconJson() {
  return JSON.stringify({
    // ground 图层盖满画布；fill 只是它加载前 / 被系统忽略时的兜底。
    fill: { 'linear-gradient': [srgb(P.bg0), srgb(P.bg1)] },
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
