local M = {}
local ui = require("sshinator.ui")

M.config = {
  auto_check_deps = true,
  notify_duration = 5000,
  request_timeout = 60000,
  external_terminal = false,
  terminal_emulator = nil,
  auto_terminal = true,
  auto_chdir = true,
  vfs_cache_mode = "writes",
  dir_cache_time = "5m",
  transfers = 4,
  checkers = 8,
  cache_dir = nil,
  mount_base = nil,
}

function M.setup(opts)
  if opts then
    M.config = vim.tbl_deep_extend("force", M.config, opts)
  end
  ui.configure({ notify_duration = M.config.notify_duration })

  if M.config.auto_check_deps then
    vim.defer_fn(M.check_deps, 1000)
  end
end

function M.config_path()
  local base = vim.env.XDG_CONFIG_HOME or (vim.fn.expand("~") .. "/.config")
  return base .. "/sshinator/connections.json"
end

local function data_base_dir()
  return M.config.mount_base or (vim.env.XDG_DATA_HOME or (vim.fn.expand("~") .. "/.local/share"))
end

local function cache_base_dir()
  return M.config.cache_dir or (vim.env.XDG_CACHE_HOME or (vim.fn.expand("~") .. "/.cache"))
end

local function mount_dir(name)
  return data_base_dir() .. "/sshinator/mounts/" .. name:gsub("[%s/\\:]", "_")
end

function M._load_config()
  local path = M.config_path()
  local ok, data = pcall(vim.fn.readfile, path)
  if not ok then return { connections = {} } end
  local ok_json, cfg = pcall(vim.fn.json_decode, table.concat(data, "\n"))
  return (ok_json and type(cfg) == "table" and cfg.connections) and cfg or { connections = {} }
end

local function save_config(cfg)
  local path = M.config_path()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(vim.split(vim.fn.json_encode(cfg), "\n"), path)
end

local function get_connection(name)
  local cfg = M._load_config()
  for _, conn in ipairs(cfg.connections) do
    if conn.name == name then return conn end
  end
  return nil
end

local function identity_file(conn)
  local idf = conn.identity_file
  if not idf or idf == "" or idf == "v:null" then
    return nil
  end
  return idf
end

local function format_conn(conn)
  local auth = conn.password_auth and " [password]" or ""
  return string.format("%s (%s@%s:%d)%s", conn.name, conn.user, conn.host, conn.port or 22, auth)
end

local function select_connection(prompt, callback)
  local cfg = M._load_config()
  if #cfg.connections == 0 then
    ui.notify("no connections configured. Use :SshinatorAdd first.", vim.log.levels.INFO)
    return
  end
  ui.select(cfg.connections, {
    prompt = prompt,
    format_item = format_conn,
  }, function(chosen)
    if chosen then
      callback(chosen)
    end
  end)
end

local function run_cmd(args, opts, on_done)
  if type(opts) == "function" then
    on_done = opts
    opts = {}
  end
  opts = opts or {}
  local result = { stdout = "", stderr = "", code = nil }
  local timed_out = false
  local exited = false

  local job_opts = {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then result.stdout = result.stdout .. table.concat(data, "\n") end
    end,
    on_stderr = function(_, data)
      if data then result.stderr = result.stderr .. table.concat(data, "\n") end
    end,
    on_exit = function(_, code)
      exited = true
      result.code = code
      if on_done and not timed_out then on_done(result) end
    end,
  }
  if opts.env then job_opts.env = opts.env end

  local job_id = vim.fn.jobstart(args, job_opts)
  if not job_id or job_id <= 0 then
    if on_done then on_done(nil, "failed to start process") end
    return nil
  end

  if opts.stdin_data then
    vim.fn.chansend(job_id, opts.stdin_data)
    vim.fn.chanclose(job_id, "stdin")
  end

  if opts.timeout then
    vim.defer_fn(function()
      if not exited then
        timed_out = true
        pcall(vim.fn.jobstop, job_id)
        if on_done then on_done(nil, "timeout") end
      end
    end, opts.timeout)
  end

  return job_id
end

local function detect_ssh_port(host, on_done)
  if not host or host == "" or vim.fn.executable("ssh") == 0 then
    vim.schedule(function() on_done(22) end)
    return
  end
  run_cmd({ "ssh", "-G", "-o", "ConnectTimeout=5", host }, function(r)
    if not r or r.code ~= 0 then
      on_done(22)
      return
    end
    for line in (r.stdout or ""):gmatch("(.-)\n") do
      local port = line:lower():match("^port%s+(%d+)%s*$")
      if port then
        on_done(tonumber(port))
        return
      end
    end
    on_done(22)
  end)
end

function M.check_deps()
  local missing = {}
  for _, c in ipairs({ "ssh", "rclone" }) do
    if vim.fn.executable(c) == 0 then table.insert(missing, c) end
  end
  local fusermount_ok = vim.fn.executable("fusermount3") == 1
    or vim.fn.executable("fusermount") == 1
    or vim.fn.executable("umount") == 1
  if not fusermount_ok then table.insert(missing, "fusermount/umount") end
  if #missing > 0 then
    ui.notify("missing dependencies: " .. table.concat(missing, ", "), vim.log.levels.WARN)
  end
end

local function kill_stale_rclone(mount_point)
  if vim.fn.executable("pkill") == 0 then return end
  local pattern = "rclone.*" .. vim.fn.escape(mount_point, "/.") .. ".*"
  run_cmd({ "pkill", "-f", pattern }, { timeout = 3000 }, function() end)
end

local function unmount_dir(dir, on_done)
  local tool, clean_flag, lazy_flag
  if vim.fn.executable("fusermount3") == 1 then
    tool, clean_flag, lazy_flag = "fusermount3", { "-u", dir }, { "-uz", dir }
  elseif vim.fn.executable("fusermount") == 1 then
    tool, clean_flag, lazy_flag = "fusermount", { "-u", dir }, { "-uz", dir }
  else
    tool, clean_flag, lazy_flag = "umount", { dir }, { "-l", dir }
  end

  local function try_lazy()
    local lazy_args = { tool }
    vim.list_extend(lazy_args, lazy_flag)
    run_cmd(lazy_args, { timeout = 5000 }, function(r)
      local ok = r and r.code == 0
      if ok then pcall(vim.fn.delete, dir, "d") end
      if on_done then on_done(ok, ok and nil or "unmount failed") end
    end)
  end

  local clean_args = { tool }
  vim.list_extend(clean_args, clean_flag)
  run_cmd(clean_args, { timeout = 5000 }, function(r)
    if r and r.code == 0 then
      pcall(vim.fn.delete, dir, "d")
      if on_done then on_done(true) end
    else
      try_lazy()
    end
  end)
end

local function is_mounted(name, on_done)
  local dir = mount_dir(name)
  if vim.fn.isdirectory(dir) == 0 then
    on_done(false)
    return
  end
  run_cmd({ "mountpoint", "-q", dir }, function(r)
    local mounted = r and r.code == 0
    if not mounted then
      on_done(false)
      return
    end
    -- Verify mount is responsive before reporting it as mounted.
    run_cmd({ "stat", dir }, { timeout = 3000 }, function(sr)
      if sr and sr.code == 0 then
        on_done(true)
        return
      end
      -- Mount is stale; tear it down so reconnect can create a fresh one.
      kill_stale_rclone(dir)
      unmount_dir(dir, function()
        on_done(false)
      end)
    end)
  end)
end

local function unmount_rclone(name, on_done)
  local dir = mount_dir(name)
  kill_stale_rclone(dir)
  is_mounted(name, function(mounted)
    if not mounted then
      if on_done then on_done(true) end
      return
    end
    unmount_dir(dir, on_done)
  end)
end

local function list_mounted(on_done)
  local cfg = M._load_config()
  local result = {}
  if #cfg.connections == 0 then
    on_done(result)
    return
  end
  local pending = #cfg.connections
  for _, conn in ipairs(cfg.connections) do
    is_mounted(conn.name, function(mounted)
      if mounted then
        result[conn.name] = mount_dir(conn.name)
      end
      pending = pending - 1
      if pending == 0 then
        on_done(result)
      end
    end)
  end
end

local function is_password_error(output)
  local lower = (output or ""):lower()
  return lower:find("permission denied")
    or lower:find("password")
    or lower:find("authentication failed")
    or lower:find("publickey")
    or lower:find("ssh: handshake failed")
    or lower:find("connection failed")
end

local function do_mount_rclone(name, conn, password, mount_point, on_done)
  local remote = conn.remote_path or ""
  local sftp_path = (remote == "" or remote == ".") and ":sftp:" or (":sftp:" .. remote)

  local cache_dir = cache_base_dir() .. "/sshinator/rclone"
  vim.fn.mkdir(cache_dir, "p")

  local log_file = cache_dir .. "/" .. name:gsub("[%s/\\:]", "_") .. ".log"

  local args = {
    "rclone", "mount",
    sftp_path,
    mount_point,
    "--sftp-host=" .. conn.host,
    "--sftp-user=" .. conn.user,
    "--sftp-port=" .. tostring(conn.port or 22),
    "--vfs-cache-mode", M.config.vfs_cache_mode,
    "--cache-dir", cache_dir,
    "--dir-cache-time", M.config.dir_cache_time,
    "--transfers", tostring(M.config.transfers),
    "--checkers", tostring(M.config.checkers),
    "--no-checksum",
    "--daemon",
    "--log-file=" .. log_file,
    "--sftp-shell-type=unix",
    "--sftp-set-modtime=false",
    "--sftp-md5sum-command=none",
    "--sftp-sha1sum-command=none",
  }

  local idf = identity_file(conn)
  if idf then
    table.insert(args, "--sftp-key-file=" .. vim.fn.expand(idf))
  end

  local max_attempts = math.min(30, math.max(10, math.floor(M.config.request_timeout / 500)))
  local function verify_mount(attempt)
    if attempt > max_attempts then
      on_done(nil, "mount verification timed out, see " .. log_file)
      return
    end
    run_cmd({ "mountpoint", "-q", mount_point }, function(r)
      if r and r.code == 0 then
        on_done(mount_point)
      else
        vim.defer_fn(function()
          verify_mount(attempt + 1)
        end, 500)
      end
    end)
  end

  local function do_mount()
    run_cmd(args, { timeout = M.config.request_timeout }, function(r)
      if not r or r.code ~= 0 then
        local err = "mount failed (exit " .. (r and r.code or "?") .. ")"
        local full_stderr = r and r.stderr or ""
        if r and is_password_error(full_stderr) then
          err = "authentication failed"
        end
        if full_stderr ~= "" then
          err = err .. ": " .. full_stderr:gsub("\n", " | "):sub(1, 200)
        end
        on_done(nil, err)
        return
      end
      verify_mount(1)
    end)
  end

  if password then
    vim.schedule(function()
      ui.notify("mounting '" .. name .. "' ...", vim.log.levels.INFO)
    end)
    run_cmd({ "rclone", "obscure", "-" }, { stdin_data = password .. "\n" }, function(r)
      if not r or r.code ~= 0 then
        on_done(nil, "failed to obscure password")
        return
      end
      table.insert(args, "--sftp-pass=" .. r.stdout:gsub("%s+$", ""))
      do_mount()
    end)
  else
    do_mount()
  end
end

local function mount_rclone(name, conn, password, on_done)
  local mount_point = mount_dir(name)
  vim.fn.mkdir(mount_point, "p")

  is_mounted(name, function(mounted)
    if mounted then
      unmount_rclone(name, function(ok)
        if not ok then
          on_done(nil, "failed to unmount existing mount")
          return
        end
        vim.fn.mkdir(mount_point, "p")
        do_mount_rclone(name, conn, password, mount_point, on_done)
      end)
    else
      do_mount_rclone(name, conn, password, mount_point, on_done)
    end
  end)
end

local function terminal_args(term, cmd_parts)
  if term == "kitty" then
    return vim.list_extend({ "kitty" }, cmd_parts)
  elseif term == "wezterm" then
    return vim.list_extend({ "wezterm", "start", "--" }, cmd_parts)
  elseif term == "gnome-terminal" then
    return vim.list_extend({ "gnome-terminal", "--" }, cmd_parts)
  elseif term == "xfce4-terminal" then
    local escaped = {}
    for _, part in ipairs(cmd_parts) do
      table.insert(escaped, vim.fn.shellescape(part))
    end
    return { "xfce4-terminal", "-e", table.concat(escaped, " ") }
  else
    return vim.list_extend({ term, "-e" }, cmd_parts)
  end
end

local function open_ssh_terminal(name, password, force_external)
  local conn = get_connection(name)
  if not conn then return end

  if password and password ~= "" and vim.fn.executable("sshpass") ~= 1 then
    ui.notify("sshpass not installed, terminal not available for password connections", vim.log.levels.WARN)
    return
  end

  local cmd_parts = {}
  local env = nil
  if password and password ~= "" and vim.fn.executable("sshpass") == 1 then
    vim.list_extend(cmd_parts, { "sshpass", "-e" })
    env = { SSHPASS = password }
  end
  vim.list_extend(cmd_parts, { "ssh" })
  if conn.port and conn.port ~= 22 then
    vim.list_extend(cmd_parts, { "-p", tostring(conn.port) })
  end
  local idf = identity_file(conn)
  if idf then
    vim.list_extend(cmd_parts, { "-i", vim.fn.expand(idf) })
  end
  table.insert(cmd_parts, conn.user .. "@" .. conn.host)

  local use_external = force_external
  if use_external == nil then
    use_external = M.config.external_terminal
  end

  if use_external then
    local custom = M.config.terminal_emulator
    local job_opts = { detach = true }
    if env then job_opts.env = env end
    if custom and custom ~= "" then
      if vim.fn.executable(custom) == 1 then
        vim.fn.jobstart(terminal_args(custom, cmd_parts), job_opts)
        return
      end
      ui.notify("configured terminal emulator not found: " .. custom, vim.log.levels.WARN)
      return
    end

    for _, t in ipairs({ "xterm", "kitty", "alacritty", "wezterm", "gnome-terminal", "xfce4-terminal", "lxterminal", "konsole", "urxvt", "st" }) do
      if vim.fn.executable(t) == 1 then
        vim.fn.jobstart(terminal_args(t, cmd_parts), job_opts)
        return
      end
    end
    ui.notify("no terminal emulator found", vim.log.levels.WARN)
    return
  end

  vim.defer_fn(function()
    vim.cmd("noautocmd belowright split")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_var(buf, "oil_disable", true)
    local session_name = string.format("[sshinator] %s (%d)", name, buf)
    vim.api.nvim_buf_set_name(buf, session_name)
    vim.api.nvim_win_set_buf(0, buf)
    local term_opts = { cwd = "/tmp" }
    if env then term_opts.env = env end
    vim.fn.termopen(cmd_parts, term_opts)
    vim.bo[buf].filetype = "sshinator-terminal"
    vim.api.nvim_buf_set_name(buf, session_name)
    vim.cmd("startinsert")
  end, 100)
end

local function current_connection()
  local base = data_base_dir() .. "/sshinator/mounts/"
  local cwd = vim.fn.getcwd()
  if cwd:find(base, 1, true) == 1 then
    return cwd:sub(#base + 1):match("^([^/]+)")
  end

  local buf_path = vim.fn.expand("%:p")
  if buf_path and buf_path ~= "" and buf_path:find(base, 1, true) == 1 then
    return buf_path:sub(#base + 1):match("^([^/]+)")
  end

  return nil
end

function M.open_terminal(name, force_external)
  if not name then
    name = current_connection()
    if not name then
      select_connection("Open SSH Terminal", function(conn)
        M.open_terminal(conn.name, force_external)
      end)
      return
    end
  end

  local conn = get_connection(name)
  if not conn then
    ui.notify("connection '" .. name .. "' not found", vim.log.levels.ERROR)
    return
  end

  if conn.password_auth then
    ui.input({ prompt = "Password for " .. name, mask = true }, function(pw)
      open_ssh_terminal(name, pw, force_external)
    end)
    return
  end

  open_ssh_terminal(name, nil, force_external)
end

local function do_connect(name, password)
  local conn = get_connection(name)
  if not conn then
    ui.notify("connection '" .. name .. "' not found", vim.log.levels.ERROR)
    return
  end

  if conn.password_auth and not password then
    ui.input({ prompt = "Password for " .. name, mask = true }, function(pw)
      if not pw then
        if identity_file(conn) then
          do_connect(name, "")
        else
          ui.notify("password required, connection cancelled", vim.log.levels.WARN)
        end
        return
      end
      do_connect(name, pw)
    end)
    return
  end

  mount_rclone(name, conn, password, function(mount_point, err)
    if not mount_point then
      if err == "authentication failed" and not password then
        ui.input({ prompt = "Password for " .. name, mask = true }, function(pw)
          if not pw then
            ui.notify("authentication failed, connection cancelled", vim.log.levels.WARN)
            return
          end
          do_connect(name, pw)
        end)
        return
      end
      ui.notify(err, vim.log.levels.ERROR)
      return
    end

    ui.notify("mounted '" .. name .. "' at " .. mount_point, vim.log.levels.INFO)

    vim.schedule(function()
      if M.config.auto_chdir then
        vim.fn.chdir(mount_point)
      end
      vim.cmd("noautocmd edit " .. vim.fn.fnameescape(mount_point))
    end)

    if M.config.auto_terminal then
      open_ssh_terminal(name, password)
    end
  end)
end

function M.connect(name)
  if name then
    do_connect(name)
    return
  end
  select_connection("Connect To", function(conn)
    do_connect(conn.name)
  end)
end

local function select_mounted(prompt, callback)
  list_mounted(function(mounted)
    local names = vim.tbl_keys(mounted)
    if #names == 0 then
      ui.notify("no active mounts", vim.log.levels.INFO)
      return
    end
    table.sort(names)
    ui.select(names, {
      prompt = prompt,
      format_item = function(mount_name)
        return string.format("%s (%s)", mount_name, mounted[mount_name])
      end,
    }, function(choice)
      if choice then
        callback(choice)
      end
    end)
  end)
end

function M.disconnect(name)
  if name then
    unmount_rclone(name, function(ok, err)
      if ok then
        ui.notify("disconnected '" .. name .. "'", vim.log.levels.INFO)
      else
        ui.notify(err or "disconnect failed", vim.log.levels.ERROR)
      end
    end)
    return
  end
  select_mounted("Disconnect", M.disconnect)
end

function M.disconnect_all()
  list_mounted(function(mounted)
    local names = vim.tbl_keys(mounted)
    if #names == 0 then
      ui.notify("no active mounts", vim.log.levels.INFO)
      return
    end
    local count = 0
    local pending = #names
    for _, conn_name in ipairs(names) do
      unmount_rclone(conn_name, function(ok)
        if ok then count = count + 1 end
        pending = pending - 1
        if pending == 0 then
          ui.notify("disconnected " .. count .. " connection(s)", vim.log.levels.INFO)
        end
      end)
    end
  end)
end

function M.reconnect(name)
  if name then
    unmount_rclone(name, function(ok)
      if not ok then
        ui.notify("unmount failed during reconnect", vim.log.levels.ERROR)
        return
      end
      vim.defer_fn(function()
        do_connect(name)
      end, 100)
    end)
    return
  end
  select_mounted("Reconnect", M.reconnect)
end

local function prompt_connection_form(existing, on_done)
  existing = existing or {}
  local is_edit = existing.name ~= nil

  local fields = {
    { key = "name", prompt = "Connection Name", default = existing.name or "", required = true },
    { key = "host", prompt = "Host", default = existing.host or "", required = true },
    { key = "user", prompt = "User", default = existing.user or vim.env.USER or "", required = true },
    {
      key = "port",
      prompt = "Port",
      default = is_edit and tostring(existing.port or 22) or function(results, cb)
        detect_ssh_port(results.host, cb)
      end,
      async_default = not is_edit,
    },
    { key = "remote_path", prompt = "Remote Path", default = existing.remote_path or "." },
    { key = "identity_file", prompt = "Identity File (leave empty to skip)", default = existing.identity_file or "" },
  }

  ui.input_chain(fields, function(results)
    if not results then return end

    local prompt_msg = "Use password auth?"
    if is_edit and existing.password_auth ~= nil then
      prompt_msg = string.format("Use password auth? (currently %s)", existing.password_auth and "Yes" or "No")
    end

    ui.confirm({ prompt = prompt_msg }, function(password_auth)
      if password_auth == nil then return end

      local conn = {
        name = results.name,
        host = results.host,
        user = results.user,
        port = tonumber(results.port) or 22,
        remote_path = results.remote_path or ".",
        identity_file = (results.identity_file or "") ~= "" and vim.fn.expand(results.identity_file) or nil,
        password_auth = password_auth == true,
      }
      on_done(conn)
    end)
  end)
end

function M.add_connection(opts)
  opts = opts or {}
  prompt_connection_form(opts, function(conn)
    local cfg = M._load_config()
    for _, c in ipairs(cfg.connections) do
      if c.name == conn.name then
        ui.notify("connection '" .. conn.name .. "' already exists", vim.log.levels.WARN)
        return
      end
    end
    table.insert(cfg.connections, conn)
    save_config(cfg)

    ui.confirm({ prompt = "Test connection?" }, function(test)
      if not test then
        ui.notify("added connection '" .. conn.name .. "'", vim.log.levels.INFO)
        return
      end

      local function run_test(env)
        local test_args = { "ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no", "-p", tostring(conn.port), "-l", conn.user, conn.host, "exit" }
        if identity_file(conn) then
          vim.list_extend(test_args, { "-i", conn.identity_file })
        end
        if env then
          table.insert(test_args, 1, "sshpass")
          table.insert(test_args, 2, "-e")
        end
        run_cmd(test_args, { timeout = 15000, env = env }, function(r)
          if r and r.code == 0 then
            ui.notify("connection test successful!", vim.log.levels.INFO)
          else
            ui.notify("connection test failed", vim.log.levels.ERROR)
          end
        end)
      end

      if conn.password_auth then
        ui.input({ prompt = "Password for " .. conn.name, mask = true }, function(password)
          if not password then
            ui.notify("added connection '" .. conn.name .. "' (not tested)", vim.log.levels.INFO)
            return
          end
          run_test({ SSHPASS = password })
        end)
      else
        run_test()
      end
    end)
  end)
end

function M.edit_connection(name)
  local function edit_conn(conn)
    prompt_connection_form(conn, function(updated)
      local cfg = M._load_config()
      for i, c in ipairs(cfg.connections) do
        if c.name == conn.name then
          updated.name = conn.name
          cfg.connections[i] = updated
          save_config(cfg)
          ui.notify("updated connection '" .. conn.name .. "'", vim.log.levels.INFO)
          return
        end
      end
      ui.notify("connection not found", vim.log.levels.ERROR)
    end)
  end

  if name then
    local conn = get_connection(name)
    if not conn then
      ui.notify("connection '" .. name .. "' not found", vim.log.levels.ERROR)
      return
    end
    edit_conn(conn)
    return
  end

  select_connection("Edit Connection", edit_conn)
end

function M.remove_connection(name)
  local function remove_conn(conn_name)
    local cfg = M._load_config()
    for i, conn in ipairs(cfg.connections) do
      if conn.name == conn_name then
        is_mounted(conn_name, function(mounted)
          local function do_remove()
            table.remove(cfg.connections, i)
            save_config(cfg)
            ui.notify("removed '" .. conn_name .. "'", vim.log.levels.INFO)
          end

          if mounted then
            ui.confirm({ prompt = conn_name .. " is mounted. Disconnect and remove?" }, function(ok)
              if not ok then return end
              unmount_rclone(conn_name, do_remove)
            end)
          else
            do_remove()
          end
        end)
        return
      end
    end
    ui.notify("connection not found", vim.log.levels.ERROR)
  end

  if name then
    remove_conn(name)
    return
  end

  select_connection("Remove Connection", function(conn)
    remove_conn(conn.name)
  end)
end

function M.status()
  local cfg = M._load_config()
  if #cfg.connections == 0 then
    ui.notify("no connections configured", vim.log.levels.INFO)
    return
  end
  list_mounted(function(mounted)
    vim.schedule(function()
      ui.status_window(cfg.connections, mounted)
    end)
  end)
end

function M.list_connections()
  select_connection("Connections", function(conn)
    local name = conn.name
    local actions = { "Connect", "Disconnect", "Reconnect", "Edit", "Status", "Terminal", "Remove" }
    ui.select(actions, { prompt = name .. " - Action" }, function(action)
      if not action then return end
      if action == "Connect" then
        M.connect(name)
      elseif action == "Disconnect" then
        M.disconnect(name)
      elseif action == "Reconnect" then
        M.reconnect(name)
      elseif action == "Edit" then
        M.edit_connection(name)
      elseif action == "Status" then
        is_mounted(name, function(mounted)
          local dir = mount_dir(name)
          local msg = mounted and string.format("MOUNTED at %s", dir) or "not mounted"
          ui.notify(name .. " - " .. msg, vim.log.levels.INFO)
        end)
      elseif action == "Terminal" then
        M.open_terminal(name)
      elseif action == "Remove" then
        M.remove_connection(name)
      end
    end)
  end)
end

return M
