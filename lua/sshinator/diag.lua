local M = {}

local function get_opt(name, opts)
  local ok, value = pcall(vim.api.nvim_get_option_value, name, opts or {})
  if not ok then
    return "<error: " .. tostring(value) .. ">"
  end
  return tostring(value)
end

local function win_desc(win)
  local buf = vim.api.nvim_win_get_buf(win)
  return string.format(
    "win=%d buf=%d ft=%s bt=%s number(local)=%s relativenumber(local)=%s",
    win,
    buf,
    vim.bo[buf].filetype,
    vim.bo[buf].buftype,
    get_opt("number", { win = win }),
    get_opt("relativenumber", { win = win })
  )
end

---Collect diagnostic information about line-number options and the window
---layout. Useful for debugging "line numbers disappear" reports.
---@return string
function M.collect()
  local lines = {}
  local function add(fmt, ...)
    table.insert(lines, select("#", ...) > 0 and string.format(fmt, ...) or fmt)
  end

  add("sshinator diagnostic - %s", os.date("%Y-%m-%d %H:%M:%S"))
  add("nvim %s (%s)", vim.version().major .. "." .. vim.version().minor .. "." .. vim.version().patch,
    vim.version().prerelease or "release")
  add("")

  add("== global option defaults ==")
  add("number(global)=%s", get_opt("number", { scope = "global" }))
  add("relativenumber(global)=%s", get_opt("relativenumber", { scope = "global" }))
  add("")

  add("== current window ==")
  add("%s", win_desc(vim.api.nvim_get_current_win()))
  add("")

  add("== all windows ==")
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    add("%s", win_desc(win))
  end
  add("")

  add("== :verbose set number? relativenumber? ==")
  add("%s", vim.fn.execute("verbose set number? relativenumber?"))
  add("== :verbose setlocal number? relativenumber? ==")
  add("%s", vim.fn.execute("verbose setlocal number? relativenumber?"))
  add("== :verbose setglobal number? relativenumber? ==")
  add("%s", vim.fn.execute("verbose setglobal number? relativenumber?"))
  add("")

  add("== autocommands referencing number/relativenumber ==")
  local found = false
  for _, line in ipairs(vim.split(vim.fn.execute("autocmd"), "\n")) do
    if line:lower():find("number", 1, true) then
      add("%s", line)
      found = true
    end
  end
  if not found then
    add("(none)")
  end
  add("")

  add("== sshinator config ==")
  local ok, cfg = pcall(require, "sshinator")
  if ok and cfg and cfg.config then
    add("%s", vim.inspect(cfg.config))
  else
    add("(unavailable)")
  end

  return table.concat(lines, "\n") .. "\n"
end

---Write diagnostics to `path` (defaults to ~/sshinator-diag.txt).
---@param path string|nil
---@return string path
function M.write(path)
  path = vim.fn.expand(path or "~/sshinator-diag.txt")
  local f, err = io.open(path, "w")
  if not f then
    error("could not write diagnostics to " .. path .. ": " .. tostring(err))
  end
  f:write(M.collect())
  f:close()
  return path
end

---Write diagnostics and open the file in the current window.
---@param path string|nil
---@return string path
function M.open(path)
  path = M.write(path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  return path
end

local watch_path = nil
local watch_orig = nil

local function watch_log(line)
  if not watch_path then
    return
  end
  local f = io.open(watch_path, "a")
  if f then
    f:write(line)
    f:close()
  end
end

---Start logging every write to `number`/`relativenumber`, including a Lua
---traceback of the caller. Call again to stop and open the log.
---@param path string|nil
---@return string|nil path
---@return boolean active
function M.watch_toggle(path)
  if watch_path then
    local done = watch_path
    watch_path = nil
    if watch_orig then
      vim.api.nvim_set_option_value = watch_orig
      watch_orig = nil
    end
    local f = io.open(done, "a")
    if f then
      f:write("stopped " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
      f:close()
    end
    vim.cmd("edit " .. vim.fn.fnameescape(done))
    return done, false
  end

  watch_path = vim.fn.expand(path or "~/sshinator-options.log")
  local f = io.open(watch_path, "w")
  if not f then
    watch_path = nil
    error("could not write watch log")
  end
  f:write("started " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
  f:close()

  -- `OptionSet` autocmds are unreliable in some builds, so intercept the API
  -- that `vim.o` / `vim.wo` ultimately call.
  watch_orig = vim.api.nvim_set_option_value
  vim.api.nvim_set_option_value = function(name, value, opts)
    if name == "number" or name == "relativenumber" then
      watch_log(string.format(
        "\n[%s] set %s=%s opts=%s win=%d ft=%s bt=%s buf=%s\n%s\n",
        os.date("%H:%M:%S"),
        name,
        tostring(value),
        vim.inspect(opts),
        vim.api.nvim_get_current_win(),
        vim.bo.filetype,
        vim.bo.buftype,
        vim.api.nvim_buf_get_name(0),
        debug.traceback("", 2)
      ))
    end
    if opts == nil then
      return watch_orig(name, value)
    end
    return watch_orig(name, value, opts)
  end
  return watch_path, true
end

return M
