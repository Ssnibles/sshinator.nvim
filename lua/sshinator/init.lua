local M = {}
local ui = require("sshinator.ui")

M.config = {
  auto_check_deps = true,
  notify_duration = 5000,
  request_timeout = 30000,
  external_terminal = false,
  auto_chdir = true,
  vfs_cache_mode = "writes",
  dir_cache_time = "5m",
  transfers = 4,
  checkers = 8,
  cache_dir = nil,
  mount_base = nil,
}

local mount_cache = {}

local function config_path()
  local base = vim.env.XDG_CONFIG_HOME or (vim.fn.expand("~") .. "/.config")
  return base .. "/sshinator/connections.json"
end

function M._load_config()
  local path = config_path()
  local ok, data = pcall(vim.fn.readfile, path)
  if not ok then return { connections = {} } end
  local ok, cfg = pcall(vim.fn.json_decode, table.concat(data, "\n"))
  return ok and cfg or { connections = {} }
end

local function save_config(cfg)
  local path = config_path()
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

  if opts.timeout then
    vim.defer_fn(function()
      if not exited then
        timed_out = true
        vim.fn.jobstop(job_id)
        if on_done then on_done(nil, "timeout") end
      end
    end, opts.timeout)
  end

  return job_id
end

function M.setup(opts)
  opts = opts or {}
  M.config.auto_check_deps = opts.auto_check_deps ~= false
  M.config.external_terminal = opts.external_terminal or false
  M.config.auto_chdir = opts.auto_chdir ~= false
  M.config.notify_duration = opts.notify_duration or 5000
  M.config.request_timeout = opts.request_timeout or 60000
  M.config.vfs_cache_mode = opts.vfs_cache_mode or "writes"
  M.config.dir_cache_time = opts.dir_cache_time or "5m"
  M.config.transfers = opts.transfers or 4
  M.config.checkers = opts.checkers or 8
  M.config.cache_dir = opts.cache_dir or nil
  M.config.mount_base = opts.mount_base or nil

  ui.configure({ notify_duration = M.config.notify_duration })

  if M.config.auto_check_deps then
    vim.defer_fn(M.check_deps, 1000)
  end
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
  for _, cmd in ipairs({ "ssh", "rclone" }) do
    if vim.fn.executable(cmd) == 0 then table.insert(missing, cmd) end
  end
  local fusermount_ok = vim.fn.executable("fusermount3") == 1
    or vim.fn.executable("fusermount") == 1
    or vim.fn.executable("umount") == 1
  if not fusermount_ok then table.insert(missing, "fusermount/umount") end
  if #missing > 0 then
    ui.notify("sshinator: missing dependencies: " .. table.concat(missing, ", "), vim.log.levels.WARN)
  end
end

function M.get_binary_path()
  return nil
end

function M._get_client()
  return nil
end

local function mount_dir(name)
  local base = M.config.mount_base
    or (vim.env.XDG_DATA_HOME or (vim.fn.expand("~") .. "/.local/share"))
  return base .. "/sshinator/mounts/" .. name:gsub("[%s/\\:]", "_")
end

local function is_mounted(name, on_done)
  if mount_cache[name] == false then
    on_done(false)
    return
  end
  if mount_cache[name] == true then
    on_done(true)
    return
  end
  local dir = mount_dir(name)
  if vim.fn.isdirectory(dir) == 0 then
    mount_cache[name] = false
    on_done(false)
    return
  end
  run_cmd({ "mountpoint", "-q", dir }, function(r)
    local mounted = r and r.code == 0
    mount_cache[name] = mounted
    on_done(mounted)
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

local function unmount_rclone(name, on_done)
  local dir = mount_dir(name)
  is_mounted(name, function(mounted)
    if not mounted then
      mount_cache[name] = false
      if on_done then on_done(true) end
      return
    end
    local umount_cmd
    if vim.fn.executable("fusermount3") == 1 then
      umount_cmd = { "fusermount3", "-u", dir }
    elseif vim.fn.executable("fusermount") == 1 then
      umount_cmd = { "fusermount", "-u", dir }
    else
      umount_cmd = { "umount", dir }
    end
    run_cmd(umount_cmd, { timeout = 5000 }, function(r)
      if r and r.code == 0 then
        vim.fn.delete(dir, "d")
        mount_cache[name] = false
        if on_done then on_done(true) end
      else
        if on_done then on_done(nil, "unmount failed") end
      end
    end)
  end)
end

local function do_mount_rclone(name, conn, password, mount_point, on_done)
  local remote = conn.remote_path or ""
  local sftp_path
  if remote == "" or remote == "." then
    sftp_path = ":sftp:"
  else
    sftp_path = ":sftp:" .. remote
  end

  local cache_dir = M.config.cache_dir
    or (vim.env.XDG_CACHE_HOME or (vim.fn.expand("~") .. "/.cache"))
  cache_dir = cache_dir .. "/sshinator/rclone"
  vim.fn.mkdir(cache_dir, "p")

  local log_file = "/tmp/sshinator-rclone-" .. name:gsub("[%s/\\:]", "_") .. ".log"

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

  if conn.identity_file and conn.identity_file ~= "" then
    table.insert(args, "--sftp-key-file=" .. conn.identity_file)
  end

  local function verify_mount(attempt)
    if attempt > 6 then
      mount_cache[name] = false
      on_done(nil, "mount verification failed, see " .. log_file)
      return
    end
    run_cmd({ "mountpoint", "-q", mount_point }, function(r)
      local mounted = r and r.code == 0
      if mounted then
        mount_cache[name] = true
        on_done(mount_point)
      else
        vim.defer_fn(function()
          verify_mount(attempt + 1)
        end, 300)
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
        mount_cache[name] = false
        on_done(nil, err)
        return
      end
      verify_mount(1)
    end)
  end

  if password then
    vim.schedule(function()
      ui.notify("sshinator: mounting '" .. name .. "' ...", vim.log.levels.INFO)
    end)
    run_cmd({ "rclone", "obscure", password }, function(r)
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

local function open_ssh_terminal(name, password)
  local conn = get_connection(name)
  if not conn then return end

  if password and password ~= "" and vim.fn.executable("sshpass") ~= 1 then
    ui.notify("sshinator: sshpass not installed, terminal not available for password connections", vim.log.levels.WARN)
    return
  end

  local cmd_parts = {}
  if password and password ~= "" and vim.fn.executable("sshpass") == 1 then
    vim.list_extend(cmd_parts, { "sshpass", "-p", password })
  end
  vim.list_extend(cmd_parts, { "ssh" })
  if conn.port and conn.port ~= 22 then
    vim.list_extend(cmd_parts, { "-p", tostring(conn.port) })
  end
  if conn.identity_file and conn.identity_file ~= "" then
    vim.list_extend(cmd_parts, { "-i", conn.identity_file })
  end
  table.insert(cmd_parts, conn.user .. "@" .. conn.host)

  if M.config.external_terminal then
    for _, t in ipairs({ "xterm", "kitty", "alacritty", "wezterm", "gnome-terminal", "xfce4-terminal", "lxterminal", "konsole", "urxvt", "st" }) do
      if vim.fn.executable(t) == 1 then
        vim.fn.jobstart({ t, "-e", table.concat(cmd_parts, " ") }, { detach = true })
        return
      end
    end
    ui.notify("sshinator: no terminal emulator found", vim.log.levels.WARN)
    return
  end

  vim.defer_fn(function()
    vim.cmd("noautocmd belowright split")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_var(buf, "oil_disable", true)
    vim.api.nvim_buf_set_name(buf, "[sshinator] " .. name)
    vim.api.nvim_win_set_buf(0, buf)
    vim.fn.termopen(cmd_parts, { cwd = "/tmp" })
    vim.bo[buf].filetype = "sshinator-terminal"
    vim.api.nvim_buf_set_name(buf, "[sshinator] " .. name)
    vim.cmd("startinsert")
  end, 100)
end

local function do_connect(name, password)
  local conn = get_connection(name)
  if not conn then
    ui.notify("sshinator: connection '" .. name .. "' not found", vim.log.levels.ERROR)
    return
  end

  if conn.password_auth and not password then
    ui.input({ prompt = "Password for " .. name, mask = true }, function(pw)
      if not pw then
        ui.notify("sshinator: password required, connection cancelled", vim.log.levels.WARN)
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
            ui.notify("sshinator: authentication failed, connection cancelled", vim.log.levels.WARN)
            return
          end
          do_connect(name, pw)
        end)
        return
      end
      ui.notify("sshinator: " .. err, vim.log.levels.ERROR)
      return
    end

    ui.notify("sshinator: mounted '" .. name .. "' at " .. mount_point, vim.log.levels.INFO)

    if M.config.auto_chdir then
      vim.schedule(function()
        vim.fn.chdir(mount_point)
        vim.cmd("noautocmd edit " .. vim.fn.fnameescape(mount_point))
      end)
    else
      vim.schedule(function()
        vim.cmd("noautocmd edit " .. vim.fn.fnameescape(mount_point))
      end)
    end

    open_ssh_terminal(name, password)
  end)
end

function M.add_connection(opts)
  opts = opts or {}
  local fields = {
    { key = "name", prompt = "Connection Name", default = opts.name or "", required = true },
    { key = "host", prompt = "Host", default = opts.host or "", required = true },
    { key = "user", prompt = "User", default = opts.user or vim.env.USER or "", required = true },
    { key = "port", prompt = "Port", default = function(results, cb) detect_ssh_port(results.host, cb) end, async_default = true },
    { key = "remote_path", prompt = "Remote Path", default = opts.remote_path or "." },
    { key = "identity_file", prompt = "Identity File (leave empty to skip)", default = opts.identity_file or "" },
  }

  ui.input_chain(fields, function(results)
    if not results then return end

    ui.confirm({ prompt = "Use password auth?" }, function(password_auth)
      if password_auth == nil then return end

      local conn = {
        name = results.name,
        host = results.host,
        user = results.user,
        port = tonumber(results.port) or 22,
        remote_path = results.remote_path or ".",
        identity_file = results.identity_file ~= "" and results.identity_file or nil,
        password_auth = password_auth == true,
      }

      local cfg = M._load_config()
      for _, c in ipairs(cfg.connections) do
        if c.name == conn.name then
          ui.notify("sshinator: connection '" .. conn.name .. "' already exists", vim.log.levels.WARN)
          return
        end
      end
      table.insert(cfg.connections, conn)
      save_config(cfg)

      ui.confirm({ prompt = "Test connection?" }, function(test)
        if test == nil or test == false then
          ui.notify("sshinator: added connection '" .. conn.name .. "'", vim.log.levels.INFO)
          return
        end

        local test_args = { "ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no", "-p", tostring(conn.port), "-l", conn.user, conn.host, "exit" }
        if conn.identity_file then
          vim.list_extend(test_args, { "-i", conn.identity_file })
        end

        if conn.password_auth then
          ui.input({ prompt = "Password for " .. conn.name, mask = true }, function(password)
            if not password then
              ui.notify("sshinator: added connection '" .. conn.name .. "' (not tested)", vim.log.levels.INFO)
              return
            end
            run_cmd({ "sshpass", "-p", password, "ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no", "-p", tostring(conn.port), "-l", conn.user, conn.host, "exit" }, { timeout = 15000 }, function(r)
              if r and r.code == 0 then
                ui.notify("sshinator: connection test successful!", vim.log.levels.INFO)
              else
                ui.notify("sshinator: connection test failed", vim.log.levels.ERROR)
              end
            end)
          end)
        else
          run_cmd(test_args, { timeout = 15000 }, function(r)
            if r and r.code == 0 then
              ui.notify("sshinator: connection test successful!", vim.log.levels.INFO)
            else
              ui.notify("sshinator: connection test failed", vim.log.levels.ERROR)
            end
          end)
        end
      end)
    end)
  end)
end

function M.edit_connection(name)
  local function edit_conn(conn_name)
    local conn = get_connection(conn_name)
    if not conn then
      ui.notify("sshinator: connection not found", vim.log.levels.ERROR)
      return
    end

    local fields = {
      { key = "name", prompt = "Connection Name", default = conn.name or "", required = true },
      { key = "host", prompt = "Host", default = conn.host or "", required = true },
      { key = "user", prompt = "User", default = conn.user or vim.env.USER or "", required = true },
      { key = "port", prompt = "Port", default = tostring(conn.port or 22) },
      { key = "remote_path", prompt = "Remote Path", default = conn.remote_path or "." },
      { key = "identity_file", prompt = "Identity File (leave empty to skip)", default = conn.identity_file or "" },
    }

    ui.input_chain(fields, function(results)
      if not results then return end

      ui.confirm({ prompt = "Use password auth?" }, function(password_auth)
        if password_auth == nil then return end

        local updated = {
          name = results.name,
          host = results.host,
          user = results.user,
          port = tonumber(results.port) or 22,
          remote_path = results.remote_path or ".",
          identity_file = results.identity_file ~= "" and results.identity_file or nil,
          password_auth = password_auth == true,
        }

        local cfg = M._load_config()
        for i, c in ipairs(cfg.connections) do
          if c.name == conn_name then
            updated.name = conn_name
            cfg.connections[i] = updated
            save_config(cfg)
            ui.notify("sshinator: updated connection '" .. conn_name .. "'", vim.log.levels.INFO)
            return
          end
        end
        ui.notify("sshinator: connection not found", vim.log.levels.ERROR)
      end)
    end)
  end

  if name then
    edit_conn(name)
    return
  end

  local cfg = M._load_config()
  if #cfg.connections == 0 then
    ui.notify("sshinator: no connections configured", vim.log.levels.INFO)
    return
  end
  local items = {}
  for _, conn in ipairs(cfg.connections) do
    table.insert(items, string.format("%s (%s@%s)", conn.name, conn.user, conn.host))
  end
  ui.select(items, { prompt = "Edit Connection" }, function(choice)
    if not choice then return end
    local selected_name = choice:match("^(%S+)")
    edit_conn(selected_name)
  end)
end

function M.remove_connection(name)
  local function remove_conn(conn_name)
    local cfg = M._load_config()
    for i, conn in ipairs(cfg.connections) do
      if conn.name == conn_name then
        is_mounted(conn_name, function(mounted)
          if mounted then
            ui.confirm({ prompt = conn_name .. " is mounted. Disconnect and remove?" }, function(ok)
              if not ok then return end
              unmount_rclone(conn_name, function()
                table.remove(cfg.connections, i)
                save_config(cfg)
                ui.notify("sshinator: removed '" .. conn_name .. "'", vim.log.levels.INFO)
              end)
            end)
          else
            table.remove(cfg.connections, i)
            save_config(cfg)
            ui.notify("sshinator: removed '" .. conn_name .. "'", vim.log.levels.INFO)
          end
        end)
        return
      end
    end
    ui.notify("sshinator: connection not found", vim.log.levels.ERROR)
  end

  if name then
    remove_conn(name)
    return
  end

  local cfg = M._load_config()
  if #cfg.connections == 0 then
    ui.notify("sshinator: no connections configured", vim.log.levels.INFO)
    return
  end
  local items = {}
  for _, conn in ipairs(cfg.connections) do
    table.insert(items, string.format("%s (%s@%s)", conn.name, conn.user, conn.host))
  end
  ui.select(items, { prompt = "Remove Connection" }, function(choice)
    if not choice then return end
    local selected_name = choice:match("^(%S+)")
    remove_conn(selected_name)
  end)
end

function M.connect(name)
  if name then
    do_connect(name)
    return
  end

  local cfg = M._load_config()
  if #cfg.connections == 0 then
    ui.notify("sshinator: no connections configured. Use :SshinatorAdd first.", vim.log.levels.INFO)
    return
  end
  local items = {}
  for _, conn in ipairs(cfg.connections) do
    local auth = conn.password_auth and " [password]" or ""
    table.insert(items, string.format("%s (%s@%s:%d)%s", conn.name, conn.user, conn.host, conn.port or 22, auth))
  end
  ui.select(items, { prompt = "Connect To" }, function(choice)
    if not choice then return end
    local selected_name = choice:match("^(%S+)")
    do_connect(selected_name)
  end)
end

function M.disconnect(name)
  local function disconnect_conn(conn_name)
    unmount_rclone(conn_name, function(ok, err)
      if ok then
        ui.notify("sshinator: disconnected '" .. conn_name .. "'", vim.log.levels.INFO)
      else
        ui.notify("sshinator: " .. (err or "disconnect failed"), vim.log.levels.ERROR)
      end
    end)
  end

  if name then
    disconnect_conn(name)
    return
  end

  list_mounted(function(mounted)
    if vim.tbl_isempty(mounted) then
      ui.notify("sshinator: no active mounts", vim.log.levels.INFO)
      return
    end
    local items = {}
    for mount_name, path in pairs(mounted) do
      table.insert(items, string.format("%s (%s)", mount_name, path))
    end
    ui.select(items, { prompt = "Disconnect" }, function(choice)
      if not choice then return end
      local selected_name = choice:match("^(%S+)")
      disconnect_conn(selected_name)
    end)
  end)
end

function M.disconnect_all()
  list_mounted(function(mounted)
    local count = 0
    local pending = 0
    for _, _ in pairs(mounted) do
      pending = pending + 1
    end
    if pending == 0 then
      ui.notify("sshinator: no active mounts", vim.log.levels.INFO)
      return
    end
    for conn_name, _ in pairs(mounted) do
      unmount_rclone(conn_name, function(ok)
        if ok then count = count + 1 end
        pending = pending - 1
        if pending == 0 then
          ui.notify("sshinator: disconnected " .. count .. " connection(s)", vim.log.levels.INFO)
        end
      end)
    end
  end)
end

function M.reconnect(name)
  local function reconnect_conn(conn_name)
    unmount_rclone(conn_name, function(ok)
      if not ok then
        ui.notify("sshinator: unmount failed during reconnect", vim.log.levels.ERROR)
        return
      end
      vim.defer_fn(function()
        do_connect(conn_name)
      end, 100)
    end)
  end

  if name then
    reconnect_conn(name)
    return
  end

  list_mounted(function(mounted)
    if vim.tbl_isempty(mounted) then
      ui.notify("sshinator: no active mounts to reconnect", vim.log.levels.INFO)
      return
    end
    local items = {}
    for mount_name, path in pairs(mounted) do
      table.insert(items, string.format("%s (%s)", mount_name, path))
    end
    ui.select(items, { prompt = "Reconnect" }, function(choice)
      if not choice then return end
      local selected_name = choice:match("^(%S+)")
      reconnect_conn(selected_name)
    end)
  end)
end

function M.status()
  local cfg = M._load_config()
  if #cfg.connections == 0 then
    ui.notify("sshinator: no connections configured", vim.log.levels.INFO)
    return
  end
  list_mounted(function(mounted)
    vim.schedule(function()
      ui.status_window(cfg.connections, mounted)
    end)
  end)
end

function M.list_connections()
  local cfg = M._load_config()
  if #cfg.connections == 0 then
    ui.notify("sshinator: no connections configured", vim.log.levels.INFO)
    return
  end

  local items = {}
  for _, conn in ipairs(cfg.connections) do
    local auth = conn.password_auth and " [password]" or ""
    table.insert(items, string.format("%s (%s@%s:%d)%s", conn.name, conn.user, conn.host, conn.port or 22, auth))
  end

  ui.select(items, { prompt = "Connections" }, function(choice)
    if not choice then return end
    local name = choice:match("^(%S+)")
    local actions = { "Connect", "Disconnect", "Reconnect", "Edit", "Status", "Remove" }
    ui.select(actions, { prompt = name .. " - Action" }, function(action)
      if not action then return end
      if action == "Connect" then
        do_connect(name)
      elseif action == "Disconnect" then
        unmount_rclone(name, function(ok, err)
          if ok then
            ui.notify("sshinator: disconnected '" .. name .. "'", vim.log.levels.INFO)
          else
            ui.notify("sshinator: " .. (err or "disconnect failed"), vim.log.levels.ERROR)
          end
        end)
      elseif action == "Reconnect" then
        unmount_rclone(name, function(ok)
          if not ok then return end
          vim.defer_fn(function()
            do_connect(name)
          end, 100)
        end)
      elseif action == "Edit" then
        M.edit_connection(name)
      elseif action == "Status" then
        is_mounted(name, function(mounted)
          local dir = mount_dir(name)
          local msg = mounted and string.format("MOUNTED at %s", dir) or "not mounted"
          ui.notify("sshinator: " .. name .. " - " .. msg, vim.log.levels.INFO)
        end)
      elseif action == "Remove" then
        local cfg2 = M._load_config()
        for i, conn in ipairs(cfg2.connections) do
          if conn.name == name then
            is_mounted(name, function(mounted)
              if mounted then
                unmount_rclone(name, function()
                  table.remove(cfg2.connections, i)
                  save_config(cfg2)
                  ui.notify("sshinator: removed '" .. name .. "'", vim.log.levels.INFO)
                end)
              else
                table.remove(cfg2.connections, i)
                save_config(cfg2)
                ui.notify("sshinator: removed '" .. name .. "'", vim.log.levels.INFO)
              end
            end)
            return
          end
        end
      end
    end)
  end)
end

function M.sudo_write()
  local buf_path = vim.fn.expand("%:p")
  local mount_base = M.config.mount_base
    or vim.fn.expand("~/.local/share")
  mount_base = mount_base .. "/sshinator/mounts/"
  if not buf_path:find(mount_base, 1, true) then
    ui.notify("sshinator: current file is not in a sshinator mount", vim.log.levels.WARN)
    return
  end

  local relative = buf_path:sub(#mount_base + 1)
  local conn_name = relative:match("^([^/]+)")
  local remote_file = relative:sub(#conn_name + 1)

  if not conn_name or not remote_file or remote_file == "" then
    ui.notify("sshinator: could not determine connection or remote path", vim.log.levels.ERROR)
    return
  end

  local conn = get_connection(conn_name)
  if not conn then
    ui.notify("sshinator: connection not found", vim.log.levels.ERROR)
    return
  end

  local tmp_file = vim.fn.tempname()
  vim.cmd("silent write " .. vim.fn.fnameescape(tmp_file))

  local remote_path = conn.remote_path
  if remote_path == "." or remote_path == "" then
    remote_path = "~"
  end
  remote_path = remote_path .. remote_file

  ui.input({ prompt = "Sudo password for " .. conn_name, mask = true }, function(password)
    if not password then
      vim.fn.delete(tmp_file)
      ui.notify("sshinator: sudo write cancelled", vim.log.levels.WARN)
      return
    end

    local cmd = string.format(
      "sshpass -p %q scp -o StrictHostKeyChecking=no -P %d %s %s@%s:/tmp/sshinator_sudo_tmp && sshpass -p %q ssh -o StrictHostKeyChecking=no -p %d %s@%s 'echo %q | sudo -S mv /tmp/sshinator_sudo_tmp %s'",
      password,
      conn.port or 22,
      tmp_file,
      conn.user,
      conn.host,
      password,
      conn.port or 22,
      conn.user,
      conn.host,
      password,
      remote_path
    )

    vim.fn.jobstart(cmd, {
      on_exit = function(_, code)
        vim.fn.delete(tmp_file)
        vim.schedule(function()
          if code == 0 then
            ui.notify("sshinator: file written with sudo", vim.log.levels.INFO)
            vim.cmd("edit!")
          else
            ui.notify("sshinator: sudo write failed (exit code " .. code .. ")", vim.log.levels.ERROR)
          end
        end)
      end,
    })
  end)
end

return M
