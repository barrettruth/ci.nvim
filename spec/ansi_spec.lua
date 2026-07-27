local ansi = require('ci.ansi')

---@param s string
---@return string text
---@return ci.ansi.Span[] spans
local function render(s)
  return ansi.line(s, {})
end

---@param name string
---@return table
local function hl(name)
  return vim.api.nvim_get_hl(0, { name = name })
end

describe('ansi.line', function()
  it('passes plain text through untouched', function()
    local text, spans = render('hello world')
    assert.equals('hello world', text)
    assert.same({}, spans)
  end)

  it('strips escapes and reports byte spans', function()
    local text, spans = render('a\27[31mred\27[0mb')
    assert.equals('aredb', text)
    assert.equals(1, #spans)
    assert.equals(1, spans[1][1])
    assert.equals(4, spans[1][2])
  end)

  it('defers the sixteen basic colours to the terminal palette', function()
    local _, spans = render('\27[31mx')
    local d = hl(spans[1][3])
    assert.is_true(d.fg_indexed)
    assert.equals(1, d.ctermfg)
  end)

  it('honours g:terminal_color_N when set', function()
    vim.g.terminal_color_1 = '#abcdef'
    ansi.reset_cache()
    local _, spans = render('\27[31mx')
    local d = hl(spans[1][3])
    assert.equals(0xabcdef, d.fg)
    assert.is_nil(d.fg_indexed)
    vim.g.terminal_color_1 = nil
    ansi.reset_cache()
  end)

  it('reads truecolor as one code, not three', function()
    local _, spans = render('\27[38;2;255;126;23mx')
    assert.equals(0xff7e17, hl(spans[1][3]).fg)
  end)

  it('reads 256-colour as one code, not three', function()
    local _, spans = render('\27[38;5;32mx')
    assert.equals(0x0087d7, hl(spans[1][3]).fg)
  end)

  it('combines attributes with colour in a single group', function()
    local _, spans = render('\27[32;1;3mx')
    local d = hl(spans[1][3])
    assert.is_true(d.bold)
    assert.is_true(d.italic)
    assert.equals(2, d.ctermfg)
  end)

  it('does not create an empty group for dim, which Neovim cannot render', function()
    local _, spans = render('\27[2mx')
    assert.same({}, spans)
  end)

  it('overwrites rather than truncates on carriage return', function()
    assert.equals('bbaaaaaaaa', (render('aaaaaaaaaa\rbb')))
  end)

  it('drops trailing CR from Windows runners', function()
    assert.equals('done', (render('done\r')))
  end)

  it('discards non-SGR CSI sequences', function()
    assert.equals('x', (render('\27[2K\27[1A\27[?25lx')))
  end)

  it('extracts OSC 8 hyperlinks', function()
    local text, _, links = ansi.line('\27]8;;https://example.com\27\\click\27]8;;\27\\', {})
    assert.equals('click', text)
    assert.same({ 'https://example.com' }, links)
  end)

  it('carries state across lines', function()
    local st = {}
    local _, a = ansi.line('\27[31mred', st)
    local _, b = ansi.line('still red', st)
    assert.equals(a[1][3], b[1][3])
  end)
end)
