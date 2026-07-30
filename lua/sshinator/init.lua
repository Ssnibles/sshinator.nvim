local M = {}
local ui = require("sshinator.ui")

M.config = {
  auto_check_deps = true,
  notify_duration = 5000,
  request_timeout = 30000,
  external_terminal = false,
  auto_chdir = true,
}

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

local function run_cmd(args, opts)
  opts = opts or {}
  local result = { stdout = "", stderr = "", code = nil }
  local done = false

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
      result.code = code
      done = true
    end,
  }
  if opts.env then job_opts.env = opts.env end

  local job_id = vim.fn.jobstart(args, job_opts)
  if not job_id or job_id <= 0 then
    return nil, "failed to start process"
  end

  vim.wait(opts.timeout or 15000, function() return done end, 100)

  if not done then
    vim.fn.jobstop(job_id)
    return nil, "timeout"
  end

  return result
end

function M.setup(opts)
  opts = opts or {}
  M.config.auto_check_deps = opts.auto_check_deps ~= false
  M.config.external_terminal = opts.external_terminal or false
  M.config.auto_chdir = opts.auto_chdir ~= false
  M.config.notify_duration = opts.notify_duration or 5000
  M.config.request_timeout = opts.request_timeout or 60000

  ui.configure({ notify_duration = M.config.notify_duration })

  if M.config.auto_check_deps then
    vim.defer_fn(M.check_deps, 1000)
  end
end

local function detect_ssh_port(host)
  if not host or host == "" or vim.fn.executable("ssh") == 0 then
    return 22
  end
  local ok, output = pcall(vim.fn.system, { "ssh", "-G", host })
  if not ok or vim.v.shell_error ~= 0 then return 22 end
  for line in (output or ""):gmatch("(.-)\n") do
    local port = line:lower():match("^port%s+(%d+)%s*$")
    if port then return tonumber(port) end
  end
  return 22
end

function M.check_deps()
  local missing = {}
  for _, cmd in ipairs({ "ssh", "sshfs" }) do
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
  local base = vim.env.XDG_DATA_HOME or (vim.fn.expand("~") .. "/.local/share")
  return base .. "/sshinator/mounts/" .. name:gsub("[%s/\\:]", "_")
end

local function is_mounted(name)
  local dir = mount_dir(name)
  if vim.fn.isdirectory(dir) == 0 then return false end
  vim.fn.system({ "mountpoint", "-q", dir })
  return vim.v.shell_error == 0
end

local function list_mounted()
  local cfg = M._load_config()
  local result = {}
  for _, conn in ipairs(cfg.connections) do
    local dir = mount_dir(conn.name)
    vim.fn.system({ "mountpoint", "-q", dir })
    if vim.v.shell_error == 0 then
      result[conn.name] = dir
    end
  end
  return result
end

local function unmount_sshfs(name)
  local dir = mount_dir(name)
  if not is_mounted(name) then return true end
  local umount_cmd
  if vim.fn.executable("fusermount3") == 1 then
    umount_cmd = { "fusermount3", "-u", dir }
  elseif vim.fn.executable("fusermount") == 1 then
    umount_cmd = { "fusermount", "-u", dir }
  else
    umount_cmd = { "umount", dir }
  end
  local r = run_cmd(umount_cmd, { timeout = 5000 })
  if type(r) == "table" and r.code == 0 then
    vim.fn.delete(dir, "d")
    return true
  end
  return nil, "unmount failed"
end

local function is_password_error(output)
  local lower = (output or ""):lower()
  return lower:find("permission denied")
    or lower:find("password")
    or lower:find("authentication failed")
    or lower:find("publickey")
end

local function mount_sshfs(name, conn, password)
  local mount_point = mount_dir(name)
  vim.fn.mkdir(mount_point, "p")

  if is_mounted(name) then
    unmount_sshfs(name)
    vim.fn.mkdir(mount_point, "p")
  end

  local remote = (conn.remote_path or "") == "" and "." or conn.remote_path
  local args = {
    "sshfs",
    string.format("%s@%s:%s", conn.user, conn.host, remote),
    mount_point,
    "-o", "reconnect",
    "-o", "follow_symlinks",
    "-o", "ControlMaster=auto",
    "-o", string.format("ControlPath=/tmp/sshinator-%%r@%%h:%d", conn.port or 22),
  }
  if conn.port and conn.port ~= 22 then
    vim.list_extend(args, { "-p", tostring(conn.port) })
  end
  if conn.identity_file and conn.identity_file ~= "" then
    vim.list_extend(args, { "-o", "IdentityFile=" .. conn.identity_file })
  end

  local run_opts = { timeout = 15000 }

  if password then
    local askpass = vim.fn.tempname()
    local escaped = password:gsub("'", "'\\''")
    vim.fn.writefile({ "#!/bin/sh", "echo '" .. escaped .. "'" }, askpass)
    vim.fn.setfperm(askpass, "rwx------")

    local env = {}
    for k, v in pairs(vim.fn.environ()) do
      env[k] = v
    end
    env["SSH_ASKPASS"] = askpass
    env["SSH_ASKPASS_REQUIRE"] = "force"
    run_opts.env = env

    local r = run_cmd(args, run_opts)
    vim.fn.delete(askpass)

    if type(r) ~= "table" then return nil, r or "mount failed" end
    if r.code ~= 0 then
      if is_password_error(r.stderr) then
        return nil, "authentication failed"
      end
      return nil, "mount failed (exit " .. r.code .. ")"
    end
  else
    vim.list_extend(args, { "-o", "BatchMode=yes" })
    local r = run_cmd(args, run_opts)
    if type(r) ~= "table" then return nil, r or "mount failed" end
    if r.code ~= 0 then
      if is_password_error(r.stderr) then
        return nil, "authentication failed"
      end
      return nil, "mount failed (exit " .. r.code .. ")"
    end
  end

  vim.fn.system({ "mountpoint", "-q", mount_point })
  if vim.v.shell_error ~= 0 then
    return nil, "mount verification failed"
  end

  return mount_point
end

local function open_ssh_terminal(name, password)
  local conn = get_connection(name)
  if not conn then return end

  local cmd_parts = {}
  if password and password ~= "" and vim.fn.executable("sshpass") == 1 then
    vim.list_extend(cmd_parts, { "sshpass", "-p", password })
  end
  vim.list_extend(cmd_parts, { "ssh" })
  if conn.port and conn.port ~= 22 then
    vim.list_extend(cmd_parts, { "-p", tostring(conn.port) })
  end
  vim.list_extend(cmd_parts, { "-o", "ControlMaster=auto" })
  vim.list_extend(cmd_parts, { "-o", string.format("ControlPath=/tmp/sshinator-%%r@%%h:%d", conn.port or 22) })
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
    local buf = vim.api.nvim_create_buf(false, true)
    vim.b[buf].oil_disable = true
    vim.cmd("noautocmd belowright split")
    vim.api.nvim_win_set_buf(0, buf)
    vim.fn.termopen(cmd_parts, { cwd = "/tmp" })
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

  local mount_point, err = mount_sshfs(name, conn, password)
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
      vim.cmd("edit " .. vim.fn.fnameescape(mount_point))
    end)
  else
    vim.schedule(function()
      vim.cmd("edit " .. vim.fn.fnameescape(mount_point))
    end)
  end

  open_ssh_terminal(name, password)
end

function M.add_connection(opts)
  opts = opts or {}
  local fields = {
    { key = "name", prompt = "Connection Name", default = opts.name or "", required = true },
    { key = "host", prompt = "Host", default = opts.host or "", required = true },
    { key = "user", prompt = "User", default = opts.user or vim.env.USER or "", required = true },
    { key = "port", prompt = "Port", default = function(results) return tostring(opts.port or detect_ssh_port(results.host) or 22) end },
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
            local r = run_cmd({ "sshpass", "-p", password, "ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no", "-p", tostring(conn.port), "-l", conn.user, conn.host, "exit" }, { timeout = 15000 })
            if type(r) == "table" and r.code == 0 then
              ui.notify("sshinator: connection test successful!", vim.log.levels.INFO)
            else
              ui.notify("sshinator: connection test failed", vim.log.levels.ERROR)
            end
          end)
        else
          local r = run_cmd(test_args, { timeout = 15000 })
          if type(r) == "table" and r.code == 0 then
            ui.notify("sshinator: connection test successful!", vim.log.levels.INFO)
          else
            ui.notify("sshinator: connection test failed", vim.log.levels.ERROR)
          end
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
      { key = "port", prompt = "Port", default = tostring(conn.port or detect_ssh_port(conn.host) or 22) },
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
        if is_mounted(conn_name) then
          ui.confirm({ prompt = conn_name .. " is mounted. Disconnect and remove?" }, function(ok)
            if not ok then return end
            unmount_sshfs(conn_name)
            table.remove(cfg.connections, i)
            save_config(cfg)
            ui.notify("sshinator: removed '" .. conn_name .. "'", vim.log.levels.INFO)
          end)
        else
          table.remove(cfg.connections, i)
          save_config(cfg)
          ui.notify("sshinator: removed '" .. conn_name .. "'", vim.log.levels.INFO)
        end
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
    local ok, err = unmount_sshfs(conn_name)
    if ok then
      ui.notify("sshinator: disconnected '" .. conn_name .. "'", vim.log.levels.INFO)
    else
      ui.notify("sshinator: " .. (err or "disconnect failed"), vim.log.levels.ERROR)
    end
  end

  if name then
    disconnect_conn(name)
    return
  end

  local mounted = list_mounted()
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
end

function M.disconnect_all()
  local count = 0
  local cfg = M._load_config()
  for _, conn in ipairs(cfg.connections) do
    if is_mounted(conn.name) then
      unmount_sshfs(conn.name)
      count = count + 1
    end
  end
  ui.notify("sshinator: disconnected " .. count .. " connection(s)", vim.log.levels.INFO)
end

function M.reconnect(name)
  local function reconnect_conn(conn_name)
    unmount_sshfs(conn_name)
    vim.defer_fn(function()
      do_connect(conn_name)
    end, 100)
  end

  if name then
    reconnect_conn(name)
    return
  end

  local mounted = list_mounted()
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
end

function M.status()
  local cfg = M._load_config()
  if #cfg.connections == 0 then
    ui.notify("sshinator: no connections configured", vim.log.levels.INFO)
    return
  end
  local mounted = list_mounted()
  vim.schedule(function()
    ui.status_window(cfg.connections, mounted)
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
        local ok, err = unmount_sshfs(name)
        if ok then
          ui.notify("sshinator: disconnected '" .. name .. "'", vim.log.levels.INFO)
        else
          ui.notify("sshinator: " .. (err or "disconnect failed"), vim.log.levels.ERROR)
        end
      elseif action == "Reconnect" then
        unmount_sshfs(name)
        vim.defer_fn(function()
          do_connect(name)
        end, 100)
      elseif action == "Edit" then
        M.edit_connection(name)
      elseif action == "Status" then
        local dir = mount_dir(name)
        local mounted = is_mounted(name)
        local msg = mounted and string.format("MOUNTED at %s", dir) or "not mounted"
        ui.notify("sshinator: " .. name .. " - " .. msg, vim.log.levels.INFO)
      elseif action == "Remove" then
        local cfg = M._load_config()
        for i, conn in ipairs(cfg.connections) do
          if conn.name == name then
            if is_mounted(name) then unmount_sshfs(name) end
            table.remove(cfg.connections, i)
            save_config(cfg)
            ui.notify("sshinator: removed '" .. name .. "'", vim.log.levels.INFO)
            return
          end
        end
      end
    end)
  end)
end

function M.sudo_write()
  local buf_path = vim.fn.expand("%:p")
  local mount_base = vim.fn.expand("~/.local/share/sshinator/mounts/")
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
