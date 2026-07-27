local api = vim.api

local M = {}

M.ns = api.nvim_create_namespace('ci.ansi')

local CUBE = { 0x00, 0x5f, 0x87, 0xaf, 0xd7, 0xff }
local BASE = {
  '#000000',
  '#800000',
  '#008000',
  '#808000',
  '#000080',
  '#800080',
  '#008080',
  '#c0c0c0',
  '#808080',
  '#ff0000',
  '#00ff00',
  '#ffff00',
  '#0000ff',
  '#ff00ff',
  '#00ffff',
  '#ffffff',
}

---@param n integer
---@return string hex
---@return boolean themed
local function hex(n)
  if n < 16 then
    local u = vim.g['terminal_color_' .. n]
    if type(u) == 'string' and u:match('^#%x%x%x%x%x%x$') then
      return u, true
    end
    return BASE[n + 1], false
  elseif n < 232 then
    local i = n - 16
    return ('#%02x%02x%02x'):format(
      CUBE[math.floor(i / 36) % 6 + 1],
      CUBE[math.floor(i / 6) % 6 + 1],
      CUBE[i % 6 + 1]
    ),
      false
  end
  local g = (n - 232) * 10 + 8
  return ('#%02x%02x%02x'):format(g, g, g), false
end

---@class ci.ansi.State
---@field fg? integer|string
---@field bg? integer|string
---@field bold? boolean
---@field dim? boolean
---@field italic? boolean
---@field underline? boolean
---@field reverse? boolean
---@field strike? boolean

local cache, seq = {}, 0

---@param s ci.ansi.State
---@return string?
local function group(s)
  local bits = (s.bold and 1 or 0)
    + (s.italic and 2 or 0)
    + (s.underline and 4 or 0)
    + (s.reverse and 8 or 0)
    + (s.strike and 16 or 0)
  if bits == 0 and not s.fg and not s.bg then
    return nil
  end
  local key = tostring(s.fg) .. '\0' .. tostring(s.bg) .. '\0' .. bits
  local g = cache[key]
  if g then
    return g
  end
  seq = seq + 1
  g = 'CiAnsi' .. seq
  ---@type table<string, any>
  local v = {
    bold = s.bold,
    italic = s.italic,
    underline = s.underline,
    reverse = s.reverse,
    strikethrough = s.strike,
  }
  for _, k in ipairs({ 'fg', 'bg' }) do
    local c = s[k]
    if type(c) == 'number' then
      local h, themed = hex(c)
      v[k], v['cterm' .. k] = h, c
      v[k .. '_indexed'] = (c < 16 and not themed) or nil
    elseif c then
      v[k] = c
    end
  end
  api.nvim_set_hl(0, g, v)
  cache[key] = g
  return g
end

function M.reset_cache()
  cache, seq = {}, 0
end

local SET =
  { [1] = 'bold', [2] = 'dim', [3] = 'italic', [4] = 'underline', [7] = 'reverse', [9] = 'strike' }
local CLR = {
  [22] = 'bold',
  [23] = 'italic',
  [24] = 'underline',
  [27] = 'reverse',
  [29] = 'strike',
  [39] = 'fg',
  [49] = 'bg',
}

---@param s ci.ansi.State
---@param p integer[]
local function sgr(s, p)
  local i, n = 1, #p
  while i <= n do
    local c = p[i]
    if c == 0 then
      s.fg, s.bg, s.bold, s.dim, s.italic, s.underline, s.reverse, s.strike =
        nil, nil, nil, nil, nil, nil, nil, nil
    elseif SET[c] then
      s[SET[c]] = true
    elseif CLR[c] then
      s[CLR[c]] = nil
      if c == 22 then
        s.dim = nil
      end
    elseif c >= 30 and c <= 37 then
      s.fg = c - 30
    elseif c >= 40 and c <= 47 then
      s.bg = c - 40
    elseif c >= 90 and c <= 97 then
      s.fg = c - 82
    elseif c >= 100 and c <= 107 then
      s.bg = c - 92
    elseif c == 38 or c == 48 then
      local k = c == 38 and 'fg' or 'bg'
      if p[i + 1] == 5 then
        s[k], i = p[i + 2], i + 2
      elseif p[i + 1] == 2 then
        s[k], i =
          ('#%02x%02x%02x'):format(
            (p[i + 2] or 0) % 256,
            (p[i + 3] or 0) % 256,
            (p[i + 4] or 0) % 256
          ),
          i + 4
      end
    end
    i = i + 1
  end
end

---@param raw string
---@return integer[]
local function params(raw)
  local p = {}
  for tok in ((raw:gsub(':', ';')) .. ';'):gmatch('([^;]*);') do
    p[#p + 1] = tonumber(tok) or 0
  end
  if (p[1] == 38 or p[1] == 48) and p[2] == 2 and #p == 6 then
    table.remove(p, 3)
  end
  return #p > 0 and p or { 0 }
end

local CSI = '\27%[[%d;:?]*[A-Za-z]'

---@param line string
---@param st ci.ansi.State
---@return string text
---@return integer[][] spans
---@return string[]? links
function M.line(line, st)
  if not line:find('[\27\r\7\b\v\f]') then
    local hl = group(st)
    return line, hl and { { 0, #line, hl } } or {}
  end
  local esc = line:find('\27', 1, true)
  local links
  line = line:gsub('\r$', '')
  if esc then
    line = line
      :gsub('\27%]8;[^;]*;([^\27\7]*)[\27\7]\\?', function(url)
        if #url > 0 then
          links = links or {}
          links[#links + 1] = url
        end
        return ''
      end)
      :gsub('\27%][^\7\27]*\7', '')
  end
  line = line:gsub('[\7\b\v\f]', '')
  local text, spans = '', {}
  for segment in (line .. '\r'):gmatch('([^\r]*)\r') do
    local seg = segment:gsub(CSI, function(m)
      if m:sub(-1) ~= 'm' then
        return ''
      end
    end)
    local t, sp, pos = {}, {}, 1
    local len, from, hl = 0, 0, group(st)
    while true do
      local a, b, ps = seg:find('\27%[([%d;:]*)m', pos)
      if not a then
        break
      end
      local chunk = seg:sub(pos, a - 1)
      t[#t + 1], len = chunk, len + #chunk
      if hl and len > from then
        sp[#sp + 1] = { from, len, hl }
      end
      sgr(st, params(ps))
      from, hl, pos = len, group(st), b + 1
    end
    local tail = seg:sub(pos)
    t[#t + 1], len = tail, len + #tail
    if hl and len > from then
      sp[#sp + 1] = { from, len, hl }
    end
    if len < #text then
      for _, s in ipairs(spans) do
        if s[2] > len then
          sp[#sp + 1] = { math.max(s[1], len), s[2], s[3] }
        end
      end
      text = table.concat(t) .. text:sub(len + 1)
    else
      text = table.concat(t)
    end
    spans = sp
  end
  return text, spans, links
end

---@param buf integer
---@param row integer
---@param spans integer[][]
---@param links? string[]
---@param width integer
function M.apply(buf, row, spans, links, width)
  for _, s in ipairs(spans) do
    api.nvim_buf_set_extmark(buf, M.ns, row, s[1], { end_col = s[2], hl_group = s[3] })
  end
  if links then
    api.nvim_buf_set_extmark(buf, M.ns, row, 0, { end_col = width, url = links[1] })
  end
end

return M
