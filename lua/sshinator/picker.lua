local M = {}

function M.select(items, opts, callback)
  opts = opts or {}
  local prompt = opts.prompt or "Select:"

  vim.ui.select(items, {
    prompt = prompt,
    format_item = function(item)
      return item
    end,
  }, function(choice)
    callback(choice)
  end)
end

return M
