local M = {}

---Autoformat a buffer when saving
---The formatter(s) used is determined by `vim.b.conform.format_opts.formatters`
function M.format_on_save()
  local aug = vim.api.nvim_create_augroup("Conform", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePre", {
    desc = "Format with conform",
    group = aug,
    callback = function(args)
      if
        not vim.api.nvim_buf_is_valid(args.buf)
        or vim.bo[args.buf].buftype ~= ""
        or not vim.opt_local.modifiable:get()
      then
        return
      end
      M.format({
        buf = args.buf,
        async = false,
      })
    end,
  })
end

---@param bufnr? integer
---@param format_opts? conform.FormatOpts
---@return conform.ResolvedConfig
function M.build_config(bufnr, format_opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  ---@type conform.ResolvedConfig
  local defaults = {
    overrides = {},
    notify_on_error = true,
    notify_no_formatters = true,
    format_opts = {
      formatters = {},
      timeout_ms = 1000,
      bufnr = bufnr,
      async = false,
      dry_run = false,
      lsp_format = "never",
      quiet = false,
      undojoin = false,
      stop_after_first = false,
    },
  }

  vim.validate("vim.g.conform", vim.g.conform, { "table", "nil" }, false, "conform.Config")
  vim.validate(
    "vim.b[bufnr].conform",
    vim.b[bufnr].conform,
    { "table", "nil" },
    false,
    "conform.Config"
  )

  local config = vim.tbl_deep_extend(
    "keep",
    { format_opts = format_opts or {} },
    vim.b[bufnr].conform or {} --[[@as conform.Config]],
    vim.g.conform or {} --[[@as conform.Config]],
    defaults
  )

  config.overrides = vim.tbl_map(
    ---@param override nil|conform.FormatterConfigOverride|fun(bufnr: integer): nil|conform.FormatterConfigOverride
    function(override)
      if type(override) == "function" then
        return override(bufnr)
      else
        return override
      end
    end,
    config.overrides
  )
  return config --[[@as conform.ResolvedConfig]]
end

---@private
---@param names string[]
---@param bufnr integer
---@param warn_on_missing boolean
---@param stop_after_first boolean
---@return conform.FormatterInfo[]
function M.resolve_formatters(names, bufnr, warn_on_missing, stop_after_first)
  local all_info = {}
  local function add_info(info, warn)
    if info.available then
      table.insert(all_info, info)
    elseif warn then
      vim.notify(
        string.format("Formatter '%s' unavailable: %s", info.name, info.available_msg),
        vim.log.levels.WARN
      )
    end
    return info.available
  end

  for _, name in ipairs(names) do
    local info = M.get_formatter_info(name, bufnr)
    add_info(info, warn_on_missing)

    if stop_after_first and #all_info > 0 then
      break
    end
  end
  return all_info
end

---@param opts table
---@return boolean
local function has_lsp_formatter(opts)
  return not vim.tbl_isempty(require("conform.lsp_format").get_format_clients(opts))
end

---@param bufnr integer
---@param mode "v"|"V"
---@return conform.Range {start={row,col}, end={row,col}} using (1, 0) indexing
local function range_from_selection(bufnr, mode)
  -- [bufnum, lnum, col, off]; both row and column 1-indexed
  local start = vim.fn.getpos("v")
  local end_ = vim.fn.getpos(".")
  local start_row = start[2]
  local start_col = start[3]
  local end_row = end_[2]
  local end_col = end_[3]

  -- A user can start visual selection at the end and move backwards
  -- Normalize the range to start < end
  if start_row == end_row and end_col < start_col then
    end_col, start_col = start_col, end_col
  elseif end_row < start_row then
    start_row, end_row = end_row, start_row
    start_col, end_col = end_col, start_col
  end
  if mode == "V" then
    start_col = 1
    local lines = vim.api.nvim_buf_get_lines(bufnr, end_row - 1, end_row, true)
    end_col = #lines[1]
  end
  return {
    ["start"] = { start_row, start_col - 1 },
    ["end"] = { end_row, end_col - 1 },
  }
end

---Handle errors and maybe run LSP formatting after cli formatters complete
---@param err? conform.Error
---@param did_edit? boolean
local function handle_formatter_result(err, did_edit)
  if err then
    local level = require("conform.errors").level_for_code(err.code)
    require("conform.log").log(level, err.message)
    ---@type boolean?
    local should_notify = not opts.quiet and level >= vim.log.levels.WARN
    -- Execution errors have special handling. Maybe should reconsider this.
    local notify_msg = err.message
    if require("conform.errors").is_execution_error(err.code) then
      should_notify = should_notify and config.notify_on_error and not err.debounce_message
      notify_msg = "Formatter failed. See :ConformInfo for details"
    end
    if should_notify then
      vim.notify(notify_msg, level)
    end
  end
  local err_message = err and err.message
  if not err_message and not vim.api.nvim_buf_is_valid(opts.bufnr) then
    err_message = "buffer was deleted"
  end
  if err_message then
    return callback(err_message)
  end

  if opts.dry_run and did_edit then
    callback(nil, true)
  elseif opts.lsp_format == "last" and has_lsp then
    require("conform.log").debug(
      "Running LSP formatter on %s",
      vim.api.nvim_buf_get_name(opts.bufnr)
    )
    require("conform.lsp_format").format(opts, callback)
  else
    callback(nil, did_edit)
  end
end

---Run the resolved formatters on the buffer
local function run_cli_formatters(cb)
  local resolved_names = vim.tbl_map(function(f)
    return f.name
  end, formatters)
  require("conform.log").debug(
    "Running formatters on %s: %s",
    vim.api.nvim_buf_get_name(opts.bufnr),
    resolved_names
  )
  ---@type conform.RunOpts
  local run_opts = { exclusive = true, dry_run = opts.dry_run, undojoin = opts.undojoin }
  if opts.async then
    require("conform.runner").format_async(opts.bufnr, formatters, opts.range, run_opts, cb)
  else
    local err, did_edit = require("conform.runner").format_sync(
      opts.bufnr,
      formatters,
      opts.timeout_ms,
      opts.range,
      run_opts
    )
    cb(err, did_edit)
  end
end

---Format a buffer
---@param opts? conform.FormatOpts
---@param callback? fun(err: nil|string, did_edit: nil|boolean) Called once formatting has completed
---@return boolean True if any formatters were attempted
function M.format(opts, callback)
  local config = M.build_config(opts and opts.bufnr, opts)
  opts = config.format_opts

  if opts.bufnr == 0 then
    opts.bufnr = vim.api.nvim_get_current_buf()
  end

  local mode = vim.api.nvim_get_mode().mode
  if not opts.range and mode == "v" or mode == "V" then
    opts.range = range_from_selection(opts.bufnr, mode)
  end

  local formatters =
    M.resolve_formatters(opts.formatters, opts.bufnr, not opts.quiet, opts.stop_after_first)
  local has_lsp = has_lsp_formatter(opts)

  if vim.tbl_isempty(formatters) and (not has_lsp or opts.lsp_format == "never") then
    -- HINT: Exit early if no formatters are configured
    return false
  end

  ---@diagnostic disable-next-line: unused-local
  callback = callback or function(err, did_edit) end

  if vim.tbl_isempty(formatters) or opts.lsp_format == "prefer" then
    if has_lsp and opts.lsp_format ~= "never" then
      -- LSP formatting only
      require("conform.log").debug(
        "Running LSP formatter on %s",
        vim.api.nvim_buf_get_name(opts.bufnr)
      )
      require("conform.lsp_format").format(opts, callback)
      return true
    else
      -- No formatting
      assert(false, "Case was handled above", formatters, opts.lsp_format, has_lsp)
      return false
    end
  else
    if
      opts.lsp_format == "never"
      or opts.lsp_format == "fallback"
      or opts.lsp_format == "last"
      or not has_lsp
    then
      -- HINT: `opts.lsp_format == "last"` is taken care of in `handle_result`
      run_cli_formatters(handle_formatter_result)
      return true
    elseif opts.lsp_format == "first" then
      -- LSP formatting, then other formatters
      require("conform.log").debug(
        "Running LSP formatter on %s",
        vim.api.nvim_buf_get_name(opts.bufnr)
      )
      require("conform.lsp_format").format(opts, function(err, did_edit)
        if err or (did_edit and opts.dry_run) then
          return callback(err, did_edit)
        end
        run_cli_formatters(function(err2, did_edit2)
          handle_formatter_result(err2, did_edit or did_edit2)
        end)
      end)
      return true
    else
      assert(false, "All cases were have been handled", formatters, opts.lsp_format, has_lsp)
      return false
    end
  end
end

---Retrieve the available formatters for a buffer
---@param bufnr? integer
---@return conform.FormatterInfo[]
function M.list_formatters(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local formatters = M.build_config(bufnr).format_opts.formatters
  return M.resolve_formatters(formatters, bufnr, false, false)
end

---Get the exact formatters that will be run for a buffer.
---@param bufnr? integer
---@return conform.FormatterInfo[]
---@return boolean lsp Will use LSP formatter
---@note
--- This accounts for stop_after_first, lsp fallback logic, etc.
function M.list_formatters_to_run(bufnr)
  local config = M.build_config(bufnr)
  local opts = config.format_opts

  local formatter_names = opts.formatters
  local formatters = M.resolve_formatters(formatter_names, opts.bufnr, false, opts.stop_after_first)

  local has_lsp = has_lsp_formatter(opts)

  local lsp = { name = "vim.lsp.buf.format()" }

  if vim.tbl_isempty(formatters) or opts.lsp_format == "prefer" then
    if opts.lsp_format ~= "never" then
      return has_lsp and { lsp } or {}, has_lsp
    else
      return {}, false
    end
  else
    if opts.lsp_format == "never" or opts.lsp_format == "fallback" or not has_lsp then
      return formatters, false
    elseif opts.lsp_format == "last" then
      table.insert(formatters, lsp)
      return formatters, true
    elseif opts.lsp_format == "first" then
      table.insert(formatters, 1, lsp)
      return formatters, true
    else
      assert(false, "All cases were have been handled", formatters, opts.lsp_format, has_lsp)
      return {}, true
    end
  end
end

---@private
---@param formatter string
---@param bufnr? integer
---@return nil|conform.FormatterConfig
function M.get_formatter_config(formatter, bufnr)
  local override = M.build_config(bufnr).overrides[formatter]
  if override and override.command and override.format then
    local msg =
      string.format("Formatter '%s' cannot define both 'command' and 'format' function", formatter)
    vim.notify_once(msg, vim.log.levels.ERROR)
    return nil
  end

  ---@type nil|conform.FormatterConfig
  local config = override
  if not override or override.inherit ~= false then
    local ok, mod_config = pcall(require, "conform.formatters." .. formatter)
    if ok then
      if override then
        config = require("conform.util").merge_formatter_configs(mod_config, override)
      else
        config = mod_config
      end
    elseif override then
      if override.command or override.format then
        config = override
      else
        local msg = string.format(
          "Formatter '%s' missing built-in definition\nSet `command` to get rid of this error.",
          formatter
        )
        vim.notify_once(msg, vim.log.levels.ERROR)
        return nil
      end
    else
      return nil
    end
  end

  if config and config.stdin == nil then
    config.stdin = true
  end
  return config
end

---Get information about a formatter (including availability)
---@param formatter string The name of the formatter
---@param bufnr? integer
---@return conform.FormatterInfo
function M.get_formatter_info(formatter, bufnr)
  local config = M.get_formatter_config(formatter, bufnr)
  if not config then
    return {
      name = formatter,
      command = formatter,
      available = false,
      available_msg = "Unknown formatter. Formatter config missing or incomplete",
      error = true,
    }
  end

  local ctx =
    require("conform.runner").build_context(bufnr or vim.api.nvim_get_current_buf(), config)

  local available = true
  local available_msg = nil
  if config.format then
    ---@cast config conform.LuaFormatterConfig
    if config.condition and not config:condition(ctx) then
      available = false
      available_msg = "Condition failed"
    end
    return {
      name = formatter,
      command = formatter,
      available = available,
      available_msg = available_msg,
    }
  end

  local command = config.command
  if type(command) == "function" then
    ---@cast config conform.JobFormatterConfig
    command = command(config, ctx)
  end

  if vim.fn.executable(command) == 0 then
    available = false
    available_msg = "Command not found"
  elseif config.condition and not config.condition(config, ctx) then
    available = false
    available_msg = "Condition failed"
  end
  local cwd = nil
  if config.cwd then
    ---@cast config conform.JobFormatterConfig
    cwd = config.cwd(config, ctx)
    if available and not cwd and config.require_cwd then
      available = false
      available_msg = "Root directory not found"
    end
  end

  ---@type conform.FormatterInfo
  return {
    name = formatter,
    command = command,
    cwd = cwd,
    available = available,
    available_msg = available_msg,
  }
end

return M
