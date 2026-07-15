local M = {}
local rpc = require("sshinator.rpc")
local ui = require("sshinator.ui")

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
      ui.notify("sshinator: " .. err, vim.log.levels.ERROR)
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
    { key = "port", prompt = "Port", default = tostring(opts.port or 22) },
    { key = "remote_path", prompt = "Remote Path", default = opts.remote_path or "." },
    { key = "identity_file", prompt = "Identity File (leave empty to skip)" , default = opts.identity_file or "" },
    { key = "password_auth", prompt = "Use password auth? (y/n)", default = "n" },
  }

  ui.input_chain(fields, function(results)
    if not results then return end

    local conn = {
      name = results.name,
      host = results.host,
      user = results.user,
      port = tonumber(results.port) or 22,
      remote_path = results.remote_path or ".",
      identity_file = results.identity_file ~= "" and results.identity_file or nil,
      password_auth = results.password_auth and results.password_auth:lower() == "y",
    }

    local c = get_client()
    c:call("add_connection", conn, function(err, result)
      if err then
        ui.notify("sshinator: " .. err, vim.log.levels.ERROR)
      else
        ui.notify("sshinator: added connection '" .. conn.name .. "'", vim.log.levels.INFO)
      end
    end)
  end)
end

function M.remove_connection()
  local c = get_client()
  c:call("list_connections", {}, function(err, connections)
    if err then
      ui.notify("sshinator: " .. err, vim.log.levels.ERROR)
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
      local name = choice:match("^(%S+)")
      c:call("remove_connection", { name = name }, function(err2, result)
        if err2 then
          ui.notify("sshinator: " .. err2, vim.log.levels.ERROR)
        else
          ui.notify("sshinator: removed '" .. name .. "'", vim.log.levels.INFO)
        end
      end)
    end)
  end)
end

local function do_connect(c, name)
  c:call("connect", { name = name }, function(err, result)
    if err then
      ui.notify("sshinator: " .. err, vim.log.levels.ERROR)
      return
    end

    if result.needs_password then
      ui.password({ prompt = "Password for " .. name }, function(password)
        if not password then
          ui.notify("sshinator: password required, connection cancelled", vim.log.levels.WARN)
          return
        end
        c:call("connect_with_password", { name = name, password = password }, function(err2, result2)
          if err2 then
            ui.notify("sshinator: " .. err2, vim.log.levels.ERROR)
          else
            ui.notify("sshinator: mounted '" .. name .. "' at " .. result2.mount_point, vim.log.levels.INFO)
            vim.schedule(function()
              vim.cmd("edit " .. vim.fn.fnameescape(result2.mount_point))
            end)
          end
        end)
      end)
      return
    end

    ui.notify("sshinator: mounted '" .. name .. "' at " .. result.mount_point, vim.log.levels.INFO)
    vim.schedule(function()
      vim.cmd("edit " .. vim.fn.fnameescape(result.mount_point))
    end)
  end)
end

function M.connect()
  local c = get_client()
  c:call("list_connections", {}, function(err, connections)
    if err then
      ui.notify("sshinator: " .. err, vim.log.levels.ERROR)
      return
    end
    if not connections or #connections == 0 then
      ui.notify("sshinator: no connections configured. Use :SshinatorAdd first.", vim.log.levels.INFO)
      return
    end
    local items = {}
    for _, conn in ipairs(connections) do
      local auth = conn.password_auth and " [password]" or ""
      table.insert(items, string.format("%s (%s@%s:%d)%s", conn.name, conn.user, conn.host, conn.port, auth))
    end
    ui.select(items, { prompt = "Connect To" }, function(choice)
      if not choice then return end
      local name = choice:match("^(%S+)")
      do_connect(c, name)
    end)
  end)
end

function M.disconnect()
  local c = get_client()
  c:call("list_mounted", {}, function(err, mounted)
    if err then
      ui.notify("sshinator: " .. err, vim.log.levels.ERROR)
      return
    end
    if not mounted or vim.tbl_isempty(mounted) then
      ui.notify("sshinator: no active mounts", vim.log.levels.INFO)
      return
    end
    local items = {}
    for name, path in pairs(mounted) do
      table.insert(items, string.format("%s (%s)", name, path))
    end
    ui.select(items, { prompt = "Disconnect" }, function(choice)
      if not choice then return end
      local name = choice:match("^(%S+)")
      c:call("disconnect", { name = name }, function(err2, result)
        if err2 then
          ui.notify("sshinator: " .. err2, vim.log.levels.ERROR)
        else
          ui.notify("sshinator: disconnected '" .. name .. "'", vim.log.levels.INFO)
        end
      end)
    end)
  end)
end

function M.disconnect_all()
  local c = get_client()
  c:call("disconnect_all", {}, function(err, result)
    if err then
      ui.notify("sshinator: " .. err, vim.log.levels.ERROR)
    else
      ui.notify("sshinator: all connections disconnected", vim.log.levels.INFO)
    end
  end)
end

function M.status()
  local c = get_client()
  c:call("list_connections", {}, function(err, connections)
    if err then
      ui.notify("sshinator: " .. err, vim.log.levels.ERROR)
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

function M.list_connections()
  local c = get_client()
  c:call("list_connections", {}, function(err, connections)
    if err then
      ui.notify("sshinator: " .. err, vim.log.levels.ERROR)
      return
    end
    if not connections or #connections == 0 then
      ui.notify("sshinator: no connections configured", vim.log.levels.INFO)
      return
    end
    local items = {}
    for _, conn in ipairs(connections) do
      local auth = conn.password_auth and " [password]" or ""
      table.insert(items, string.format("%s (%s@%s:%d)%s", conn.name, conn.user, conn.host, conn.port, auth))
    end
    ui.select(items, { prompt = "Connections" }, function(choice)
      if not choice then return end
      local name = choice:match("^(%S+)")
      local actions = {
        "Connect",
        "Disconnect",
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

return M
