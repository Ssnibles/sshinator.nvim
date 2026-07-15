local M = {}

local Client = {}
Client.__index = Client

function M.new_client(binary)
  local self = setmetatable({}, Client)
  self.binary = binary
  self.job_id = nil
  self.request_id = 0
  self.callbacks = {}
  self.buffer = ""
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
      self.job_id = nil
      for id, cb in pairs(self.callbacks) do
        cb("process exited with code " .. code, nil)
      end
      self.callbacks = {}
    end,
    stdout_buffered = false,
    stderr_buffered = true,
  })
  if self.job_id <= 0 then
    error("failed to start sshinator process")
  end
end

function Client:handle_stdout(data)
  for _, chunk in ipairs(data) do
    self.buffer = self.buffer .. chunk
  end

  while true do
    local newline_pos = self.buffer:find("\n")
    if not newline_pos then
      break
    end

    local json_line = self.buffer:sub(1, newline_pos - 1)
    self.buffer = self.buffer:sub(newline_pos + 1)

    if json_line ~= "" then
      local ok, decoded = pcall(vim.fn.json_decode, json_line)
      if ok then
        local id = decoded.id
        local cb = self.callbacks[id]
        if cb then
          self.callbacks[id] = nil
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
  local request = vim.fn.json_encode({
    id = id,
    method = method,
    params = params,
  })
  vim.fn.chansend(self.job_id, request .. "\n")
end

function Client:is_running()
  return self.job_id ~= nil
end

function Client:stop()
  if self.job_id then
    vim.fn.jobstop(self.job_id)
    self.job_id = nil
  end
end

return M
