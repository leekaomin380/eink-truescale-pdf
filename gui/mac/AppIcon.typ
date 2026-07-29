#set page(width: 1024pt, height: 1024pt, margin: 0pt, fill: none)
#let INK   = rgb("#1F2933")
#let PAPER = rgb("#F7F4EC")

#place(center + horizon,
  block(width: 824pt, height: 824pt, radius: 185pt, fill: INK, clip: true,
    place(center + horizon,
      block(width: 384pt, height: 512pt, fill: PAPER)[
        #place(top + left, dx: 52pt, dy: 66pt,
          block(width: 280pt, height: 380pt)[
            #place(top + left, rect(width: 190pt, height: 26pt, fill: INK))
            #for i in range(8) {
              place(top + left, dy: 74pt + i * 38pt,
                rect(width: if calc.rem(i,4) == 3 { 176pt } else { 280pt },
                     height: 13pt, fill: INK.lighten(28%)))
            }
          ])
      ])))
