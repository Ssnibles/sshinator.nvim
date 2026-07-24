local M = {}

local ns_id = nil

local hl_groups = {
  title = "SshinatorTitle",
  border = "SshinatorBorder",
  prompt = "SshinatorPrompt",
  selected = "SshinatorSelected",
  status_mounted = "SshinatorMounted",
  status_unmounted = "SshinatorUnmounted",
  header = "SshinatorHeader",
  keybind = "SshinatorKeybind",
  muted = "SshinatorMuted",
}

local config = {
  notify_duration = 5000,
}

function M.configure(opts)
  opts = opts or {}
  if opts.notify_duration then
    config.notify_duration = opts.notify_duration
  end
end

local highlights_initialized = false

local function setup_highlights()
  if highlights_initialized then
    return
  end
  highlights_initialized = true
  local defs = {
    [hl_groups.title] = { fg = "#7aa2f7", bold = true, default = true },
    [hl_groups.border] = { fg = "#3b4261", default = true },
    [hl_groups.prompt] = { fg = "#bb9af7", default = true },
    [hl_groups.selected] = { fg = "#c0caf5", bg = "#283457", bold = true, default = true },
    [hl_groups.status_mounted] = { fg = "#9ece6a", bold = true, default = true },
    [hl_groups.status_unmounted] = { fg = "#f7768e", default = true },
    [hl_groups.header] = { fg = "#7dcfff", bold = true, default = true },
    [hl_groups.keybind] = { fg = "#e0af68", default = true },
    [hl_groups.muted] = { fg = "#565f89", default = true },
  }
  for group, def in pairs(defs) do
    vim.api.nvim_set_hl(0, group, def)
  end
end

local function get_ns_id()
  if not ns_id then
    ns_id = vim.api.nvim_create_namespace("sshinator")
  end
  return ns_id
end

local function get_ui_size()
  local ui = vim.api.nvim_list_uis()[1]
  if ui then
    return ui.width, ui.height
  end
  return vim.o.columns, vim.o.lines
end

local function calc_center(width, height)
  local columns, lines = get_ui_size()
  local total_w = width + 2
  local total_h = height + 2
  return {
    row = math.max(0, math.floor((lines - total_h) / 2)),
    col = math.max(0, math.floor((columns - total_w) / 2)),
  }
end

local function create_float(opts)
  setup_highlights()
  local width = opts.width or 50
  local height = opts.height or 10
  local pos = calc_center(width, height)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "sshinator"

  local win_config = {
    relative = "editor",
    width = width,
    height = height,
    row = pos.row,
    col = pos.col,
    style = "minimal",
    border = "rounded",
  }
  if opts.title then
    win_config.title = " " .. opts.title .. " "
    win_config.title_pos = "center"
  end

  local ok, win = pcall(vim.api.nvim_open_win, buf, true, win_config)
  if not ok or not win or win == 0 then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    return nil, nil
  end

  vim.api.nvim_set_option_value("winhl",
    "FloatBorder:" .. hl_groups.border .. ",FloatTitle:" .. hl_groups.title,
    { win = win })
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false

  local float_augroup = vim.api.nvim_create_augroup("sshinator_float_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "WinEnter", "BufWinEnter" }, {
    group = float_augroup,
    buffer = buf,
    callback = function()
      if vim.api.nvim_win_is_valid(win) then
        vim.wo[win].number = false
        vim.wo[win].relativenumber = false
      end
    end,
  })

  return buf, win
end

local function close_float(win, buf)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
end

function M.input(opts, callback)
  opts = opts or {}
  local title = opts.title or opts.prompt or "Input"
  local default = opts.default or ""
  local mask = opts.mask or false
  local width = math.max(50, vim.fn.strdisplaywidth(title) + 20)

  local buf, win = create_float({
    title = title,
    width = width,
    height = 1,
  })
  if not buf or not win then
    if vim.ui and vim.ui.input then
      vim.ui.input({ prompt = title .. ": ", default = default, secret = mask }, function(value)
        callback(value)
      end)
    else
      vim.notify("sshinator: unable to create input UI", vim.log.levels.ERROR)
      callback(nil)
    end
    return
  end

  vim.bo[buf].buftype = "nofile"
  vim.b[buf].completion = false

  local submitted = false
  local real_value = default

  local function set_content(text)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
    vim.bo[buf].modifiable = false
  end

  local function get_value()
    if mask then
      return real_value
    end
    return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
  end

  local function submit()
    if submitted then return end
    submitted = true
    local value = get_value()
    close_float(win, buf)
    vim.cmd("stopinsert")
    callback(value ~= "" and value or nil)
  end

  local function cancel()
    if submitted then return end
    submitted = true
    close_float(win, buf)
    vim.cmd("stopinsert")
    callback(nil)
  end

  if mask then
    set_content(string.rep("*", #default))
    vim.cmd("startinsert!")

    local function update_display()
      if not vim.api.nvim_buf_is_valid(buf) then return end
      set_content(string.rep("*", #real_value))
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_set_cursor(win, { 1, #real_value })
      end
    end

    vim.api.nvim_create_autocmd({ "InsertCharPre" }, {
      buffer = buf,
      callback = function()
        local char = vim.v.char
        if char == "" or char == "\r" or char == "\n" then
          return
        end
        real_value = real_value .. char
        vim.v.char = ""
        vim.schedule(update_display)
      end,
    })

    vim.keymap.set("i", "<BS>", function()
      if #real_value > 0 then
        real_value = real_value:sub(1, -2)
        update_display()
      end
    end, { buffer = buf, noremap = true })
  else
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { default })
    vim.cmd("startinsert!")
  end

  vim.keymap.set("i", "<CR>", submit, { buffer = buf, noremap = true })
  vim.keymap.set("n", "<CR>", submit, { buffer = buf, noremap = true })
  vim.keymap.set("i", "<Esc>", cancel, { buffer = buf, noremap = true })
  vim.keymap.set("n", "<Esc>", cancel, { buffer = buf, noremap = true })
  vim.keymap.set("n", "q", cancel, { buffer = buf, noremap = true })

  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    nested = true,
    once = true,
    callback = cancel,
  })
end

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

function M.select(items, opts, callback)
  opts = opts or {}
  local prompt = opts.prompt or "Select"

  if not items or #items == 0 then
    callback(nil)
    return
  end

  local max_width = 40
  for _, item in ipairs(items) do
    local w = vim.fn.strdisplaywidth(item)
    if w > max_width then
      max_width = w
    end
  end
  local columns, lines = get_ui_size()
  local width = math.min(math.max(max_width + 4, 40), math.floor(columns * 0.8))
  local height = math.min(#items, math.floor(lines * 0.6))

  local buf, win = create_float({
    title = prompt,
    width = width,
    height = height,
  })
  if not buf or not win then
    if vim.ui and vim.ui.select then
      vim.ui.select(items, { prompt = prompt }, function(choice)
        callback(choice)
      end)
    else
      vim.notify("sshinator: unable to create selection UI", vim.log.levels.ERROR)
      callback(nil)
    end
    return
  end

  local selected_idx = 1
  local submitted = false
  local filter_text = ""
  local filter_mode = false
  local filtered_items = {}

  local function apply_filter()
    if filter_text == "" then
      filtered_items = {}
      for i, item in ipairs(items) do
        table.insert(filtered_items, { idx = i, item = item, score = 0 })
      end
    else
      local scored = {}
      for i, item in ipairs(items) do
        local score = fuzzy_score(filter_text, item)
        if score > 0 then
          table.insert(scored, { idx = i, item = item, score = score })
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

  apply_filter()

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
    for i, entry in ipairs(filtered_items) do
      local prefix = i == selected_idx and " > " or "   "
      local line = prefix .. entry.item
      local padding = width - vim.fn.strdisplaywidth(line)
      if padding > 0 then
        line = line .. string.rep(" ", padding)
      end
      table.insert(render_lines, line)
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, render_lines)
    vim.bo[buf].modifiable = false

    vim.api.nvim_buf_clear_namespace(buf, get_ns_id(), 0, -1)
    for i = 1, #render_lines do
      if i == selected_idx then
        vim.api.nvim_buf_add_highlight(buf, get_ns_id(), hl_groups.selected, i - 1, 0, -1)
      end
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
    local choice = filtered_items[selected_idx] and filtered_items[selected_idx].item or nil
    close_float(win, buf)
    callback(choice)
  end

  local function cancel()
    if submitted then return end
    submitted = true
    close_float(win, buf)
    callback(nil)
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
    vim.cmd("startinsert!")
  end

  local function exit_filter_mode()
    if not filter_mode then return end
    filter_mode = false
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

  for i = 1, math.min(9, #filtered_items) do
    vim.keymap.set("n", tostring(i), function()
      selected_idx = i
      submit()
    end, { buffer = buf, noremap = true })
  end

  vim.keymap.set("i", "<CR>", submit, { buffer = buf, noremap = true })
  vim.keymap.set("i", "<Esc>", exit_filter_mode, { buffer = buf, noremap = true })
  vim.keymap.set("i", "<Down>", move_down, { buffer = buf, noremap = true })
  vim.keymap.set("i", "<Up>", move_up, { buffer = buf, noremap = true })
  vim.keymap.set("i", "<BS>", function()
    pop_filter()
  end, { buffer = buf, noremap = true })

  local filter_augroup = vim.api.nvim_create_augroup("sshinator_filter_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "InsertCharPre" }, {
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
    buffer = buf,
    nested = true,
    once = true,
    callback = function()
      pcall(vim.api.nvim_del_augroup_by_id, filter_augroup)
      cancel()
    end,
  })
end

function M.notify(msg, level)
  level = level or vim.log.levels.INFO
  local lines = vim.split(msg, "\n")

  local max_width = 40
  for _, line in ipairs(lines) do
    local w = vim.fn.strdisplaywidth(line)
    if w > max_width then
      max_width = w
    end
  end
  local columns, lines_count = get_ui_size()
  local width = math.min(math.max(max_width + 4, 30), math.floor(columns * 0.8))
  local height = math.min(#lines, math.floor(lines_count * 0.6))

  local title = "Sshinator"
  if level == vim.log.levels.ERROR then
    title = "Sshinator Error"
  elseif level == vim.log.levels.WARN then
    title = "Sshinator Warning"
  end

  local buf, win = create_float({
    title = title,
    width = width,
    height = height,
  })
  if not buf or not win then
    vim.notify("sshinator: " .. msg, level)
    return
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local hl = hl_groups.header
  if level == vim.log.levels.ERROR then
    hl = hl_groups.status_unmounted
  elseif level == vim.log.levels.WARN then
    hl = hl_groups.keybind
  end

  for i = 0, #lines - 1 do
    vim.api.nvim_buf_add_highlight(buf, get_ns_id(), hl, i, 0, -1)
  end

  local dismissed = false
  local function dismiss()
    if dismissed then return end
    dismissed = true
    close_float(win, buf)
  end

  vim.keymap.set("n", "<CR>", dismiss, { buffer = buf, noremap = true })
  vim.keymap.set("n", "<Esc>", dismiss, { buffer = buf, noremap = true })
  vim.keymap.set("n", "q", dismiss, { buffer = buf, noremap = true })

  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    once = true,
    callback = dismiss,
  })

  vim.defer_fn(dismiss, config.notify_duration)
end

function M.status_window(connections, mounted)
  local lines = {}
  local highlights = {}

  table.insert(lines, "")
  table.insert(highlights, { group = hl_groups.muted, line = #lines - 1 })

  for _, conn in ipairs(connections) do
    local is_mounted = mounted[conn.name] ~= nil
    local icon = is_mounted and "[connected]" or "[disconnected]"
    local line = string.format("  %s  %-20s %s@%s:%d", icon, conn.name, conn.user, conn.host, conn.port or 22)
    if is_mounted then
      line = line .. "  ->  " .. mounted[conn.name]
    end
    table.insert(lines, line)
    table.insert(highlights, {
      group = is_mounted and hl_groups.status_mounted or hl_groups.status_unmounted,
      line = #lines - 1,
    })
    table.insert(lines, "")
    table.insert(highlights, { group = hl_groups.muted, line = #lines - 1 })
  end

  local max_width = 60
  for _, line in ipairs(lines) do
    local w = vim.fn.strdisplaywidth(line)
    if w > max_width then
      max_width = w
    end
  end
  local columns, lines_count = get_ui_size()
  local width = math.min(math.max(max_width + 4, 50), math.floor(columns * 0.85))
  local height = math.min(#lines, math.floor(lines_count * 0.7))

  local buf, win = create_float({
    title = "Connection Status",
    width = width,
    height = height,
  })
  if not buf or not win then
    return
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  for _, h in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(buf, get_ns_id(), h.group, h.line, 0, -1)
  end

  local closed = false
  local function close()
    if closed then return end
    closed = true
    close_float(win, buf)
  end

  vim.keymap.set("n", "<CR>", close, { buffer = buf, noremap = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, noremap = true })
  vim.keymap.set("n", "q", close, { buffer = buf, noremap = true })

  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    once = true,
    callback = close,
  })
end

function M.confirm(opts, callback)
  opts = opts or {}
  local title = opts.title or opts.prompt or "Confirm"
  local width = math.max(50, vim.fn.strdisplaywidth(title) + 20)

  local buf, win = create_float({
    title = title,
    width = width,
    height = 3,
  })
  if not buf or not win then
    if vim.ui and vim.ui.select then
      vim.ui.select({ "Yes", "No" }, { prompt = prompt }, function(choice)
        callback(choice == "Yes")
      end)
    else
      vim.notify("sshinator: unable to create confirm UI", vim.log.levels.ERROR)
      callback(nil)
    end
    return
  end

  local selected_idx = 1
  local submitted = false

  local function render()
    local options = { "Yes", "No" }
    local lines = {}
    for i, opt in ipairs(options) do
      local prefix = i == selected_idx and " > " or "   "
      local line = prefix .. opt
      local padding = width - vim.fn.strdisplaywidth(line)
      if padding > 0 then
        line = line .. string.rep(" ", padding)
      end
      table.insert(lines, line)
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    vim.api.nvim_buf_clear_namespace(buf, get_ns_id(), 0, -1)
    for i = 1, #lines do
      if i == selected_idx then
        vim.api.nvim_buf_add_highlight(buf, get_ns_id(), hl_groups.selected, i - 1, 0, -1)
      end
    end
  end

  render()

  local function submit()
    if submitted then return end
    submitted = true
    local result = selected_idx == 1
    close_float(win, buf)
    callback(result)
  end

  local function cancel()
    if submitted then return end
    submitted = true
    close_float(win, buf)
    callback(nil)
  end

  local function toggle()
    selected_idx = selected_idx == 1 and 2 or 1
    render()
  end

  vim.keymap.set("n", "<CR>", submit, { buffer = buf, noremap = true })
  vim.keymap.set("n", "<Esc>", cancel, { buffer = buf, noremap = true })
  vim.keymap.set("n", "q", cancel, { buffer = buf, noremap = true })
  vim.keymap.set("n", "j", toggle, { buffer = buf, noremap = true })
  vim.keymap.set("n", "k", toggle, { buffer = buf, noremap = true })
  vim.keymap.set("n", "<Down>", toggle, { buffer = buf, noremap = true })
  vim.keymap.set("n", "<Up>", toggle, { buffer = buf, noremap = true })
  vim.keymap.set("n", "y", function()
    selected_idx = 1
    submit()
  end, { buffer = buf, noremap = true })
  vim.keymap.set("n", "n", function()
    selected_idx = 2
    submit()
  end, { buffer = buf, noremap = true })

  vim.api.nvim_set_option_value("number", false, { win = win })
  vim.api.nvim_set_option_value("relativenumber", false, { win = win })

  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    nested = true,
    once = true,
    callback = cancel,
  })
end

function M.input_chain(fields, callback)
  local results = {}
  local idx = 1
  local submitted = false

  local function process_field()
    if submitted then return end
    if idx > #fields then
      submitted = true
      callback(results)
      return
    end

    local field = fields[idx]
    local default_val = field.default
    if type(default_val) == "function" then
      default_val = default_val(results)
    end

    if field.mask then
      M.input({
        title = field.prompt,
        default = default_val or "",
        mask = true,
      }, function(value)
        if value == nil then
          submitted = true
          callback(nil)
          return
        end
        results[field.key] = value
        idx = idx + 1
        vim.schedule(process_field)
      end)
    else
      M.input({
        title = field.prompt,
        default = default_val or "",
      }, function(value)
        if value == nil then
          if field.required then
            submitted = true
            callback(nil)
            return
          end
          results[field.key] = nil
          idx = idx + 1
          vim.schedule(process_field)
          return
        end
        results[field.key] = value
        idx = idx + 1
        vim.schedule(process_field)
      end)
    end
  end

  vim.schedule(process_field)
end

return M
