--[[
  book-filter.lua · epub → PDF 的兼容性修补
  ---------------------------------------------------------------------------
  用于 book.sh。解决真实 epub 转 typst 时的已知崩溃源。

  【问题】epub 内部锚点链接
    很多电子书（中文书尤甚）用手工锚点做尾注/交叉引用，形如
      <a href="#part0022.html_jz_0_10">(1)</a>
    pandoc 会译成 typst 的 #link(<part0022.html_jz_0_10>)[...]，
    但这些锚点在 typst 侧并不会生成对应 label，于是 typst 报
      error: label `<...>` does not exist in the document
    整本书渲染直接中止。

  【处理】把指向文档内部（# 开头）的链接摊平成纯文本：
    保留读者能看到的文字（如尾注序号「(1)」），只去掉失效的跳转。
    外部链接（http/https/mailto 等）原样保留。

  【取舍】尾注序号将不可点击。但它们本来就已失效——
    真正的导航（章节跳转）由 PDF 大纲与目录页承担，不受影响。
]]

function Link(el)
  local target = el.target or ""
  if target:sub(1, 1) == "#" then
    -- 内部锚点：摊平为其可见内容
    return el.content
  end
  return nil          -- 其余链接不动
end
