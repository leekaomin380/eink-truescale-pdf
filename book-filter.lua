--[[
  book-filter.lua · epub / html → PDF 的 AST 修补与安全分章
  ---------------------------------------------------------------------------
  1. 内部锚点摊平：解决 EPUB 内部无效锚点链接导致 Typst label 找不到而崩溃的问题。
  2. 顶层分章分页：若开启 chapterbreak，仅在 Pandoc AST 顶层 block 之前插入
     Typst 原生 #pagebreak(weak: true)，绝不侵入 Div / 表格 / 列表 / 引用块内部，
     规避 Typst 的 "pagebreaks are not allowed inside of containers" 崩溃。
]]

function Link(el)
  local target = el.target or ""
  if target:sub(1, 1) == "#" then
    -- 内部锚点：摊平为其可见内容
    return el.content
  end
  return nil          -- 其余链接不动
end

local function contains_h1(block)
  if block.t == "Header" and block.level == 1 then
    return true
  end
  local found = false
  pandoc.walk_block(block, {
    Header = function(h)
      if h.level == 1 then
        found = true
      end
    end
  })
  return found
end

function Pandoc(doc)
  local do_chapterbreak = false
  if doc.meta.chapterbreak then
    local val = pandoc.utils.stringify(doc.meta.chapterbreak)
    if val == "true" or val == "1" then
      do_chapterbreak = true
    end
  end

  if do_chapterbreak then
    local new_blocks = pandoc.List()
    local has_h1 = false

    for _, block in ipairs(doc.blocks) do
      if contains_h1(block) then
        if has_h1 then
          new_blocks:insert(pandoc.RawBlock('typst', '#pagebreak(weak: true)'))
        end
        has_h1 = true
      end
      new_blocks:insert(block)
    end
    doc.blocks = new_blocks
  end

  return doc
end
