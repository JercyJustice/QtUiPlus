-- QtUiPlus :: themes/classic-wow.lua
--
-- Registration only. Classic WoW keeps the client's own chrome on stock
-- windows while every QtUiPlus module stays fully enabled -- it is a visual
-- style, never an addon-off switch.
--
-- `available = false` because none of that exists here yet. The entry is
-- registered rather than omitted so the settings list shows what is coming and
-- the id is reserved; U.GetThemeStyle refuses to resolve to an unavailable
-- style, so selecting it is impossible until the implementation lands.
--
-- What "available" will require, roughly in the order the surfaces matter:
--
--   * unit frames keeping the QtUiPlus frames as invisible layout anchors with
--     the client's own frames shown on top, so saved mover positions, aura
--     attachment points and the refresh contract all survive
--   * action and stance buttons drawing the live client's own button faces,
--     read before core/compat.lua suppresses the stock bars
--   * the merged bag window painted from the live ContainerFrame textures
--   * every module that skins a native window bailing out of its build step
--     when U.ThemeStyleUsesNativeChrome() is true
--
-- The palette below is the Classic side of the token contract themes/modern.lua
-- states, and is applied only once this style becomes selectable.

local U = QtUiPlus

U.RegisterThemeStyle("classic-wow", {
  label = "Classic WoW",
  available = false,
  wip = true,
  nativeChrome = true,
  apply = function(M)
    M.color.background[1], M.color.background[2] = 0.12, 0.075
    M.color.background[3], M.color.background[4] = 0.035, 0.95

    M.color.border[1], M.color.border[2] = 0.56, 0.43
    M.color.border[3], M.color.border[4] = 0.20, 1.00

    M.color.healthFull[1], M.color.healthFull[2] = 0.00, 0.75
    M.color.healthFull[3], M.color.healthFull[4] = 0.00, 1.00

    M.color.healthBg[1], M.color.healthBg[2] = 0.10, 0.06
    M.color.healthBg[3], M.color.healthBg[4] = 0.03, 0.90
  end,
})
