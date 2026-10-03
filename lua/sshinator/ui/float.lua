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

-- Window-local options that Neovim can leak into the global defaults when a
-- float is opened or when it is the current window. Snapshotting/restoring
-- them guarantees floating windows (and terminals) never change the user's
-- global settings.
local LEAKY_GLOBAL_OPTS = { "number", "relativenumber" }

local function snapshot_globals(names)
  local saved = {}
  for _, name in ipairs(names) do
    saved[name] = vim.api.nvim_get_option_value(name, { scope = "global" })
  end
  return saved
end

local function restore_globals(saved)
  for name, value in pairs(saved) do
    pcall(vim.api.nvim_set_option_value, name, value, { scope = "global" })
  end
end

---Run `fn`, then restore the global values of `names` (defaults to the
---line-number options). Neovim writes window-local option changes made on the
---current window into the global defaults, so wrapping operations that may
---set them (opening terminals, special buffers, etc.) stops settings such as
---`nonumber` from leaking into every future window.
---@param names string[]|nil
---@param fn fun()
function M.preserve_global_opts(names, fn)
  local saved = snapshot_globals(names or LEAKY_GLOBAL_OPTS)
  local ok, err = pcall(fn)
  restore_globals(saved)
  if not ok then
    error(err)
  end
end

---Set a window-local option on `win` without mutating the global default.
---Setting window options while the window is current also updates the global
---value in Neovim, so restore the previous global value afterwards.
---@param win integer
---@param name string
---@param value any
function M.set_win_option(win, name, value)
  local ok, global = pcall(vim.api.nvim_get_option_value, name, { scope = "global" })
  vim.api.nvim_set_option_value(name, value, { win = win })
  if ok then
    pcall(vim.api.nvim_set_option_value, name, global, { scope = "global" })
  end
end

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

--- Saved global option snapshots keyed by float window, restored on close.
--- Closing a float moves focus back to the window underneath it, which can
--- trigger `WinEnter`/`BufEnter` autocommands that set window-local options
--- (e.g. a dashboard disabling line numbers). On Neovim versions where such
--- writes leak into the global defaults, restoring here keeps the damage from
--- spreading to every future window.
local pending_restore = {}

function M.create_float(opts)
  M.setup_highlights()

  -- `style = "minimal"` writes the float's line-number settings into the
  -- global option defaults. Capture the real global values before opening so
  -- they can be restored, otherwise every window opened afterwards inherits
  -- `nonumber`/`norelativenumber`.
  local saved_globals = snapshot_globals(LEAKY_GLOBAL_OPTS)

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
    restore_globals(saved_globals)
    return nil, nil
  end

  -- Undo any global option leakage caused by opening the float.
  restore_globals(saved_globals)

  -- Be explicit about the float's own options as well, so floats stay clean
  -- even if `style` handling changes in the future.
  M.set_win_option(win, "number", false)
  M.set_win_option(win, "relativenumber", false)
  M.set_win_option(win, "winhl",
    "FloatBorder:" .. M.hl_groups.border .. ",FloatTitle:" .. M.hl_groups.title)

  pending_restore[win] = saved_globals

  return buf, win
end

function M.close_float(win)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if win and pending_restore[win] then
    local saved = pending_restore[win]
    pending_restore[win] = nil
    -- Focus has now returned to the window below the float, so any autocommand
    -- leak has already happened; undo it.
    restore_globals(saved)
  end
end

return M
