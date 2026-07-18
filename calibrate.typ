// =============================================================================
// calibrate.typ · Quaderno 显示区 1:1 校准页
// -----------------------------------------------------------------------------
// 用途：验证「PDF 页面尺寸 == 屏幕物理显示区」这一假设是否精确成立。
// 用法：typst compile calibrate.typ calibrate.pdf  然后投递到设备，
//       拿实体尺子贴屏幕量那条 100mm 基准线。
//   量得 100mm → 精确 1:1，deliver.sh 的 PAGE_W/PAGE_H 正确
//   量得 L mm  → 存在缩放，把 PAGE_W/PAGE_H 各乘以 (100 / L) 即可校正
// 换机型（如 A4 机）时，改下面 PW/PH 为该机型显示区推导值后重新出图即可。
// =============================================================================

#let PW = 157.1mm     // 显示区宽（1404px ÷ 227dpi）
#let PH = 209.5mm     // 显示区高（1872px ÷ 227dpi）

#set page(width: PW, height: PH, margin: 0mm)
#set text(font: ("Helvetica Neue", "PingFang SC"), size: 9pt)

// ── 四角裁切标记：若设备裁边或留黑边，这四个角会缺失/内移 ──────────────
#let corner(x, y, hx, hy) = {
  place(top + left, dx: x, dy: y, line(start: (0mm, 0mm), end: (hx, 0mm), stroke: 0.7pt))
  place(top + left, dx: x, dy: y, line(start: (0mm, 0mm), end: (0mm, hy), stroke: 0.7pt))
}
#corner(0mm, 0mm, 10mm, 10mm)
#corner(PW, 0mm, -10mm, 10mm)
#corner(0mm, PH, 10mm, -10mm)
#corner(PW, PH, -10mm, -10mm)

// ── 标题与说明 ───────────────────────────────────────────────────────
#place(top + left, dx: 14mm, dy: 14mm, text(13pt, weight: "bold")[1:1 校准页 · Quaderno A5])
#place(top + left, dx: 14mm, dy: 22mm, text(8.5pt)[
  拿实体尺子贴屏幕，量下面标注 *100mm* 的水平基准线。
])
#place(top + left, dx: 14mm, dy: 28mm, text(8.5pt)[
  正好 100mm → 精确 1:1；否则记下实测值告诉我，我按比例校正。
])

// ── 水平基准线 100mm（x: 20→120mm, y: 48mm）─────────────────────────
#let HX = 20mm
#let HY = 52mm
#place(top + left, dx: HX, dy: HY, line(start: (0mm, 0mm), end: (100mm, 0mm), stroke: 0.6pt))
#for i in range(0, 11) {
  // 每 10mm 一个长刻度
  place(top + left, dx: HX + i * 10mm, dy: HY,
        line(start: (0mm, 0mm), end: (0mm, -4.5mm), stroke: 0.6pt))
  place(top + left, dx: HX + i * 10mm - 3mm, dy: HY - 10.5mm, text(7pt)[#(i * 10)])
}
#for i in range(0, 10) {
  // 每 5mm 一个短刻度（只画在 0–100mm 区间内）
  place(top + left, dx: HX + 5mm + i * 10mm, dy: HY,
        line(start: (0mm, 0mm), end: (0mm, -2.5mm), stroke: 0.4pt))
}
#place(top + left, dx: HX + 30mm, dy: HY + 2mm, text(9pt, weight: "bold")[← 这段应为 100 mm →])

// ── 垂直基准线 120mm（x: 14mm, y: 78→198mm）─────────────────────────
#let VX = 14mm
#let VY = 78mm
#place(top + left, dx: VX, dy: VY, line(start: (0mm, 0mm), end: (0mm, 110mm), stroke: 0.6pt))
#for i in range(0, 12) {
  place(top + left, dx: VX, dy: VY + i * 10mm,
        line(start: (0mm, 0mm), end: (4.5mm, 0mm), stroke: 0.6pt))
  place(top + left, dx: VX + 5.5mm, dy: VY + i * 10mm - 2mm, text(7pt)[#(i * 10)])
}
#place(top + left, dx: VX, dy: VY - 6mm, text(8pt, weight: "bold")[垂直基准 110 mm ↓])

// ── 字号实样：确认 12pt 的真实观感 ───────────────────────────────────
#place(top + left, dx: 38mm, dy: 84mm, text(9pt, weight: "bold")[字号实样（应等同纸上打印）])
#place(top + left, dx: 38mm, dy: 92mm, text(10pt)[10pt　这是十号字的中文与 English 混排])
#place(top + left, dx: 38mm, dy: 101mm, text(11pt)[11pt　这是十一号字的中文与 English])
#place(top + left, dx: 38mm, dy: 111mm,
      text(12pt)[12pt　*当前正文字号* 中文与 English])
#place(top + left, dx: 38mm, dy: 122mm, text(13pt)[13pt　这是十三号字的中文])
#place(top + left, dx: 38mm, dy: 134mm, text(14pt)[14pt　这是十四号字])

// ── 10mm 见方基准块：另一种快速校验 ─────────────────────────────────
#place(top + left, dx: 38mm, dy: 152mm, rect(width: 10mm, height: 10mm, stroke: 0.6pt))
#place(top + left, dx: 50mm, dy: 155mm, text(8pt)[← 这个方块应为 10 × 10 mm])

#place(top + left, dx: 38mm, dy: 168mm, rect(width: 50mm, height: 20mm, stroke: 0.6pt))
#place(top + left, dx: 38mm, dy: 190mm, text(8pt)[↑ 这个矩形应为 50 × 20 mm])

// ── 页脚：参数留档 ───────────────────────────────────────────────────
#place(bottom + left, dx: 14mm, dy: -6mm,
       text(7pt)[页面设定 157.1 × 209.5 mm ＝ 1404 × 1872 px ÷ 227 dpi])
