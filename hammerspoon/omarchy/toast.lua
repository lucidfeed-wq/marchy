-- Omarchy-style OSD toasts: themed hs.alert, square corners, accent border,
-- near the bottom centre of the focused screen, 1.2 s.
local M = {}

local last = nil

function M.style()
  local theme = require("omarchy.theme")
  return {
    fillColor = theme.color("background", 0.97),
    strokeColor = theme.color("accent"),
    strokeWidth = 2,
    radius = 0,
    textColor = theme.color("foreground"),
    textFont = theme.font,
    textSize = 15,
    padding = 14,
    atScreenEdge = 2,
    fadeInDuration = 0.05,
    fadeOutDuration = 0.15,
  }
end

-- Replaces the previous toast instead of stacking.
function M.show(text, seconds)
  pcall(function()
    if last then hs.alert.closeSpecific(last, 0) end
    last = hs.alert.show(tostring(text), M.style(), hs.screen.mainScreen(), seconds or 1.2)
  end)
end

-- Longer-lived toast for warnings.
function M.warn(text)
  M.show(text, 3)
end

-- Apply the theme to hs.alert's defaults too, so stray alerts match.
function M.retint()
  local style = M.style()
  for k, v in pairs(style) do
    if k ~= "atScreenEdge" then hs.alert.defaultStyle[k] = v end
  end
end

return M
