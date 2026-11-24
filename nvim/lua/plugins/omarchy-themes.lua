-- Omarchy themes for Neovim (managed by omarchy-mac; safe to keep in git).
--
-- Declares every colorscheme plugin any Omarchy theme can ask for, lazy-loaded,
-- so lazy.nvim installs them all once and a theme switch never needs a
-- download. Which one is active is decided by plugins/omarchy-theme.lua, which
-- `omarchy-theme set <name>` rewrites (from the theme's neovim.lua, or from
-- templates/neovim.lua.tpl for themes without one), and running Neovims are
-- retinted on SIGUSR1 by config/omarchy-reload.lua.

-- Register the SIGUSR1 handler. Doing it here means no edit to the user's
-- init.lua / config files is needed; it is idempotent (cleared augroup).
pcall(function()
  require("config.omarchy-reload").setup()
end)

return {
  -- LazyVim already declares these two; repeating them only merges.
  { "folke/tokyonight.nvim", lazy = true },
  { "catppuccin/nvim", name = "catppuccin", lazy = true },

  { "neanias/everforest-nvim", lazy = true }, -- everforest
  { "kepano/flexoki-neovim", lazy = true }, -- flexoki-light
  { "ellisonleao/gruvbox.nvim", lazy = true }, -- gruvbox
  -- hackerman's own neovim.lua depends on bjarneo/aether.nvim, which installs the
  -- same `aether` Lua module and colors/aether.vim as omacom/aether.nvim (its
  -- newer fork, same API). With both present lazy.nvim's colorscheme autoloader
  -- picks either at startup, and bjarneo's never gets the theme's opts, so it is
  -- disabled here (lazy skips disabled dependencies silently) and hackerman
  -- runs on omacom's copy.
  { "bjarneo/hackerman.nvim", lazy = true, dependencies = { "aether" } }, -- hackerman
  { "bjarneo/aether.nvim", enabled = false },
  { "omacom/aether.nvim", name = "aether", branch = "v3", lazy = true }, -- templated themes + hackerman's base
  { "rebelot/kanagawa.nvim", lazy = true }, -- kanagawa
  { "omacom-io/lumon.nvim", lazy = true }, -- lumon
  { "tahayvr/matteblack.nvim", lazy = true }, -- matte-black
  { "EdenEast/nightfox.nvim", lazy = true }, -- nord (nordfox)
  { "OldJobobo/retro-82.nvim", lazy = true }, -- retro-82
  { "rose-pine/neovim", name = "rose-pine", lazy = true }, -- rose-pine
  { "ficcdaf/ashen.nvim", lazy = true }, -- solitude
}
