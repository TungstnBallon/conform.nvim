local M = {}

function M.check()
  local conform = require("conform")
  -- HACK: :checkhealth switches to its buffer before invoking the healthcheck(s).
  local orig_bufnr = vim.fn.bufnr("#")

  vim.health.start("conform.nvim report")

  local log = require("conform.log")
  if vim.fn.has("nvim-0.10") == 0 then
    vim.health.error("Neovim 0.10 or later is required")
  end
  vim.health.info(string.format("Log file: %s", log.get_logfile()))
  vim.health.info(
    string.format(
      "Configuration for this buffer: %s",
      vim.inspect(conform.build_config(orig_bufnr))
    )
  )

  local all_formatters = conform.list_formatters(orig_bufnr)
  for _, formatter in ipairs(all_formatters) do
    if not formatter.available then
      vim.health.warn(string.format("%s unavailable: %s", formatter.name, formatter.available_msg))
    else
      vim.health.ok(string.format("%s ready", formatter.name))
    end
  end

  local formatters_to_run, _ = conform.list_formatters_to_run(orig_bufnr)
  vim.health.info(
    string.format(
      "Will run these formatter(s): %s",
      table.concat(
        vim.tbl_map(function(fmt)
          return fmt.name
        end, formatters_to_run),
        ", "
      )
    )
  )
end

return M
