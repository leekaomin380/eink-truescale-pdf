// =============================================================================
// font-test-songti.typ · 宋体字号 & 笔画对比度实测页
// -----------------------------------------------------------------------------
// 目的：验证 docs/typography-for-eink.md 中标为【机制推论】的一条 ——
//   「宋体/明朝体横细竖粗，细横笔在 227ppi 下接近或低于一像素，
//     被抗锯齿摊成浅灰，叠加墨水屏本就偏低的对比度即显发虚。」
// 设计：不只排各字号（那只能看出大小），同时给出同字号下
//       宋体 vs 苹方(黑体) 的并排对照 —— 才能看出「虚实」差异。
// 附：灰阶阶梯，用于验证另一条推论「浅于约 40% 的灰在墨水屏上接近糊掉」。
// =============================================================================

#let PW = 157.1mm
#let PH = 209.5mm
#let MG = 10mm

#set page(width: PW, height: PH, margin: MG)
#set par(justify: false, leading: 0.8em)

// 样例文本：前半为自然语句，后半刻意堆叠横笔密集字（三/量/書/言/畺）
#let S = "注意力是稀缺资源，墨水屏为深度阅读而生。三言量書畺鑫垚"

#let row(sz, fam) = block(breakable: false)[
  #text(7pt, fill: black)[#sz　#fam]
  #v(-1.4mm)
  #text(font: (fam, "Helvetica Neue"), size: sz)[#S]
  #v(1.2mm)
]

// ── 第 1 页：宋体各字号 ────────────────────────────────────────────────
#text(12pt, weight: "bold", font: ("Songti SC",))[宋体 · 各字号实测]
#v(1mm)
#text(7.5pt)[
  本页 1:1 显示，即真实物理字号。请留意横笔（如「三」「量」「書」的横画）
  是否发灰、断续、或与竖笔粗细失衡。
]
#v(2mm)
#line(length: 100%, stroke: 0.5pt)
#v(1.5mm)

#row(8pt,  "Songti SC")
#row(9pt,  "Songti SC")
#row(10pt, "Songti SC")
#row(11pt, "Songti SC")
#row(12pt, "Songti SC")
#row(13pt, "Songti SC")
#row(14pt, "Songti SC")

#pagebreak()

// ── 第 2 页：同字号 宋体 vs 苹方 对照 ─────────────────────────────────
#text(12pt, weight: "bold", font: ("PingFang SC",))[同字号对照 · 宋体 vs 苹方]
#v(1mm)
#text(7.5pt)[
  控制变量：同字号、同文本、同行距，只换字体。
  若推论成立，宋体应比苹方更显灰、更虚，且字号越小差距越明显。
]
#v(2mm)
#line(length: 100%, stroke: 0.5pt)
#v(1.5mm)

#for sz in (9pt, 10pt, 11pt, 12pt) {
  block(breakable: false)[
    #text(7pt, weight: "bold")[#sz]
    #v(-1mm)
    #text(6.5pt, fill: luma(60))[宋体 ↓]
    #v(-1.6mm)
    #text(font: ("Songti SC", "Helvetica Neue"), size: sz)[#S]
    #v(0.4mm)
    #text(6.5pt, fill: luma(60))[苹方 ↓]
    #v(-1.6mm)
    #text(font: ("PingFang SC", "Helvetica Neue"), size: sz)[#S]
    #v(2.2mm)
  ]
}

#v(1mm)
#line(length: 100%, stroke: 0.5pt)
#v(1.5mm)

// ── 灰阶阶梯：验证浅灰可辨识下限 ──────────────────────────────────────
#text(8pt, weight: "bold")[附：灰阶可辨识测试]
#v(0.5mm)
#text(7pt)[下列各级灰度中，你能清楚读出的最浅一档是？（用于校准正文辅助文字的用色）]
#v(1.5mm)
#for g in (0, 20, 40, 60, 90, 120, 150) {
  block[
    #text(8pt, fill: luma(g))[luma(#g)　这一行是灰度 #g 的示例文字，能否清晰辨认？]
    #v(0.6mm)
  ]
}
