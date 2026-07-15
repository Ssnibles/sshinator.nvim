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

local highlights_initialized = false

local function setup_highlights()
  if highlights_initialized then
    return
  end
  highlights_initialized = true
  local defs = {
    [hl_groups.title] = { fg = "#7aa2f7", bold = true },
    [hl_groups.border] = { fg = "#3b4261" },
    [hl_groups.prompt] = { fg = "#bb9af7" },
    [hl_groups.selected] = { fg = "#c0caf5", bg = "#283457", bold = true },
    [hl_groups.status_mounted] = { fg = "#9ece6a", bold = true },
    [hl_groups.status_unmounted] = { fg = "#f7768e" },
    [hl_groups.header] = { fg = "#7dcfff", bold = true },
    [hl_groups.keybind] = { fg = "#e0af68" },
    [hl_groups.muted] = { fg = "#565f89" },
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

local function calc_center(width, height)
  local columns = vim.o.columns
  local lines = vim.o.lines
  return {
    row = math.floor((lines - height) / 2),
    col = math.floor((columns - width) / 2),
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

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = pos.row,
    col = pos.col,
    style = "minimal",
    border = "rounded",
    title = opts.title and (" " .. opts.title .. " ") or nil,
    title_pos = opts.title and "center" or nil,
    noautocmd = true,
  })

  vim.api.nvim_set_option_value("winhl", "FloatBorder:" .. hl_groups.border .. ",FloatTitle:" .. hl_groups.title, { win = win, scope = "local" })

  return buf, win
end

local function close_float(win, buf)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
end

function M.input(opts, callback)
  opts = opts or {}
  local prompt = opts.prompt or "Input"
  local default = opts.default or ""
  local width = math.max(50, vim.fn.strdisplaywidth(prompt) + 20)

  local buf, win = create_float({
    title = prompt,
    width = width,
    height = 1,
  })

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { default })
  vim.cmd("startinsert!")

  local submitted = false

  local function submit()
    if submitted then return end
    submitted = true
    local value = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
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

function M.password(opts, callback)
  opts = opts or {}
  local prompt = opts.prompt or "Password"
  local width = math.max(50, vim.fn.strdisplaywidth(prompt) + 20)

  local buf, win = create_float({
    title = prompt,
    width = width,
    height = 1,
  })

  local real_value = ""
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  vim.cmd("startinsert!")

  local submitted = false

  local function update_display()
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { string.rep("*", #real_value) })
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_cursor(win, { 1, #real_value })
    end
  end

  local function submit()
    if submitted then return end
    submitted = true
    local val = real_value
    real_value = ""
    close_float(win, buf)
    vim.cmd("stopinsert")
    callback(val ~= "" and val or nil)
  end

  local function cancel()
    if submitted then return end
    submitted = true
    real_value = ""
    close_float(win, buf)
    vim.cmd("stopinsert")
    callback(nil)
  end

  vim.keymap.set("i", "<CR>", submit, { buffer = buf, noremap = true })
  vim.keymap.set("n", "<CR>", submit, { buffer = buf, noremap = true })
  vim.keymap.set("i", "<Esc>", cancel, { buffer = buf, noremap = true })
  vim.keymap.set("n", "<Esc>", cancel, { buffer = buf, noremap = true })
  vim.keymap.set("n", "q", cancel, { buffer = buf, noremap = true })

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

  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    nested = true,
    once = true,
    callback = cancel,
  })
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
  local width = math.min(math.max(max_width + 4, 40), math.floor(vim.o.columns * 0.8))
  local height = math.min(#items, math.floor(vim.o.lines * 0.6))

  local buf, win = create_float({
    title = prompt,
    width = width,
    height = height,
  })

  local selected_idx = 1
  local submitted = false

  local function render()
    local lines = {}
    for i, item in ipairs(items) do
      local prefix = i == selected_idx and " > " or "   "
      local line = prefix .. item
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
    local choice = items[selected_idx]
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
    if selected_idx < #items then
      selected_idx = selected_idx + 1
      render()
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
    selected_idx = #items
    render()
  end, { buffer = buf, noremap = true })

  for i = 1, math.min(9, #items) do
    vim.keymap.set("n", tostring(i), function()
      selected_idx = i
      submit()
    end, { buffer = buf, noremap = true })
  end

  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    nested = true,
    once = true,
    callback = cancel,
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
  local width = math.min(math.max(max_width + 4, 30), math.floor(vim.o.columns * 0.8))
  local height = math.min(#lines, math.floor(vim.o.lines * 0.6))

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

  local function dismiss()
    close_float(win, buf)
  end

  vim.keymap.set("n", "<CR>", dismiss, { buffer = buf, noremap = true })
  vim.keymap.set("n", "<Esc>", dismiss, { buffer = buf, noremap = true })
  vim.keymap.set("n", "q", dismiss, { buffer = buf, noremap = true })

  vim.defer_fn(function()
    if win and vim.api.nvim_win_is_valid(win) then
      close_float(win, buf)
    end
  end, 5000)
end

function M.status_window(connections, mounted)
  local lines = {}
  local highlights = {}

  table.insert(lines, "")
  table.insert(highlights, { group = hl_groups.muted, line = #lines - 1 })

  for _, conn in ipairs(connections) do
    local is_mounted = mounted[conn.name] ~= nil
    local state_str = is_mounted and "MOUNTED" or "not mounted"
    local icon = is_mounted and "[connected]" or "[disconnected]"
    local line = string.format("  %s  %-20s %s@%s:%d", icon, conn.name, conn.user, conn.host, conn.port)
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
  local width = math.min(math.max(max_width + 4, 50), math.floor(vim.o.columns * 0.85))
  local height = math.min(#lines, math.floor(vim.o.lines * 0.7))

  local buf, win = create_float({
    title = "Connection Status",
    width = width,
    height = height,
  })

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  for _, h in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(buf, get_ns_id(), h.group, h.line, 0, -1)
  end

  vim.keymap.set("n", "<CR>", function() close_float(win, buf) end, { buffer = buf, noremap = true })
  vim.keymap.set("n", "<Esc>", function() close_float(win, buf) end, { buffer = buf, noremap = true })
  vim.keymap.set("n", "q", function() close_float(win, buf) end, { buffer = buf, noremap = true })
end

function M.input_chain(fields, callback)
  local results = {}
  local idx = 1

  local function next_field()
    if idx > #fields then
      callback(results)
      return
    end
    local field = fields[idx]
    local input_fn = field.password and M.password or M.input
    input_fn({
      prompt = field.prompt,
      default = field.default or "",
    }, function(value)
      if value == nil and field.required then
        callback(nil)
        return
      end
      results[field.key] = value
      idx = idx + 1
      vim.schedule(next_field)
    end)
  end

  next_field()
end

return M
