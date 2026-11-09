-- Convert visible prose only. Code, math, raw markup, link/image destinations and IDs
-- remain untouched. Metadata titles are included by Pandoc's document walker.
function Pandoc(doc)
  local values = {}
  doc:walk { Str = function(el) values[#values + 1] = el.text end }
  -- CLI -M title=... produces a MetaString, whereas YAML titles usually contain Str nodes.
  local refs = {}
  local function collect_strings(container, key)
    local value = container[key]
    if type(value) == 'string' then
      values[#values + 1] = value
      refs[#refs + 1] = { container = container, key = key, index = #values }
    elseif type(value) == 'table' then
      for child in pairs(value) do collect_strings(value, child) end
    end
  end
  for _, key in ipairs({'title', 'subtitle', 'author', 'abstract', 'description', 'subject', 'rights', 'keywords'}) do
    collect_strings(doc.meta, key)
  end
  if #values == 0 then return doc end
  local executable = os.getenv('P2Q_CHINESE_CONVERTER')
  if not executable or executable == '' then error('Missing Chinese converter') end
  local converted = pandoc.json.decode(pandoc.pipe(executable, {}, pandoc.json.encode(values)))
  if #converted ~= #values then error('Chinese converter returned an incomplete document') end
  for _, ref in ipairs(refs) do ref.container[ref.key] = converted[ref.index] end
  local index = 0
  return doc:walk { Str = function(el)
    index = index + 1
    el.text = converted[index]
    return el
  end }
end
