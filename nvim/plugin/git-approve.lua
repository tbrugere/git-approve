-- git-approve.nvim command + autocmd registration. The logic lives in
-- lua/git-approve/init.lua.

if vim.g.loaded_git_approve then
  return
end
vim.g.loaded_git_approve = 1

local ga = require('git-approve')

vim.api.nvim_create_user_command('GApproveReview', ga.review, {})
vim.api.nvim_create_user_command('GApprove', function(o)
  ga.run('approve', o.args)
end, { nargs = '*', complete = 'file' })
vim.api.nvim_create_user_command('GUnapprove', function(o)
  ga.run('revoke', o.args)
end, { nargs = '*', complete = 'file' })
vim.api.nvim_create_user_command('GApproveStage', ga.stage_approve, {})

-- Auto-refresh the staged side of an open review diff when the index changes.
-- The handler is a near-no-op unless the current tab holds a review diff.
local grp = vim.api.nvim_create_augroup('git_approve_review', {})
vim.api.nvim_create_autocmd({ 'FocusGained', 'BufEnter', 'CursorHold' }, {
  group = grp,
  callback = ga.maybe_refresh,
})
