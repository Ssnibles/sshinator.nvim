local M = {}
local float = require("sshinator.ui.float")

function M.open(opts, callback)
  opts = opts or {}
  local title = opts.title or opts.prompt or "Confirm"
  local width = math.max(50, vim.fn.strdisplaywidth(title) + 20)

  local buf, win = float.create_float({
    title = title,
    width = width,
    height = 3,
  })
  if not buf or not win then
    callback(nil)
    return
  end

  local selected_idx = 1
  local submitted = false

  local function render()
    local options = { "Yes", "No" }
    local lines = {}
    for i, opt in ipairs(options) do
      local prefix = i == selected_idx and " > " or "   "
      local line = prefix .. opt
      local padding = width - vim.fn.strdisplaywidth(line)
      if padding > 0 then
        line = line .. string.rep(" ", padding)
      end
      table.insert(lines, line)
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    local ns = float.get_ns_id()
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for i = 1, #lines do
      if i == selected_idx then
        vim.api.nvim_buf_add_highlight(buf, ns, float.hl_groups.selected, i - 1, 0, -1)
      end
    end
  end

  render()

  local function submit()
    if submitted then return end
    submitted = true
    local result = selected_idx == 1
    float.close_float(win)
    callback(result)
  end

  local function cancel()
    if submitted then return end
    submitted = true
    float.close_float(win)
    callback(nil)
  end

  local function toggle()
    selected_idx = selected_idx == 1 and 2 or 1
    render()
  end

  vim.keymap.set("n", "<CR>", submit, { buffer = buf, noremap = true })
  vim.keymap.set("n", "<Esc>", cancel, { buffer = buf, noremap = true })
  vim.keymap.set("n", "q", cancel, { buffer = buf, noremap = true })
  vim.keymap.set("n", "j", toggle, { buffer = buf, noremap = true })
  vim.keymap.set("n", "k", toggle, { buffer = buf, noremap = true })
  vim.keymap.set("n", "<Down>", toggle, { buffer = buf, noremap = true })
  vim.keymap.set("n", "<Up>", toggle, { buffer = buf, noremap = true })
  vim.keymap.set("n", "y", function()
    selected_idx = 1
    submit()
  end, { buffer = buf, noremap = true })
  vim.keymap.set("n", "n", function()
    selected_idx = 2
    submit()
  end, { buffer = buf, noremap = true })

  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    nested = true,
    once = true,
    callback = cancel,
  })
end

return M
