local M = {}
local ui = require("sshinator.ui")

function M.select(items, opts, callback)
  ui.select(items, opts, callback)
end

return M
