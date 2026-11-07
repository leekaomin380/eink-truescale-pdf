--[[
  table-layout.lua · L2 Table Layout Policy
  ---------------------------------------------------------------------------
  Consumes the Pandoc AST (the Structural Intermediate Representation produced
  by L1). It never sees the clipboard flavor: an HTML table, a TSV table and a
  hand-written GFM table with identical cells must produce identical layout.

  Rules, in priority order:
    1. Content fidelity: no cell text is dropped or merged.
    2. Readability: column widths follow content, never equal fractions.
    3. Pagination: a row stays atomic; Typst repeats table.header on each page.
    4. Degradation: when a table cannot be read at the current physical size,
       render it as a DefinitionList, reusing the template's existing terms.item
       vocabulary (bold term + indented description) instead of inventing a style.
    5. Whole-table scaling is NOT used to force a table onto one page. The only
       existing scale rule (deliver.typ math.equation) applies to indivisible
       atomic objects, not to breakable/reflowable tables.

  Non-table nodes are returned as nil, so ordinary prose is byte-identical.
]]

local MIN_COL = 0.12          -- A4/A8: bounds pending on-device measurement
local MAX_COL = 0.62
local MAX_COLS = 6            -- A8: threshold pending on-device measurement
local MAX_CELL_LINES = 10     -- A8: a cell taller than this is not readable
local DEFAULT_TYPAREA_MM = 129.1   -- config.sh: 157.1mm - 2 * 14mm
local DEFAULT_BODY_PT = 10.5       -- config.sh BODY_SIZE
local PT_TO_MM = 25.4 / 72

-- Latin characters that fit across the full type area. Derived from geometry,
-- never hardcoded to a page size: 129.1mm / (10.5pt * 0.3528 * 0.5em) ~= 70,
-- consistent with book.sh's 32-40 CJK chars per line (CJK counts as 2).
local capacity = 70

local function meta_number(meta, key, default)
  if not meta or not meta[key] then return default end
  return tonumber(pandoc.utils.stringify(meta[key])) or default
end

local function configure(doc)
  local area = meta_number(doc.meta, 'typarea_mm', DEFAULT_TYPAREA_MM)
  local size = meta_number(doc.meta, 'body_size_pt', DEFAULT_BODY_PT)
  local advance = size * PT_TO_MM * 0.5
  if advance > 0 then capacity = area / advance end
  return nil
end

local function stringify(value)
  return pandoc.utils.stringify(value or {})
end

local function visual_len(s)
  local n = 0
  for ch in s:gmatch("([%z\1-\127\194-\244][\128-\191]*)") do
    n = n + (ch:len() > 1 and 2 or 1)
  end
  return n
end

-- Longest run that cannot be line-broken: ASCII identifiers, URLs, inline code.
-- CJK characters and spaces are valid break opportunities in the template.
local function longest_unbreakable(s)
  local best, current, i = 0, 0, 1
  while i <= #s do
    local b = s:byte(i)
    if b >= 194 then                       -- multibyte: a valid break point
      best = math.max(best, current)
      current = 0
      i = i + 1
      while i <= #s and s:byte(i) >= 128 and s:byte(i) <= 191 do i = i + 1 end
    elseif b == 32 or b == 9 or b == 10 or b == 13 or b == 47 or b == 45 then
      best = math.max(best, current)
      current = 0
      i = i + 1
    else
      current = current + 1
      i = i + 1
    end
  end
  return math.max(best, current)
end

local function cell_text(cell)
  -- Explicit ASCII whitespace only. Lua's %s is byte-locale aware and matches
  -- 0xA0 (a UTF-8 continuation byte in 素/池/... ) as NBSP, which would replace
  -- that byte with a space and corrupt the character. Never use %s on UTF-8 here.
  return (stringify(cell.contents or {})):gsub('[ \t\n\r\f\v]+', ' ')
end

local function scan_rows(rows, score, unbreakable)
  for _, row in ipairs(rows or {}) do
    for i, cell in ipairs(row.cells or {}) do
      local text = cell_text(cell)
      score[i] = math.max(score[i] or 1, visual_len(text))
      unbreakable[i] = math.max(unbreakable[i] or 0, longest_unbreakable(text))
    end
  end
end

local function collect(t)
  local cols = #t.colspecs
  local score, unbreakable = {}, {}
  for i = 1, cols do score[i], unbreakable[i] = 1, 0 end
  if t.head then scan_rows(t.head.rows, score, unbreakable) end
  for _, body in ipairs(t.bodies or {}) do scan_rows(body.body, score, unbreakable) end
  if t.foot then scan_rows(t.foot.rows, score, unbreakable) end
  return cols, score, unbreakable
end

local function proportional_widths(cols, score)
  local weights, total = {}, 0
  for i = 1, cols do
    weights[i] = math.max(math.sqrt(score[i]), 2)   -- damp very long cells
    total = total + weights[i]
  end
  local widths, sum = {}, 0
  for i = 1, cols do
    widths[i] = math.max(MIN_COL, math.min(MAX_COL, weights[i] / total))
    sum = sum + widths[i]
  end
  for i = 1, cols do widths[i] = widths[i] / sum end
  return widths
end

local function to_definition_list(t)
  local headers = {}
  if t.head and t.head.rows and t.head.rows[1] then
    for i, cell in ipairs(t.head.rows[1].cells) do headers[i] = cell_text(cell) end
  end
  local items, rownum = {}, 0
  local function rows(blocks)
    for _, row in ipairs(blocks or {}) do
      rownum = rownum + 1
      local cells = row.cells or {}
      local label = #cells > 0 and cell_text(cells[1]) or ''
      if label == '' then label = '行 ' .. rownum end
      local defs = pandoc.List()
      for i = 2, #cells do
        local key = (headers[i] and headers[i] ~= '') and headers[i] or ('列 ' .. i)
        defs:insert(pandoc.Para({
          pandoc.Strong({pandoc.Str(key)}),
          pandoc.Str('：'),
          pandoc.Str(cell_text(cells[i])),
        }))
      end
      if #defs == 0 then defs:insert(pandoc.Para({pandoc.Str('')})) end
      -- DefinitionList terms are Inlines (a list), not a single Inline object.
      items[#items + 1] = {pandoc.List({pandoc.Str(label)}), defs}
    end
  end
  for _, body in ipairs(t.bodies or {}) do rows(body.body) end
  if t.foot then rows(t.foot.rows) end
  return pandoc.DefinitionList(items)
end

function Table(t)
  local cols = #t.colspecs
  if cols < 2 then return nil end
  local _, score, unbreakable = collect(t)
  local widths = proportional_widths(cols, score)

  local degrade = cols > MAX_COLS
  for i = 1, cols do
    local room = capacity * widths[i]
    if unbreakable[i] > room then degrade = true end
    if score[i] > room * MAX_CELL_LINES then degrade = true end
  end
  if degrade then
    -- List-form degradation: field names and row identifiers are written out
    -- explicitly, so no row/column relation depends on visual alignment.
    return to_definition_list(t)
  end

  for i, spec in ipairs(t.colspecs) do
    spec[2] = widths[i]                  -- keep the source alignment in spec[1]
    -- AlignDefault (auto) is not author-specified; typst's auto centering makes
    -- headerless TSV tables look ragged. Left is the CJK reading baseline, while
    -- explicitly specified left / center / right are left untouched.
    if tostring(spec[1]) == 'AlignDefault' then spec[1] = pandoc.AlignLeft end
  end
  return t
end

return {
  { traverse = 'topdown', Pandoc = configure },
  { Table = Table },
}
