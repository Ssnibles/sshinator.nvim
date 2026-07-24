local M = {}
local rpc = require("sshinator.rpc")
local ui = require("sshinator.ui")

local client = nil
local binary_path = nil

local config = {
  auto_check_deps = true,
  notify_duration = 5000,
  request_timeout = 30000,
}

function M.get_binary_path()
  if binary_path then
    return binary_path
  end
  local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
  local binary = plugin_root .. "/bin/sshinator"
  if vim.fn.executable(binary) == 0 then
    binary = "sshinator"
  end
  if vim.fn.executable(binary) == 0 then
    return nil
  end
  binary_path = binary
  return binary_path
end

function M._get_client()
  return client
end

local function get_client()
  if client and client:is_running() then
    return client
  end
  local binary = M.get_binary_path()
  if not binary then
    return nil, "sshinator binary not found. Run 'make build' first."
  end
  client = rpc.new_client(binary, { request_timeout = config.request_timeout })
  return client
end

function M.setup(opts)
  opts = opts or {}
  config.auto_check_deps = opts.auto_check_deps ~= false
  config.notify_duration = opts.notify_duration or 5000
  config.request_timeout = opts.request_timeout or 60000

  ui.configure({
    notify_duration = config.notify_duration,
  })

  if config.auto_check_deps then
    vim.defer_fn(function()
      M.check_deps()
    end, 1000)
  end
end

local function detect_ssh_port(host)
  if not host or host == "" then
    return 22
  end
  if vim.fn.executable("ssh") == 0 then
    return 22
  end
  local ok, output = pcall(vim.fn.system, { "ssh", "-G", host })
  if not ok or vim.v.shell_error ~= 0 or not output or output == "" then
    return 22
  end
  for line in output:gmatch("[^\r\n]+") do
    local port = line:lower():match("^port%s+(%d+)%s*$")
    if port then
      return tonumber(port) or 22
    end
  end
  return 22
end

function M.check_deps()
  local c, err = get_client()
  if not c then
    ui.notify("sshinator: " .. err, vim.log.levels.ERROR)
    return
  end
  c:call("check_deps", {}, function(call_err, result)
    if call_err then
      ui.notify("sshinator: " .. call_err, vim.log.levels.ERROR)
      return
    end
    if not result.ok then
      local missing = table.concat(result.missing, ", ")
      ui.notify("sshinator: missing dependencies: " .. missing, vim.log.levels.WARN)
    end
  end)
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

      local c, client_err = get_client()
      if not c then
        ui.notify("sshinator: " .. client_err, vim.log.levels.ERROR)
        return
      end

      local function handle_test_result(test_err, test_result)
        if test_err then
          ui.notify("sshinator: test failed: " .. test_err, vim.log.levels.ERROR)
        elseif test_result.success then
          ui.notify("sshinator: connection test successful!", vim.log.levels.INFO)
        else
          ui.notify("sshinator: connection test failed: " .. (test_result.error or "unknown error"), vim.log.levels.ERROR)
        end
      end

      local function save_and_test()
        c:call("add_connection", conn, function(call_err, result)
          if call_err then
            ui.notify("sshinator: " .. call_err, vim.log.levels.ERROR)
            return
          end

          ui.confirm({ prompt = "Test connection?" }, function(test)
            if test == nil or test == false then
              ui.notify("sshinator: added connection '" .. conn.name .. "'", vim.log.levels.INFO)
              return
            end

            local test_params = {
              host = conn.host,
              port = conn.port,
              user = conn.user,
              identity_file = conn.identity_file,
            }

            if conn.password_auth then
              ui.input({ prompt = "Password for " .. conn.name, mask = true }, function(password)
                if not password then
                  ui.notify("sshinator: added connection '" .. conn.name .. "' (not tested)", vim.log.levels.INFO)
                  return
                end
                test_params.password = password
                c:call("test_connection", test_params, handle_test_result)
              end)
            else
              c:call("test_connection", test_params, handle_test_result)
            end
          end)
        end)
      end

      save_and_test()
    end)
  end)
end

function M.edit_connection(name)
  local c, err = get_client()
  if not c then
    ui.notify("sshinator: " .. err, vim.log.levels.ERROR)
    return
  end
  
  -- Helper function to edit a specific connection
  local function edit_conn(conn_name)
    c:call("get_connection", { name = conn_name }, function(call_err, conn)
      if call_err then
        ui.notify("sshinator: " .. call_err, vim.log.levels.ERROR)
        return
      end
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

          c:call("update_connection", { name = conn_name, updated = updated }, function(err2, result)
            if err2 then
              ui.notify("sshinator: " .. err2, vim.log.levels.ERROR)
            else
              ui.notify("sshinator: updated connection '" .. conn_name .. "'", vim.log.levels.INFO)
            end
          end)
        end)
      end)
    end)
  end
  
  -- If name provided, edit directly
  if name then
    edit_conn(name)
    return
  end
  
  -- Otherwise, show picker
  c:call("list_connections", {}, function(call_err, connections)
    if call_err then
      ui.notify("sshinator: " .. call_err, vim.log.levels.ERROR)
      return
    end
    if not connections or #connections == 0 then
      ui.notify("sshinator: no connections configured", vim.log.levels.INFO)
      return
    end
    local items = {}
    for _, conn in ipairs(connections) do
      table.insert(items, string.format("%s (%s@%s)", conn.name, conn.user, conn.host))
    end
    ui.select(items, { prompt = "Edit Connection" }, function(choice)
      if not choice then return end
      local selected_name = choice:match("^(%S+)")
      edit_conn(selected_name)
    end)
  end)
end

function M.remove_connection(name)
  local c, err = get_client()
  if not c then
    ui.notify("sshinator: " .. err, vim.log.levels.ERROR)
    return
  end
  
  -- If name provided, remove directly
  if name then
    c:call("remove_connection", { name = name }, function(err2, result)
      if err2 then
        ui.notify("sshinator: " .. err2, vim.log.levels.ERROR)
      else
        ui.notify("sshinator: removed '" .. name .. "'", vim.log.levels.INFO)
      end
    end)
    return
  end
  
  c:call("list_connections", {}, function(call_err, connections)
    if call_err then
      ui.notify("sshinator: " .. call_err, vim.log.levels.ERROR)
      return
    end
    if not connections or #connections == 0 then
      ui.notify("sshinator: no connections configured", vim.log.levels.INFO)
      return
    end
    local items = {}
    for _, conn in ipairs(connections) do
      table.insert(items, string.format("%s (%s@%s)", conn.name, conn.user, conn.host))
    end
    ui.select(items, { prompt = "Remove Connection" }, function(choice)
      if not choice then return end
      local selected_name = choice:match("^(%S+)")
      c:call("remove_connection", { name = selected_name }, function(err2, result)
        if err2 then
          ui.notify("sshinator: " .. err2, vim.log.levels.ERROR)
        else
          ui.notify("sshinator: removed '" .. selected_name .. "'", vim.log.levels.INFO)
        end
      end)
    end)
  end)
end

local function do_connect(c, name)
  c:call("connect", { name = name }, function(call_err, result)
    if call_err then
      ui.notify("sshinator: " .. call_err, vim.log.levels.ERROR)
      return
    end

    if not result then
      ui.notify("sshinator: no response from server", vim.log.levels.ERROR)
      return
    end

    if result.needs_password then
      ui.input({ prompt = "Password for " .. name, mask = true }, function(password)
        if not password then
          ui.notify("sshinator: password required, connection cancelled", vim.log.levels.WARN)
          return
        end
        c:call("connect_with_password", { name = name, password = password }, function(err2, result2)
          if err2 then
            ui.notify("sshinator: " .. err2, vim.log.levels.ERROR)
            return
          end
          if not result2 then
            ui.notify("sshinator: no response from server", vim.log.levels.ERROR)
            return
          end
          ui.notify("sshinator: mounted '" .. name .. "' at " .. result2.mount_point, vim.log.levels.INFO)
          vim.schedule(function()
            vim.cmd("edit " .. vim.fn.fnameescape(result2.mount_point))
          end)
        end)
      end)
      return
    end

    if not result.mount_point then
      ui.notify("sshinator: connection succeeded but no mount point returned", vim.log.levels.ERROR)
      return
    end

    ui.notify("sshinator: mounted '" .. name .. "' at " .. result.mount_point, vim.log.levels.INFO)
    vim.schedule(function()
      vim.cmd("edit " .. vim.fn.fnameescape(result.mount_point))
    end)
  end)
end

function M.connect(name)
  local c, err = get_client()
  if not c then
    ui.notify("sshinator: " .. err, vim.log.levels.ERROR)
    return
  end
  
  -- If name provided, connect directly
  if name then
    do_connect(c, name)
    return
  end
  
  c:call("list_connections", {}, function(call_err, connections)
    if call_err then
      ui.notify("sshinator: " .. call_err, vim.log.levels.ERROR)
      return
    end
    if not connections or #connections == 0 then
      ui.notify("sshinator: no connections configured. Use :SshinatorAdd first.", vim.log.levels.INFO)
      return
    end
    local items = {}
    for _, conn in ipairs(connections) do
      local auth = conn.password_auth and " [password]" or ""
      table.insert(items, string.format("%s (%s@%s:%d)%s", conn.name, conn.user, conn.host, conn.port or 22, auth))
    end
    ui.select(items, { prompt = "Connect To" }, function(choice)
      if not choice then return end
      local selected_name = choice:match("^(%S+)")
      do_connect(c, selected_name)
    end)
  end)
end

function M.disconnect(name)
  local c, err = get_client()
  if not c then
    ui.notify("sshinator: " .. err, vim.log.levels.ERROR)
    return
  end
  
  -- If name provided, disconnect directly
  if name then
    c:call("disconnect", { name = name }, function(err2, result)
      if err2 then
        ui.notify("sshinator: " .. err2, vim.log.levels.ERROR)
      else
        ui.notify("sshinator: disconnected '" .. name .. "'", vim.log.levels.INFO)
      end
    end)
    return
  end
  
  c:call("list_mounted", {}, function(call_err, mounted)
    if call_err then
      ui.notify("sshinator: " .. call_err, vim.log.levels.ERROR)
      return
    end
    if not mounted or vim.tbl_isempty(mounted) then
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
      c:call("disconnect", { name = selected_name }, function(err2, result)
        if err2 then
          ui.notify("sshinator: " .. err2, vim.log.levels.ERROR)
        else
          ui.notify("sshinator: disconnected '" .. selected_name .. "'", vim.log.levels.INFO)
        end
      end)
    end)
  end)
end

function M.disconnect_all()
  local c, err = get_client()
  if not c then
    ui.notify("sshinator: " .. err, vim.log.levels.ERROR)
    return
  end
  c:call("disconnect_all", {}, function(call_err, result)
    if call_err then
      ui.notify("sshinator: " .. call_err, vim.log.levels.ERROR)
    else
      ui.notify("sshinator: all connections disconnected", vim.log.levels.INFO)
    end
  end)
end

function M.status()
  local c, err = get_client()
  if not c then
    ui.notify("sshinator: " .. err, vim.log.levels.ERROR)
    return
  end
  c:call("list_connections", {}, function(call_err, connections)
    if call_err then
      ui.notify("sshinator: " .. call_err, vim.log.levels.ERROR)
      return
    end
    if not connections or #connections == 0 then
      ui.notify("sshinator: no connections configured", vim.log.levels.INFO)
      return
    end
    c:call("list_mounted", {}, function(err2, mounted)
      if err2 then
        ui.notify("sshinator: " .. err2, vim.log.levels.ERROR)
        return
      end
      mounted = mounted or {}
      vim.schedule(function()
        ui.status_window(connections, mounted)
      end)
    end)
  end)
end

function M.reconnect(name)
  local c, err = get_client()
  if not c then
    ui.notify("sshinator: " .. err, vim.log.levels.ERROR)
    return
  end
  
  -- If name provided, reconnect directly
  if name then
    c:call("disconnect", { name = name }, function(err2)
      if err2 then
        ui.notify("sshinator: disconnect failed: " .. err2, vim.log.levels.ERROR)
        return
      end
      vim.defer_fn(function()
        do_connect(c, name)
      end, 100)
    end)
    return
  end
  
  c:call("list_mounted", {}, function(call_err, mounted)
    if call_err then
      ui.notify("sshinator: " .. call_err, vim.log.levels.ERROR)
      return
    end
    if not mounted or vim.tbl_isempty(mounted) then
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
      c:call("disconnect", { name = selected_name }, function(err2)
        if err2 then
          ui.notify("sshinator: disconnect failed: " .. err2, vim.log.levels.ERROR)
          return
        end
        vim.defer_fn(function()
          do_connect(c, selected_name)
        end, 100)
      end)
    end)
  end)
end

function M.list_connections()
  local c, err = get_client()
  if not c then
    ui.notify("sshinator: " .. err, vim.log.levels.ERROR)
    return
  end
  c:call("list_connections", {}, function(call_err, connections)
    if call_err then
      ui.notify("sshinator: " .. call_err, vim.log.levels.ERROR)
      return
    end
    if not connections or #connections == 0 then
      ui.notify("sshinator: no connections configured", vim.log.levels.INFO)
      return
    end
    local items = {}
    for _, conn in ipairs(connections) do
      local auth = conn.password_auth and " [password]" or ""
      table.insert(items, string.format("%s (%s@%s:%d)%s", conn.name, conn.user, conn.host, conn.port or 22, auth))
    end
    ui.select(items, { prompt = "Connections" }, function(choice)
      if not choice then return end
      local name = choice:match("^(%S+)")
      local actions = {
        "Connect",
        "Disconnect",
        "Reconnect",
        "Edit",
        "Status",
        "Remove",
      }
      ui.select(actions, { prompt = name .. " - Action" }, function(action)
        if not action then return end
        if action == "Connect" then
          do_connect(c, name)
        elseif action == "Disconnect" then
          c:call("disconnect", { name = name }, function(err2, result)
            if err2 then
              ui.notify("sshinator: " .. err2, vim.log.levels.ERROR)
            else
              ui.notify("sshinator: disconnected '" .. name .. "'", vim.log.levels.INFO)
            end
          end)
        elseif action == "Reconnect" then
          c:call("disconnect", { name = name }, function(err2)
            if err2 then
              ui.notify("sshinator: disconnect failed: " .. err2, vim.log.levels.ERROR)
              return
            end
            vim.defer_fn(function()
              do_connect(c, name)
            end, 100)
          end)
        elseif action == "Edit" then
          M.edit_connection(name)
        elseif action == "Status" then
          c:call("status", { name = name }, function(err2, result)
            if err2 then
              ui.notify("sshinator: " .. err2, vim.log.levels.ERROR)
            else
              local msg = result.mounted
                and string.format("MOUNTED at %s", result.mount_point)
                or "not mounted"
              ui.notify("sshinator: " .. name .. " - " .. msg, vim.log.levels.INFO)
            end
          end)
        elseif action == "Remove" then
          c:call("remove_connection", { name = name }, function(err2, result)
            if err2 then
              ui.notify("sshinator: " .. err2, vim.log.levels.ERROR)
            else
              ui.notify("sshinator: removed '" .. name .. "'", vim.log.levels.INFO)
            end
          end)
        end
      end)
    end)
  end)
end

function M.sudo_write()
  local buf_path = vim.fn.expand("%:p")
  
  -- Check if file is in a sshinator mount
  local mount_base = vim.fn.expand("~/.local/share/sshinator/mounts/")
  if not buf_path:find(mount_base, 1, true) then
    ui.notify("sshinator: current file is not in a sshinator mount", vim.log.levels.WARN)
    return
  end
  
  -- Extract connection name and remote path
  local relative = buf_path:sub(#mount_base + 1)
  local conn_name = relative:match("^([^/]+)")
  local remote_file = relative:sub(#conn_name + 1)
  
  if not conn_name or not remote_file or remote_file == "" then
    ui.notify("sshinator: could not determine connection or remote path", vim.log.levels.ERROR)
    return
  end
  
  local c, err = get_client()
  if not c then
    ui.notify("sshinator: " .. err, vim.log.levels.ERROR)
    return
  end
  
  -- Get connection details
  c:call("get_connection", { name = conn_name }, function(call_err, conn)
    if call_err then
      ui.notify("sshinator: " .. call_err, vim.log.levels.ERROR)
      return
    end
    if not conn then
      ui.notify("sshinator: connection not found", vim.log.levels.ERROR)
      return
    end
    
    -- Save buffer to temporary file
    local tmp_file = vim.fn.tempname()
    vim.cmd("silent write " .. vim.fn.fnameescape(tmp_file))
    
    -- Build remote path
    local remote_path = conn.remote_path
    if remote_path == "." or remote_path == "" then
      remote_path = "~"
    end
    remote_path = remote_path .. remote_file
    
    -- Use scp with sudo
    ui.input({ prompt = "Sudo password for " .. conn.name, mask = true }, function(password)
      if not password then
        vim.fn.delete(tmp_file)
        ui.notify("sshinator: sudo write cancelled", vim.log.levels.WARN)
        return
      end
      
      local scp_cmd = string.format(
        "sshpass -p %q scp -o StrictHostKeyChecking=no -P %d %s %s@%s:/tmp/sshinator_sudo_tmp && " ..
        "sshpass -p %q ssh -o StrictHostKeyChecking=no -p %d %s@%s 'echo %q | sudo -S mv /tmp/sshinator_sudo_tmp %s'",
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
      
      vim.fn.jobstart(scp_cmd, {
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
  end)
end

return M
