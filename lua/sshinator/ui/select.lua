local M = {}
local float = require("sshinator.ui.float")

local function fuzzy_score(filter, text)
  filter = filter:lower()
  text = text:lower()
  local fidx = 1
  local score = 0
  local last_match = 0
  for i = 1, #text do
    if fidx <= #filter and text:sub(i, i) == filter:sub(fidx, fidx) then
      score = score + 1
      if last_match == i - 1 then
        score = score + 2
      end
      if i == 1 then
        score = score + 3
      else
        local prev = text:sub(i - 1, i - 1)
        if prev == " " or prev == "@" or prev == ":" or prev == "/" or prev == "-" or prev == "_" then
          score = score + 3
        end
      end
      fidx = fidx + 1
      last_match = i
    end
  end
  if fidx <= #filter then
    return 0
  end
  return score
end

function M.open(items, opts, callback)
  opts = opts or {}
  local prompt = opts.prompt or opts.title or "Select"
  local format_item = opts.format_item or tostring

  if not items or #items == 0 then
    callback(nil, nil)
    return
  end

  local max_width = 40
  local entries = {}
  for i, it in ipairs(items) do
    local text = format_item(it)
    local w = vim.fn.strdisplaywidth(text)
    if w > max_width then
      max_width = w
    end
    table.insert(entries, { idx = i, item = it, text = text })
  end

  local columns, lines = float.get_ui_size()
  local width = math.min(math.max(max_width + 6, 40), math.floor(columns * 0.85))
  local height = math.min(#entries, math.floor(lines * 0.6))

  local buf, win = float.create_float({
    title = prompt,
    width = width,
    height = height,
  })
  if not buf or not win then
    callback(nil, nil)
    return
  end

  local selected_idx = 1
  local submitted = false
  local filter_text = ""
  local filter_mode = false
  local filtered_items = entries

  local function apply_filter()
    if filter_text == "" then
      filtered_items = entries
    else
      local scored = {}
      for _, e in ipairs(entries) do
        local s = fuzzy_score(filter_text, e.text)
        if s > 0 then
          table.insert(scored, { idx = e.idx, item = e.item, text = e.text, score = s })
        end
      end
      table.sort(scored, function(a, b)
        if a.score ~= b.score then
          return a.score > b.score
        end
        return a.idx < b.idx
      end)
      filtered_items = scored
    end
    selected_idx = 1
  end

  local function update_title()
    local title = prompt
    if filter_text ~= "" then
      title = title .. " [filter: " .. filter_text .. "]"
    end
    pcall(vim.api.nvim_win_set_config, win, {
      title = " " .. title .. " ",
      title_pos = "center",
    })
  end

  local function render()
    local render_lines = {}
    for i, e in ipairs(filtered_items) do
      local prefix = i == selected_idx and " > " or "   "
      local line = prefix .. e.text
      local pad = width - vim.fn.strdisplaywidth(line)
      if pad > 0 then
        line = line .. string.rep(" ", pad)
      end
      table.insert(render_lines, line)
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, render_lines)
    -- Keep the buffer modifiable while filtering; `startinsert!` fails with
    -- E21 on a non-modifiable buffer. Input is intercepted via InsertCharPre.
    vim.bo[buf].modifiable = filter_mode

    local ns = float.get_ns_id()
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    if #filtered_items > 0 and selected_idx <= #filtered_items then
      vim.api.nvim_buf_add_highlight(buf, ns, float.hl_groups.selected, selected_idx - 1, 0, -1)
    end
  end

  local function refresh()
    update_title()
    render()
  end

  refresh()

  local function submit()
    if submitted then return end
    submitted = true
    local chosen = filtered_items[selected_idx]
    float.close_float(win)
    if filter_mode then
      vim.cmd("stopinsert")
    end
    if chosen then
      callback(chosen.item, chosen.idx)
    else
      callback(nil, nil)
    end
  end

  local function cancel()
    if submitted then return end
    submitted = true
    float.close_float(win)
    if filter_mode then
      vim.cmd("stopinsert")
    end
    callback(nil, nil)
  end

  local function move_up()
    if selected_idx > 1 then
      selected_idx = selected_idx - 1
      render()
    end
  end

  local function move_down()
    if selected_idx < #filtered_items then
      selected_idx = selected_idx + 1
      render()
    end
  end

  local function enter_filter_mode()
    if filter_mode then return end
    filter_mode = true
    vim.bo[buf].modifiable = true
    vim.cmd("startinsert!")
  end

  local function exit_filter_mode()
    if not filter_mode then return end
    filter_mode = false
    vim.bo[buf].modifiable = false
    vim.cmd("stopinsert")
  end

  local function append_filter_char(char)
    filter_text = filter_text .. char
    apply_filter()
    refresh()
  end

  local function pop_filter()
    if #filter_text > 0 then
      filter_text = filter_text:sub(1, -2)
      apply_filter()
      refresh()
    end
  end

  vim.keymap.set("n", "<CR>", submit, { buffer = buf, noremap = true })
  vim.keymap.set("n", "<Esc>", cancel, { buffer = buf, noremap = true })
  vim.keymap.set("n", "q", cancel, { buffer = buf, noremap = true })
  vim.keymap.set("n", "j", move_down, { buffer = buf, noremap = true })
  vim.keymap.set("n", "k", move_up, { buffer = buf, noremap = true })
  vim.keymap.set("n", "<Down>", move_down, { buffer = buf, noremap = true })
  vim.keymap.set("n", "<Up>", move_up, { buffer = buf, noremap = true })
  vim.keymap.set("n", "gg", function()
    selected_idx = 1
    render()
  end, { buffer = buf, noremap = true })
  vim.keymap.set("n", "G", function()
    selected_idx = #filtered_items
    render()
  end, { buffer = buf, noremap = true })
  vim.keymap.set("n", "/", enter_filter_mode, { buffer = buf, noremap = true })

  for i = 1, math.min(9, #entries) do
    vim.keymap.set("n", tostring(i), function()
      if i <= #filtered_items then
        selected_idx = i
        submit()
      end
    end, { buffer = buf, noremap = true })
  end

  vim.keymap.set("i", "<CR>", submit, { buffer = buf, noremap = true })
  vim.keymap.set("i", "<Esc>", exit_filter_mode, { buffer = buf, noremap = true })
  vim.keymap.set("i", "<Down>", move_down, { buffer = buf, noremap = true })
  vim.keymap.set("i", "<Up>", move_up, { buffer = buf, noremap = true })
  vim.keymap.set("i", "<BS>", pop_filter, { buffer = buf, noremap = true })

  local filter_augroup = vim.api.nvim_create_augroup("sshinator_picker_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("InsertCharPre", {
    group = filter_augroup,
    buffer = buf,
    callback = function()
      if not filter_mode then return end
      local char = vim.v.char
      if char == "" or char == "\r" or char == "\n" then
        return
      end
      vim.v.char = ""
      append_filter_char(char)
    end,
  })

  vim.api.nvim_create_autocmd("BufLeave", {
    group = filter_augroup,
    buffer = buf,
    once = true,
    callback = function()
      pcall(vim.api.nvim_del_augroup_by_id, filter_augroup)
      cancel()
    end,
  })
end

return M
