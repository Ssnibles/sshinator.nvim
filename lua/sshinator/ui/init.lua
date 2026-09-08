local M = {}

function M.configure(opts)
  -- Kept for backwards compatibility
end

function M.notify(msg, level)
  level = level or vim.log.levels.INFO
  vim.notify("[sshinator] " .. msg, level)
end

function M.select(items, opts, callback)
  require("sshinator.ui.select").open(items, opts, callback)
end

function M.input(opts, callback)
  require("sshinator.ui.input").open(opts, callback)
end

function M.confirm(opts, callback)
  require("sshinator.ui.confirm").open(opts, callback)
end

function M.status_window(connections, mounted)
  require("sshinator.ui.status").open(connections, mounted)
end

function M.input_chain(fields, callback)
  local results = {}
  local idx = 1

  local function process_field()
    if idx > #fields then
      callback(results)
      return
    end

    local field = fields[idx]
    local default_val = field.default

    local function on_value(val)
      if val == nil then
        if field.required then
          callback(nil)
          return
        end
        results[field.key] = nil
      else
        results[field.key] = val
      end
      idx = idx + 1
      vim.schedule(process_field)
    end

    local function prompt_field(def)
      M.input({
        title = field.prompt,
        default = def or "",
        mask = field.mask,
      }, on_value)
    end

    if type(default_val) == "function" then
      if field.async_default then
        default_val(results, function(computed)
          prompt_field(computed)
        end)
      else
        prompt_field(default_val(results))
      end
    else
      prompt_field(default_val)
    end
  end

  vim.schedule(process_field)
end

return M
