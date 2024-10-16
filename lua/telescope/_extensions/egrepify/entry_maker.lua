local ts_utils = require "telescope.utils"
local egrep_conf = require("telescope._extensions.egrepify.config").values

local os_sep = require("plenary.path").path.sep
local str = require "plenary.strings"

local find_whitespace = function(string_)
  local offset = 0
  for i = 1, #string_ do
    if string.sub(string_, i, i) == " " then
      offset = i
      break
    end
  end
  return offset
end

local function collect(tbl)
  local out = {}
  for i = 1, 8 do
    local val = tbl[i]
    if val then
      out[#out + 1] = val
    end
  end
  return out
end

local function has_ts_parser(lang)
  return pcall(vim.treesitter.language.add, lang)
end

-- get the string width of a number without converting to string
local function num_width(num)
  return math.floor(math.log10(num) + 1)
end

--- Load TS parser and return buffer highlights if available.
---@param bufnr number: buffer number
---@param lang string: filetype of buffer
---@return table: { [lnum] = { [columns ...] = "HighlightGroup" } }
local get_buffer_highlights = function(bufnr, lang)
  local has_parser = has_ts_parser(lang)
  local root
  if lang and has_parser then
    local parser = vim.treesitter.get_parser(bufnr, lang)
    root = parser:parse()[1]:root()
  end
  if not root then
    return {}
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local query = vim.treesitter.query.get(lang, "highlights")
  local line_highlights = setmetatable({}, {
    __index = function(t, k)
      local obj = {}
      rawset(t, k, obj)
      return obj
    end,
  })
  if query then
    for id, node in query:iter_captures(root, bufnr, 0, -1) do
      local hl = "@" .. query.captures[id]
      if hl and type(hl) ~= "number" then
        local row1, col1, row2, col2 = node:range()

        if row1 == row2 then
          local row = row1 + 1

          for index = col1, col2 do
            line_highlights[row][index] = hl
          end
        else
          local row = row1 + 1
          for index = col1, #lines[row] do
            line_highlights[row][index] = hl
          end

          while row < row2 + 1 do
            row = row + 1

            for index = 0, #(lines[row] or {}) do
              line_highlights[row][index] = hl
            end
          end
        end
      end
    end
  end
  return line_highlights
end

---@param path string absolute path to file
---@return table: { [lnum] = { [columns ...] = "HighlightGroup" } }
local get_ts_highlights = function(path)
  local ei = vim.go.eventignore
  vim.go.eventignore = "all"
  local highlights = {}
  local lang = vim.filetype.match { filename = path }
  if lang then
    local bufnr, loaded
    -- check if buffer is opened
    local buffers = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(b) == path then
        buffers[#buffers + 1] = b
      end
    end
    if #buffers == 1 then
      bufnr = buffers[1]
    else
      -- TODO: maybe change with reading file into temporary buffer ala plenary
      bufnr = vim.fn.bufadd(path)
      vim.fn.bufload(bufnr)
      -- trying to preempt issues
      pcall(vim.api.nvim_buf_set_name, bufnr, path)
      vim.go.eventignore = ei
      loaded = true
    end
    if bufnr then
      highlights = get_buffer_highlights(bufnr, lang)
      if loaded then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
  end
  vim.go.eventignore = ei
  return highlights
end
local cache = {}
local function line_display(entry, data, opts, ts_highlights)
  entry = entry or {}
  if not cache[entry.filename] then
    local tail = vim.fs.basename(entry.filename)
    local file_devicon, devicon_hl = ts_utils.transform_devicons(tail, tail, false)
    cache[entry.filename] = { file_devicon, devicon_hl }
  end
  local file_devicon, devicon_hl = cache[entry.filename][1], cache[entry.filename][2]
  -- if opts.title == false then
  --   file_devicon, devicon_hl = ts_utils.transform_devicons(entry.filename, entry.filename, false)
  -- end
  local lnum
  local lnum_width = opts.lnum and (opts.lnum_width or num_width(entry.lnum)) or 0
  local col_width = opts.col and (opts.col_width or num_width(entry.col)) or 0
  if opts.lnum then
    lnum = type(opts.lnum_width) == "number" and str.align_str(tostring(entry.lnum), opts.lnum_width, true)
      or tostring(entry.lnum)
  end
  local col
  if opts.col then
    col = type(opts.col_width) == "number" and str.align_str(tostring(entry.col), opts.col_width, true)
      or tostring(entry.col)
  end
  local display = table.concat(
    collect {
      [1] = file_devicon,
      [2] = opts.title == false and ":" or nil,
      [3] = lnum,
      [4] = lnum and " " or nil,
      [5] = col,
      [6] = col and ":" or nil,
      [7] = (lnum or col) and " " or nil,
      [8] = string.gsub(entry.text, "\r", ""),
    },
    ""
  )
  local highlights = {}
  local begin = 0
  local end_ = 0
  -- begin = end_ + 1 to skip the separators
  if opts.title == false then
    begin = find_whitespace(file_devicon)
    highlights[#highlights + 1] = { { 0, begin }, devicon_hl }
    end_ = #vim.fs.basename(entry.filename) + begin
    highlights[#highlights + 1] = { { begin, end_ }, opts.filename_hl }
    begin = end_ + 1
  end
  if lnum then
    end_ = begin + lnum_width
    highlights[#highlights + 1] = { { begin, end_ }, opts.lnum_hl }
    highlights[#highlights + 1] = { { begin - 1, begin }, opts.lnum_hl }
    highlights[#highlights + 1] = { { end_, end_ + 1 }, opts.lnum_hl }
    begin = end_ + 1
  end
  if col then
    end_ = begin + col_width
    highlights[#highlights + 1] = { { begin, end_ }, opts.col_hl }
    begin = end_ + 1
  end
  if lnum or col then
    begin = begin + 1
  end

  local covered_ids = {}
  if not vim.tbl_isempty(data["submatches"]) then
    local matches = data["submatches"]
    for i = 1, #matches do
      local submatch = matches[i]
      local s, f = submatch["start"], submatch["end"]
      end_ = begin + f
      highlights[#highlights + 1] = { { begin + s, end_ }, "TelescopeMatching" }
      for j = s, f - 1 do
        covered_ids[j] = true
      end
    end
  end
  return display, highlights
end

vim.api.nvim_create_autocmd({ "User" }, {
  pattern = "TelescopeSetSelection",
  callback = function(data)
    local action_state = require "telescope.actions.state"
    local prompt_bufnr = require("telescope.state").get_existing_prompt_bufnrs()[1]

    local picker = action_state.get_current_picker(prompt_bufnr)
    local title = picker.layout.picker.prompt_title
    if title ~= "Live Grep" then
      return
    end
    local results = picker.layout.results
    local bufnr = results.bufnr
    local winid = results.winid
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    _G.egrepfy_regions = {}
    local bottom_line = vim.api.nvim_win_call(winid, function()
      return vim.fn.line "w$"
    end)
    local first_line = vim.api.nvim_win_call(winid, function()
      return vim.fn.winsaveview().topline
    end)
    for i = first_line, bottom_line + 1 do
      local line = lines[i]
      if line == nil then
        goto continue
      end
      local entry = picker.manager:get_entry(i)
      if entry == nil then
        goto continue
      end
      local ft = require("plenary.filetype").detect(entry.filename)
      if ft == nil then
        goto continue
      end
      if _G.egrepfy_regions[ft] == nil then
        _G.egrepfy_regions[ft] = {}
      end
      -- Find the second occurrence of ':' starting after the first occurrence
      local second_pos = string.find(line, vim.trim(entry.text), nil, true)
      if second_pos == nil then
        goto continue
      end
      table.insert(_G.egrepfy_regions[ft], { { i - 1, second_pos - 2, i - 1, line:len() } })
      ::continue::
    end
    require("telescope._extensions.egrepify.treesitter").attach(bufnr, _G.egrepfy_regions)
  end,
})

local function title_display(filename, _, opts)
  local display_filename = ts_utils.transform_path({ cwd = opts.cwd }, filename)
  local suffix_ = opts.title_suffix or ""
  local display, hl_group = ts_utils.transform_devicons(filename, display_filename .. suffix_, false)
  local offset = find_whitespace(display)
  local end_filename = offset + #display_filename
  local end_suffix = end_filename + #opts.title_suffix
  if hl_group then
    return display,
      {
        { { 0, offset }, hl_group },
        {
          { offset, end_filename },
          opts.filename_hl,
        },
        suffix_ ~= "" and {
          { end_filename, end_suffix },
          opts.title_suffix_hl,
        } or nil,
      }
  else
    return display
  end
end

return function(opts)
  opts = opts or {}
  opts.filename_hl = vim.F.if_nil(opts.filename_hl, egrep_conf.filename_hl)
  opts.title_suffix = vim.F.if_nil(opts.title_suffix, egrep_conf.title_suffix)
  opts.title_suffix_hl = vim.F.if_nil(opts.title_suffix_hl, egrep_conf.title_suffix_hl)
  opts.lnum = vim.F.if_nil(opts.lnum, egrep_conf.lnum)
  opts.lnum_hl = vim.F.if_nil(opts.lnum_hl, egrep_conf.lnum_hl)
  opts.col = vim.F.if_nil(opts.col, egrep_conf.col)
  opts.col_hl = vim.F.if_nil(opts.col_hl, egrep_conf.col_hl)
  opts.results_ts_hl = vim.F.if_nil(opts.results_ts_hl, egrep_conf.results_ts_hl)
  local lnum_col_width = 1
  if opts.lnum then
    lnum_col_width = lnum_col_width + 4
  end
  if opts.col then
    lnum_col_width = lnum_col_width + 3
  end

  local items = {}
  if opts.lnum or opts.col then
    items[#items + 1] = { width = lnum_col_width }
  end
  items[#items + 1] = { remaining = true }

  opts.display_line_create = vim.F.if_nil(opts.display_line_create, {
    separator = (opts.lnum or opts.col) and " " or "",
    items = items,
  })
  opts.title_display = vim.F.if_nil(opts.title_display, title_display)
  local ts_highlights = {}

  return function(stream)
    local json_line = vim.json.decode(stream)
    if json_line == nil then
      return nil
    end
    local kind = json_line["type"]
    if json_line then
      if kind == "match" then
        local data = json_line["data"]
        local lines = data["lines"]
        if not lines then
          return
        end
        local text = lines["text"]
        if not text then
          return
        end
        text = text:gsub("\n", " ")
        local start = not vim.tbl_isempty(data["submatches"]) and data["submatches"][1]["start"] or 0
        local filename = data["path"]["text"]
        local lnum = data["line_number"]
        -- byte offset zero-indexed
        local col = start + 1
        local entry = {
          filename = filename,
          -- rg --json returns absolute paths when expl. directories are grepped
          path = opts.searches_dirs and filename or opts.cwd .. os_sep .. filename,
          cwd = opts.cwd,
          lnum = lnum,
          text = text,
          col = col,
          value = data,
          ordinal = string.format("%s:%s:%s:%s", filename, lnum, col, text),
          kind = kind,
        }

        local display = function()
          return line_display(entry, data, opts, ts_highlights)
        end
        entry.display = display
        return entry
      elseif
        -- parse beginning of rg output for a file
        kind == "begin" and opts.title ~= false
      then
        local data = json_line["data"]
        local filename = data["path"]["text"]
        return {
          value = filename,
          ordinal = filename,
          filename = filename,
          -- rg --json returns absolute paths when expl. directories are grepped
          path = opts.searches_dirs and filename or opts.cwd .. os_sep .. filename,
          cwd = opts.cwd,
          kind = kind,
          display = function()
            return opts.title_display(filename, data, opts)
          end,
        }
      end
    end
    -- TODO: check if other entry kinds are valid
    -- skip other entry kinds
    return nil
  end
end
