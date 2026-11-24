-- Live Omarchy theme switching for a running Neovim (managed by omarchy-mac).
--
-- `omarchy-theme set <name>` rewrites lua/plugins/omarchy-theme.lua and then
-- sends SIGUSR1 to every nvim. On that signal this module re-reads the spec,
-- loads the colorscheme plugin (all are pre-declared lazily in
-- plugins/omarchy-themes.lua), applies its opts/config and switches the
-- colorscheme. `:OmarchyThemeReload` does the same by hand.
local M = {}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Omarchy theme" })
end

local function theme_spec_path()
  return vim.fn.stdpath("config") .. "/lua/plugins/omarchy-theme.lua"
end

local function theme_mode()
  local path = vim.fn.expand("~/.config/omarchy-mac/current/colors.json")
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or not lines then
    return nil
  end
  local ok2, data = pcall(vim.json.decode, table.concat(lines, "\n"))
  if ok2 and type(data) == "table" and (data.mode == "light" or data.mode == "dark") then
    return data.mode
  end
end

local function plugin_name(spec)
  if spec.name then
    return spec.name
  end
  if type(spec[1]) == "string" then
    return spec[1]:match("[^/]+$")
  end
end

local function setup_plugin(spec, missing)
  local name = plugin_name(spec)
  if not name then
    return
  end
  local okc, Config = pcall(require, "lazy.core.config")
  local plugin = okc and Config.plugins[name] or nil
  if not plugin or not (plugin._ and plugin._.installed) then
    missing[#missing + 1] = name
    return
  end
  local Loader = require("lazy.core.loader")
  -- Loads dependencies too; a plugin that is already loaded is left alone.
  pcall(Loader.load, name, { cmd = "OmarchyThemeReload" })
  if type(spec.config) == "function" then
    local ok, err = pcall(spec.config, plugin, spec.opts or {})
    if not ok then
      notify("config for " .. name .. " failed: " .. tostring(err), vim.log.levels.WARN)
    end
  elseif type(spec.opts) == "table" then
    local main = Loader.get_main(plugin)
    local okm, mod = pcall(require, main or name)
    if okm and type(mod) == "table" and type(mod.setup) == "function" then
      local ok, err = pcall(mod.setup, spec.opts)
      if not ok then
        notify("setup for " .. name .. " failed: " .. tostring(err), vim.log.levels.WARN)
      end
    end
  end
end

function M.apply()
  local ok, specs = pcall(dofile, theme_spec_path())
  if not ok or type(specs) ~= "table" then
    notify("cannot read " .. theme_spec_path() .. ": " .. tostring(specs), vim.log.levels.ERROR)
    return
  end
  local colorscheme
  local missing = {}
  for _, spec in ipairs(specs) do
    if type(spec) == "table" then
      if spec[1] == "LazyVim/LazyVim" then
        colorscheme = spec.opts and spec.opts.colorscheme
      else
        setup_plugin(spec, missing)
      end
    end
  end
  if #missing > 0 then
    notify("not installed: " .. table.concat(missing, ", ") .. " (run :Lazy install)", vim.log.levels.WARN)
  end
  local mode = theme_mode()
  if mode then
    vim.o.background = mode
  end
  if type(colorscheme) == "function" then
    pcall(colorscheme)
  elseif type(colorscheme) == "string" then
    local okc, err = pcall(vim.cmd.colorscheme, colorscheme)
    if not okc then
      notify("colorscheme " .. colorscheme .. " failed: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
  end
  -- Keep LazyVim's idea of the colorscheme in step for anything that asks later.
  local okl, lv = pcall(require, "lazyvim.config")
  if okl and type(lv) == "table" and colorscheme then
    lv.colorscheme = colorscheme
  end
end

function M.setup()
  local group = vim.api.nvim_create_augroup("omarchy_theme_reload", { clear = true })
  vim.api.nvim_create_autocmd("Signal", {
    group = group,
    pattern = "SIGUSR1",
    desc = "Apply the Omarchy theme written by omarchy-theme",
    callback = function()
      -- The spec file is written before the signal is sent; schedule to run
      -- outside the signal callback.
      vim.schedule(M.apply)
    end,
  })
  pcall(vim.api.nvim_create_user_command, "OmarchyThemeReload", M.apply, { force = true })
end

return M
