local M = {}
local rpc = require("sshinator.rpc")
local picker = require("sshinator.picker")

local client = nil

local function get_client()
  if not client or not client:is_running() then
    local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
    local binary = plugin_root .. "/bin/sshinator"
    if vim.fn.executable(binary) == 0 then
      binary = "sshinator"
    end
    if vim.fn.executable(binary) == 0 then
      error("sshinator binary not found. Run 'make build' first.")
    end
    client = rpc.new_client(binary)
  end
  return client
end

function M.setup(opts)
  opts = opts or {}
  if opts.auto_check_deps ~= false then
    vim.defer_fn(function()
      M.check_deps()
    end, 1000)
  end
end

function M.check_deps()
  local c = get_client()
  c:call("check_deps", {}, function(err, result)
    if err then
      vim.notify("sshinator: " .. err, vim.log.levels.ERROR)
      return
    end
    if not result.ok then
      local missing = table.concat(result.missing, ", ")
      vim.notify("sshinator: missing dependencies: " .. missing, vim.log.levels.WARN)
    end
  end)
end

function M.add_connection(opts)
  opts = opts or {}
  vim.ui.input({ prompt = "Connection name: ", default = opts.name or "" }, function(name)
    if not name or name == "" then return end
    vim.ui.input({ prompt = "Host: ", default = opts.host or "" }, function(host)
      if not host or host == "" then return end
      vim.ui.input({ prompt = "User: ", default = opts.user or vim.env.USER or "" }, function(user)
        if not user or user == "" then return end
        vim.ui.input({ prompt = "Port: ", default = tostring(opts.port or 22) }, function(port)
          if not port then return end
          vim.ui.input({ prompt = "Remote path: ", default = opts.remote_path or "." }, function(remote_path)
            if not remote_path then return end
            vim.ui.input({ prompt = "Identity file (optional): ", default = opts.identity_file or "" }, function(identity_file)
              local conn = {
                name = name,
                host = host,
                user = user,
                port = tonumber(port) or 22,
                remote_path = remote_path,
                identity_file = identity_file ~= "" and identity_file or nil,
              }
              local c = get_client()
              c:call("add_connection", conn, function(err, result)
                if err then
                  vim.notify("sshinator: " .. err, vim.log.levels.ERROR)
                else
                  vim.notify("sshinator: added connection '" .. name .. "'", vim.log.levels.INFO)
                end
              end)
            end)
          end)
        end)
      end)
    end)
  end)
end

function M.remove_connection()
  local c = get_client()
  c:call("list_connections", {}, function(err, connections)
    if err then
      vim.notify("sshinator: " .. err, vim.log.levels.ERROR)
      return
    end
    if not connections or #connections == 0 then
      vim.notify("sshinator: no connections configured", vim.log.levels.INFO)
      return
    end
    local items = {}
    for _, conn in ipairs(connections) do
      table.insert(items, string.format("%s (%s@%s)", conn.name, conn.user, conn.host))
    end
    picker.select(items, { prompt = "Remove connection:" }, function(choice)
      if not choice then return end
      local name = choice:match("^(%S+)")
      c:call("remove_connection", { name = name }, function(err2, result)
        if err2 then
          vim.notify("sshinator: " .. err2, vim.log.levels.ERROR)
        else
          vim.notify("sshinator: removed '" .. name .. "'", vim.log.levels.INFO)
        end
      end)
    end)
  end)
end

function M.connect()
  local c = get_client()
  c:call("list_connections", {}, function(err, connections)
    if err then
      vim.notify("sshinator: " .. err, vim.log.levels.ERROR)
      return
    end
    if not connections or #connections == 0 then
      vim.notify("sshinator: no connections configured. Use :SshinatorAdd first.", vim.log.levels.INFO)
      return
    end
    local items = {}
    for _, conn in ipairs(connections) do
      table.insert(items, string.format("%s (%s@%s:%d)", conn.name, conn.user, conn.host, conn.port))
    end
    picker.select(items, { prompt = "Connect to:" }, function(choice)
      if not choice then return end
      local name = choice:match("^(%S+)")
      vim.notify("sshinator: connecting to '" .. name .. "'...", vim.log.levels.INFO)
      c:call("connect", { name = name }, function(err2, result)
        if err2 then
          vim.notify("sshinator: " .. err2, vim.log.levels.ERROR)
        else
          vim.notify("sshinator: mounted '" .. name .. "' at " .. result.mount_point, vim.log.levels.INFO)
          vim.schedule(function()
            vim.cmd("edit " .. result.mount_point)
          end)
        end
      end)
    end)
  end)
end

function M.disconnect()
  local c = get_client()
  c:call("list_mounted", {}, function(err, mounted)
    if err then
      vim.notify("sshinator: " .. err, vim.log.levels.ERROR)
      return
    end
    if not mounted or vim.tbl_isempty(mounted) then
      vim.notify("sshinator: no active mounts", vim.log.levels.INFO)
      return
    end
    local items = {}
    for name, path in pairs(mounted) do
      table.insert(items, string.format("%s (%s)", name, path))
    end
    picker.select(items, { prompt = "Disconnect:" }, function(choice)
      if not choice then return end
      local name = choice:match("^(%S+)")
      c:call("disconnect", { name = name }, function(err2, result)
        if err2 then
          vim.notify("sshinator: " .. err2, vim.log.levels.ERROR)
        else
          vim.notify("sshinator: disconnected '" .. name .. "'", vim.log.levels.INFO)
        end
      end)
    end)
  end)
end

function M.disconnect_all()
  local c = get_client()
  c:call("disconnect_all", {}, function(err, result)
    if err then
      vim.notify("sshinator: " .. err, vim.log.levels.ERROR)
    else
      vim.notify("sshinator: all connections disconnected", vim.log.levels.INFO)
    end
  end)
end

function M.status()
  local c = get_client()
  c:call("list_connections", {}, function(err, connections)
    if err then
      vim.notify("sshinator: " .. err, vim.log.levels.ERROR)
      return
    end
    if not connections or #connections == 0 then
      vim.notify("sshinator: no connections configured", vim.log.levels.INFO)
      return
    end
    c:call("list_mounted", {}, function(err2, mounted)
      if err2 then
        vim.notify("sshinator: " .. err2, vim.log.levels.ERROR)
        return
      end
      mounted = mounted or {}
      local lines = { "Sshinator Connections:", "" }
      for _, conn in ipairs(connections) do
        local state = mounted[conn.name] and ("MOUNTED @ " .. mounted[conn.name]) or "not mounted"
        table.insert(lines, string.format("  %s (%s@%s:%d) - %s", conn.name, conn.user, conn.host, conn.port, state))
      end
      vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
    end)
  end)
end

function M.list_connections()
  local c = get_client()
  c:call("list_connections", {}, function(err, connections)
    if err then
      vim.notify("sshinator: " .. err, vim.log.levels.ERROR)
      return
    end
    if not connections or #connections == 0 then
      vim.notify("sshinator: no connections configured", vim.log.levels.INFO)
      return
    end
    local items = {}
    for _, conn in ipairs(connections) do
      table.insert(items, string.format("%s (%s@%s:%d)", conn.name, conn.user, conn.host, conn.port))
    end
    picker.select(items, { prompt = "Connections:" }, function(choice)
      if not choice then return end
      local name = choice:match("^(%S+)")
      local actions = {
        "Connect",
        "Disconnect",
        "Status",
        "Remove",
      }
      picker.select(actions, { prompt = name .. " - Action:" }, function(action)
        if not action then return end
        if action == "Connect" then
          c:call("connect", { name = name }, function(err2, result)
            if err2 then
              vim.notify("sshinator: " .. err2, vim.log.levels.ERROR)
            else
              vim.notify("sshinator: mounted at " .. result.mount_point, vim.log.levels.INFO)
              vim.schedule(function()
                vim.cmd("edit " .. result.mount_point)
              end)
            end
          end)
        elseif action == "Disconnect" then
          c:call("disconnect", { name = name }, function(err2, result)
            if err2 then
              vim.notify("sshinator: " .. err2, vim.log.levels.ERROR)
            else
              vim.notify("sshinator: disconnected '" .. name .. "'", vim.log.levels.INFO)
            end
          end)
        elseif action == "Status" then
          c:call("status", { name = name }, function(err2, result)
            if err2 then
              vim.notify("sshinator: " .. err2, vim.log.levels.ERROR)
            else
              local msg = result.mounted
                and string.format("MOUNTED at %s", result.mount_point)
                or "not mounted"
              vim.notify("sshinator: " .. name .. " - " .. msg, vim.log.levels.INFO)
            end
          end)
        elseif action == "Remove" then
          c:call("remove_connection", { name = name }, function(err2, result)
            if err2 then
              vim.notify("sshinator: " .. err2, vim.log.levels.ERROR)
            else
              vim.notify("sshinator: removed '" .. name .. "'", vim.log.levels.INFO)
            end
          end)
        end
      end)
    end)
  end)
end

return M
