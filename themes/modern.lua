-- QtUiPlus :: themes/modern.lua
--
-- The current QtUiPlus visual system, made an explicit theme. Its tokens keep
-- living in core/media.lua and its shared components in core/style.lua and
-- core/widgets.lua; this registration only names that established
-- implementation so a second one can exist beside it.
--
-- The apply callback writes the tokens back to their Modern values rather than
-- being empty. That is not a no-op with extra steps: a theme change is
-- reload-bound and only one apply runs per session, but stating the values
-- here is the contract a future Classic theme flips, and it keeps the two
-- files readable as a pair. Tokens are mutated in place, never replaced --
-- modules capture a reference to an individual token table at file-load time.

local U = QtUiPlus

U.RegisterThemeStyle("modern", {
  label = "Modern",
  available = true,
  apply = function(M)
    -- Near-black panels with a single thin dark outline.
    M.color.background[1], M.color.background[2] = 0.06, 0.06
    M.color.background[3], M.color.background[4] = 0.06, 0.85

    M.color.border[1], M.color.border[2] = 0.16, 0.16
    M.color.border[3], M.color.border[4] = 0.16, 1.00

    -- What a full health bar fades to under the QtUI gradient; see the note on
    -- healthFull in core/media.lua.
    M.color.healthFull[1], M.color.healthFull[2] = 0.10, 0.10
    M.color.healthFull[3], M.color.healthFull[4] = 0.10, 1.00

    M.color.healthBg[1], M.color.healthBg[2] = 0.10, 0.10
    M.color.healthBg[3], M.color.healthBg[4] = 0.10, 0.90
  end,
})
