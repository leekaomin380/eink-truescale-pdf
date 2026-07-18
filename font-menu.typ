// =============================================================================
// font-menu.typ · 字号菜单页（1:1 实样）
// -----------------------------------------------------------------------------
// 因为页面按设备显示区物理尺寸出图、设备满屏 1:1 显示（已用尺子实测确认），
// 所以本页在墨水屏上呈现的字号 **就是真实物理字号**，可直接当菜单点选。
// 用法：typst compile font-menu.typ out.pdf → 投递到设备 → 选定后把
//       deliver.sh 里的 BODY_SIZE 改成对应值即可。
// 换机型：改下面 PW/PH 为该机型显示区尺寸（见 docs/ 技术文档）。
// =============================================================================

#let PW = 157.1mm          // Quaderno A5 显示区宽
#let PH = 209.5mm          // Quaderno A5 显示区高
#let MG = 12mm
#let TEXTW = PW - 2 * MG   // 版心宽 133.1mm

#set page(width: PW, height: PH, margin: MG)
#set text(font: ("Helvetica Neue", "PingFang SC"))
#set par(justify: false, leading: 0.72em)

#text(13pt, weight: "bold")[字号菜单 · Quaderno A5]

#v(1mm)
#text(7.5pt)[
  本页 1:1 显示，下列即真实物理字号。「字/行」按版心宽 #calc.round(TEXTW.mm(), digits: 1) mm 估算。选定后改 deliver.sh 的 `BODY_SIZE`。
]

#v(2mm)
#line(length: 100%, stroke: 0.4pt)
#v(1mm)

// 样例文本：中英混排的技术性叙述，贴近真实载荷
#let SAMPLE = "注意力是稀缺资源，墨水屏为深度阅读而生。渲染管道由 pandoc 解析语法树，typst 负责光栅化输出 PDF。"

#let row(sz) = {
  let cpl = calc.round(TEXTW / sz)
  block(breakable: false)[
    #text(7pt, fill: luma(90))[
      #text(weight: "bold")[#sz] ／ 约 #cpl 字每行
    ]
    #v(-1.2mm)
    #text(size: sz)[#SAMPLE]
    #v(0.9mm)
  ]
}

#row(8pt)
#row(9pt)
#row(10pt)
#row(11pt)
#row(12pt)
#row(13pt)
#row(14pt)

#v(1mm)
#line(length: 100%, stroke: 0.4pt)
#v(1mm)
#text(7pt, fill: luma(90))[
  参考：平装书 10–11pt，办公文档 11–12pt；行长 25–40 字为宜。当前默认 10pt。
]
