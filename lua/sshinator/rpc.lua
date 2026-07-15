local M = {}

local Client = {}
Client.__index = Client

function M.new_client(binary, opts)
  opts = opts or {}
  local self = setmetatable({}, Client)
  self.binary = binary
  self.job_id = nil
  self.request_id = 0
  self.callbacks = {}
  self.timers = {}
  self.buffer = ""
  self.request_timeout = opts.request_timeout or 60000
  self:start()
  return self
end

function Client:start()
  self.job_id = vim.fn.jobstart({ self.binary }, {
    on_stdout = function(_, data, _)
      self:handle_stdout(data)
    end,
    on_stderr = function(_, data, _)
      if data and #data > 0 and data[1] ~= "" then
        vim.schedule(function()
          vim.notify("sshinator stderr: " .. table.concat(data, "\n"), vim.log.levels.DEBUG)
        end)
      end
    end,
    on_exit = function(_, code, _)
      vim.schedule(function()
        self.job_id = nil
        for id, cb in pairs(self.callbacks) do
          if self.timers[id] then
            self.timers[id]:stop()
            self.timers[id]:close()
            self.timers[id] = nil
          end
          cb("sshinator process exited with code " .. code, nil)
        end
        self.callbacks = {}
      end)
    end,
    stdout_buffered = false,
    stderr_buffered = true,
  })
  if self.job_id <= 0 then
    error("failed to start sshinator process")
  end
end

function Client:handle_stdout(data)
  local chunks = {}
  if self.buffer ~= "" then
    table.insert(chunks, self.buffer)
    self.buffer = ""
  end
  for _, chunk in ipairs(data) do
    table.insert(chunks, chunk)
  end

  local combined = table.concat(chunks)
  local start = 1
  while true do
    local newline_pos = combined:find("\n", start, true)
    if not newline_pos then
      self.buffer = combined:sub(start)
      break
    end

    local json_line = combined:sub(start, newline_pos - 1)
    start = newline_pos + 1

    if json_line ~= "" then
      local ok, decoded = pcall(vim.fn.json_decode, json_line)
      if ok then
        local id = decoded.id
        local cb = self.callbacks[id]
        if cb then
          self.callbacks[id] = nil
          if self.timers[id] then
            self.timers[id]:stop()
            self.timers[id]:close()
            self.timers[id] = nil
          end
          vim.schedule(function()
            if decoded.error and decoded.error ~= vim.NIL then
              cb(decoded.error, nil)
            else
              cb(nil, decoded.result)
            end
          end)
        end
      end
    end
  end
end

function Client:call(method, params, callback)
  if not self.job_id then
    self:start()
  end
  self.request_id = self.request_id + 1
  local id = self.request_id
  self.callbacks[id] = callback

  if self.request_timeout > 0 then
    local timer = vim.uv.new_timer()
    self.timers[id] = timer
    timer:start(self.request_timeout, 0, function()
      timer:close()
      self.timers[id] = nil
      local cb = self.callbacks[id]
      if cb then
        self.callbacks[id] = nil
        vim.schedule(function()
          cb("request timed out after " .. self.request_timeout .. "ms", nil)
        end)
      end
    end)
  end

  local ok, encoded = pcall(vim.fn.json_encode, {
    id = id,
    method = method,
    params = params,
  })
  if not ok then
    self.callbacks[id] = nil
    if self.timers[id] then
      self.timers[id]:stop()
      self.timers[id]:close()
      self.timers[id] = nil
    end
    vim.schedule(function()
      callback("failed to encode request", nil)
    end)
    return
  end

  local send_ok = pcall(vim.fn.chansend, self.job_id, encoded .. "\n")
  if not send_ok then
    self.callbacks[id] = nil
    if self.timers[id] then
      self.timers[id]:stop()
      self.timers[id]:close()
      self.timers[id] = nil
    end
    vim.schedule(function()
      callback("failed to send request", nil)
    end)
  end
end

function Client:is_running()
  return self.job_id ~= nil
end

function Client:stop()
  if self.job_id then
    for _, timer in pairs(self.timers) do
      timer:stop()
      timer:close()
    end
    self.timers = {}
    vim.fn.jobstop(self.job_id)
    self.job_id = nil
  end
end

return M
