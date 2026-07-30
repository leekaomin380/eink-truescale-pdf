#let horizontalrule = line(start: (25%,0%), end: (75%,0%))

#show terms.item: it => block(breakable: false)[
  #text(weight: "bold")[#it.term]
  #block(inset: (left: 1.5em, top: -0.4em))[#it.description]
]

#set table(
  inset: 6pt,
  stroke: none
)

#show figure.where(
  kind: table
): set figure.caption(position: $if(table-caption-position)$$table-caption-position$$else$top$endif$)

#show figure.where(
  kind: image
): set figure.caption(position: $if(figure-caption-position)$$figure-caption-position$$else$bottom$endif$)

$if(highlighting-definitions)$
// syntax highlighting functions from skylighting:
$highlighting-definitions$

$endif$
$if(template)$
#import "$template$": conf
$else$
$template.typst()$
$endif$

$if(smart)$
$else$
#set smartquote(enabled: false)

$endif$
$for(header-includes)$
$header-includes$

$endfor$
#show: doc => conf(
$if(author)$
  authors: (
$for(author)$
$if(author.name)$
    ( name: [$author.name$],
      affiliation: [$author.affiliation$],
      email: [$author.email$] ),
$else$
    ( name: [$author$],
      affiliation: "",
      email: "" ),
$endif$
$endfor$
    ),
$endif$
$if(keywords)$
  keywords: ($for(keywords)$$keywords$$sep$,$endfor$),
$endif$
$if(date)$
  date: [$date$],
$endif$
$if(lang)$
  lang: "$lang$",
$endif$
$if(region)$
  region: "$region$",
$endif$
$if(abstract-title)$
  abstract-title: [$abstract-title$],
$endif$
$if(abstract)$
  abstract: [$abstract$],
$endif$
$if(thanks)$
  thanks: [$thanks$],
$endif$
$if(margin)$
  margin: $margin$,
$endif$
$if(papersize)$
  paper: "$papersize$",
$endif$
$if(mainfont)$
  font: ($for(mainfont)$"$mainfont$",$endfor$),
$endif$
$if(fontsize)$
  fontsize: $fontsize$,
$endif$
$if(mathfont)$
  mathfont: ($for(mathfont)$"$mathfont$",$endfor$),
$endif$
$if(codefont)$
  codefont: ($for(codefont)$"$codefont$",$endfor$),
$endif$
$if(linestretch)$
  linestretch: $linestretch$,
$endif$
$if(section-numbering)$
  sectionnumbering: "$section-numbering$",
$endif$
  pagenumbering: $if(page-numbering)$"$page-numbering$"$else$none$endif$,
$if(linkcolor)$
  linkcolor: [$linkcolor$],
$endif$
$if(citecolor)$
  citecolor: [$citecolor$],
$endif$
$if(filecolor)$
  filecolor: [$filecolor$],
$endif$
  cols: $if(columns)$$columns$$else$1$endif$,
  doc,
)

$if(pagewidth)$
#set page(width: $pagewidth$, height: $pageheight$$if(pagemargin)$, margin: $pagemargin$$endif$)
$endif$
$if(bodysize)$
#set text(size: $bodysize$)
$endif$
$if(chapterbreak)$
#show heading.where(level: 1): it => { pagebreak(weak: true); it }
$endif$
$if(leading)$
#set par(leading: $leading$)
$endif$
// 标题与正文之间留出呼吸空间。
// typst 的 heading 默认 below 约 0.55em，标题几乎贴住首行正文；
// 中文标题字面饱满、缺少升降部，视觉上比西文更"顶"，故需更多下间距。
//
// 必须写成 `show heading: set block(...)`（只改样式），
// 不可写成 `show heading: it => block(..., it)`（构造容器）——
// 后者会把标题包进容器，而分章规则要在标题处 pagebreak，typst 随即报
// 「pagebreaks are not allowed inside of containers」，整本 EPUB 渲染中止。
// 该错误已由 test.sh 的 EPUB 断言当场抓到。
#show heading: set block(above: 1.5em, below: 0.9em)

// 超宽数学块等比缩进版心 —— typst 的数学块【不会自动换行】，长公式会原样
// 顶出版心。实测一条来自 AI 对话的真实公式：版心 [34.0, 411.3]pt，
// 公式却占 [5.6, 439.8]pt（左右各溢约 10mm），距纸张物理边缘仅剩 2mm。
// 这在墨水屏上尤其危险：屏幕边缘常有数毫米被外壳遮挡或显示不良，
// 溢出的两端可能真的看不见。
// 只在超宽时缩，绝不放大 —— 与 ImageInliner 处理图片同一原则。
#show math.equation.where(block: true): it => {
  layout(size => {
    let w = measure(it).width
    if w > size.width {
      let s = size.width / w
      block(width: 100%, align(center,
        scale(x: s * 100%, y: s * 100%, reflow: true, it)))
    } else { it }
  })
}
$if(title)$
#align(center)[
  #block(above: 1.2em, below: 1.4em)[#text(1.5em, weight: "bold")[$title$]]
$if(subtitle)$  #block(below: 0.6em)[#text(1.05em)[$subtitle$]]
$endif$$if(author)$  #block(below: 1.6em)[#text(0.95em)[$for(author)$$author$$sep$, $endfor$]]
$endif$]
$endif$
$for(include-before)$
$include-before$

$endfor$
$if(toc)$
#outline(
  title: auto,
  depth: $toc-depth$
);
$endif$

$body$

$if(citations)$
$for(nocite-ids)$
#cite(label("${it}"), form: none)
$endfor$
$if(csl)$

#set bibliography(style: "$csl$")
$elseif(bibliographystyle)$

#set bibliography(style: "$bibliographystyle$")
$endif$
$if(bibliography)$

#bibliography(($for(bibliography)$"$bibliography$"$sep$,$endfor$)$if(full-bibliography)$, full: true$endif$)
$endif$
$endif$
$for(include-after)$

$include-after$
$endfor$
