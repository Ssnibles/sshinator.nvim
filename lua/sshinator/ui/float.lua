local M = {}

local ns_id = nil

M.hl_groups = {
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

-- Track previous window and global line number options so floats never mutate user options
local saved_prev_win = nil
local saved_global_num = nil
local saved_global_rnu = nil
local saved_win_num = nil
local saved_win_rnu = nil

function M.setup_highlights()
  if highlights_initialized then
    return
  end
  highlights_initialized = true
  local defs = {
    [M.hl_groups.title] = { fg = "#7aa2f7", bold = true, default = true },
    [M.hl_groups.border] = { fg = "#3b4261", default = true },
    [M.hl_groups.prompt] = { fg = "#bb9af7", default = true },
    [M.hl_groups.selected] = { fg = "#c0caf5", bg = "#283457", bold = true, default = true },
    [M.hl_groups.status_mounted] = { fg = "#9ece6a", bold = true, default = true },
    [M.hl_groups.status_unmounted] = { fg = "#f7768e", default = true },
    [M.hl_groups.header] = { fg = "#7dcfff", bold = true, default = true },
    [M.hl_groups.keybind] = { fg = "#e0af68", default = true },
    [M.hl_groups.muted] = { fg = "#565f89", default = true },
  }
  for group, def in pairs(defs) do
    vim.api.nvim_set_hl(0, group, def)
  end
end

function M.get_ns_id()
  if not ns_id then
    ns_id = vim.api.nvim_create_namespace("sshinator")
  end
  return ns_id
end

function M.get_ui_size()
  local uis = vim.api.nvim_list_uis()
  if uis and uis[1] then
    return uis[1].width, uis[1].height
  end
  return vim.o.columns, vim.o.lines
end

function M.calc_center(width, height)
  local columns, lines = M.get_ui_size()
  local total_w = width + 2
  local total_h = height + 2
  return {
    row = math.max(0, math.floor((lines - total_h) / 2)),
    col = math.max(0, math.floor((columns - total_w) / 2)),
  }
end

function M.create_float(opts)
  M.setup_highlights()

  -- Save current window options and global options before opening float
  saved_prev_win = vim.api.nvim_get_current_win()
  saved_global_num = vim.o.number
  saved_global_rnu = vim.o.relativenumber
  if saved_prev_win and vim.api.nvim_win_is_valid(saved_prev_win) then
    pcall(function()
      saved_win_num = vim.wo[saved_prev_win].number
      saved_win_rnu = vim.wo[saved_prev_win].relativenumber
    end)
  end

  local width = opts.width or 50
  local height = opts.height or 10
  local pos = M.calc_center(width, height)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = opts.filetype or "sshinator"

  local win_config = {
    relative = "editor",
    width = width,
    height = height,
    row = pos.row,
    col = pos.col,
    style = "minimal",
    border = opts.border or "rounded",
    noautocmd = true,
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
    "FloatBorder:" .. M.hl_groups.border .. ",FloatTitle:" .. M.hl_groups.title,
    { win = win })

  return buf, win
end

function M.close_float(win)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end

  -- Restore global options so new windows/splits retain user settings
  if saved_global_num ~= nil then
    pcall(function() vim.o.number = saved_global_num end)
  end
  if saved_global_rnu ~= nil then
    pcall(function() vim.o.relativenumber = saved_global_rnu end)
  end

  -- Restore previous window local options
  if saved_prev_win and vim.api.nvim_win_is_valid(saved_prev_win) then
    if saved_win_num ~= nil then
      pcall(function() vim.wo[saved_prev_win].number = saved_win_num end)
    end
    if saved_win_rnu ~= nil then
      pcall(function() vim.wo[saved_prev_win].relativenumber = saved_win_rnu end)
    end
  end
end

return M
