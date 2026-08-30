-- QtUiPlus :: core/qtcompat.lua
--
-- Bridge for the feature modules ported from QtUI.
--
-- QtUI is a single flat addon: every module reaches for a handful of helpers on
-- one global table. Rewriting those modules into the QtUiPlus registry idiom
-- would mean re-deriving thousands of lines of behaviour that already work on
-- this client. Instead the ported files keep their original shape and call a
-- `QtP` table that this file backs with QtUiPlus internals. The surface is
-- deliberately small, and it is the complete set the ported modules actually use:
--
--   QtP:Print / QtP.media / QtP:ApplyFont / QtP:PlaceAlignedText
--   QtP:CreatePanel / QtP:GetLayout / QtP:EnsureLayoutDefaults
--   QtP:IsFeatureEnabled
--
-- The `QtP` name (not `QtUI`) matters: QtUI itself may be installed in the same
-- AddOns folder. Sharing a global, or stamping the same `qt*` fields onto the
-- same native frames, would have the two addons silently overwrite each other.

local U = QtUiPlus
local M = U.media

QtP = {}
QtPDB = nil   -- resolved against QtUiPlusDB.qt once SavedVariables have loaded

-- ---------------------------------------------------------------------------
-- Storage
--
-- The ported settings live under QtUiPlusDB.qt rather than in the module store.
-- core/config.lua's SanitizeModules caps a module table at one level of nesting
-- and 200 entries; the QtUI layout nests deeper than that, so it would be
-- silently truncated on every load. A top-level key is left alone by
-- ApplyDefaults, which only walks keys present in its template.
--
-- That same file's warning about SavedVariables backslash corruption still
-- applies here: nothing below persists a media path. Paths are rebuilt at
-- runtime from QtP.media and core/media.lua.
-- ---------------------------------------------------------------------------
local function EnsureDB()
  if type(QtUiPlusDB) ~= "table" then QtUiPlusDB = {} end
  if type(QtUiPlusDB.qt) ~= "table" then QtUiPlusDB.qt = {} end
  QtPDB = QtUiPlusDB.qt
  return QtPDB
end

QtP.EnsureDB = EnsureDB

function QtP:Print(message)
  U.Print(message)
end

-- Adapted to the QtUiPlus look: every bar this addon draws uses the flat
-- plain texture, so a ported window reads as part of the same UI rather than
-- as a transplant from another one.
QtP.media = {
  statusbar = M.texture.plain,
}

-- ---------------------------------------------------------------------------
-- Fonts
--
-- Carried over from QtUI Core.lua unchanged in behaviour, because the
-- workaround it encodes is specific to this client: FontString:SetFont is a
-- no-op while a Font object is assigned, and CreateFontString always assigns
-- GameFontNormal. Owning a Font object via CreateFont + SetFontObject is the
-- only way through. SetTextColor writes through the Font object, so the pool is
-- keyed by size AND colour -- one Font per widget measurably halved idle FPS
-- when QtUI tried it.
-- ---------------------------------------------------------------------------
local FONT_PATH = "Fonts\\FRIZQT__.TTF"
local fontSeq = 0
local fontPool = {}

function QtP:ApplyFont(widget, size, r, g, b)
  if not widget then return end
  size = math.floor(tonumber(size) or 12)
  if size < 6 then size = 6 end
  if size > 32 then size = 32 end
  r = tonumber(r); g = tonumber(g); b = tonumber(b)
  if not r then r = 1 end
  if not g then g = 1 end
  if not b then b = 1 end
  local path = STANDARD_TEXT_FONT or FONT_PATH
  local key = size .. ":" .. string.format("%.2f:%.2f:%.2f", r, g, b)
  local font = fontPool[key]
  if not font and type(CreateFont) == "function" then
    fontSeq = fontSeq + 1
    local ok, created = pcall(CreateFont, "QtUiPlusFont" .. fontSeq)
    if ok and created then
      font = created
      fontPool[key] = font
      if font.SetFont then pcall(font.SetFont, font, path, size) end
      if font.SetTextColor then pcall(font.SetTextColor, font, r, g, b) end
    end
  end
  if font and widget.SetFontObject then
    pcall(widget.SetFontObject, widget, font)
    widget.qtpFontObject = font
    widget.qtpFontSize = size
    widget.qtpFontKey = key
    return
  end
  if widget.SetFont then
    pcall(widget.SetFont, widget, path, size)
    widget.qtpFontSize = size
  end
  if widget.SetTextColor then pcall(widget.SetTextColor, widget, r, g, b) end
end

-- Single-point TOPLEFT/TOPRIGHT on a FontString is unreliable on this client:
-- SetWidth is ignored, so a label keeps its template width and LEFT/RIGHT read
-- swapped. Pin an explicit pixel box from the parent instead.
function QtP:PlaceAlignedText(fontString, parent, align, pad, width, height, ox, oy)
  if not fontString or not parent then return end
  pad = tonumber(pad) or 2
  width = tonumber(width)
  height = tonumber(height)
  if not width and parent.GetWidth then width = parent:GetWidth() end
  if not height and parent.GetHeight then height = parent:GetHeight() end
  width = tonumber(width) or 40
  height = tonumber(height) or 20
  if width < 8 then width = 8 end
  if height < 8 then height = 8 end
  if not align then align = "center" end
  ox = tonumber(ox) or 0
  oy = tonumber(oy) or 0

  local left, bottom = pad, pad
  local right, top = width - pad, height - pad
  local colW = math.floor((width - pad * 2) * .58)
  local rowH = math.floor((height - pad * 2) * .5)
  if colW < 10 then colW = 10 end
  if rowH < 8 then rowH = 8 end

  if align == "left" or align == "topleft" or align == "bottomleft" then
    right = left + colW
  elseif align == "right" or align == "topright" or align == "bottomright" then
    left = right - colW
  end
  if align == "top" or align == "topleft" or align == "topright" then
    bottom = top - rowH
  elseif align == "bottom" or align == "bottomleft" or align == "bottomright" then
    top = bottom + rowH
  end

  fontString:ClearAllPoints()
  fontString:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", left + ox, bottom + oy)
  fontString:SetPoint("TOPRIGHT", parent, "BOTTOMLEFT", right + ox, top + oy)
  if fontString.SetJustifyH then
    local h = "CENTER"
    if string.find(align, "left") then h = "LEFT"
    elseif string.find(align, "right") then h = "RIGHT" end
    pcall(fontString.SetJustifyH, fontString, h)
  end
end

-- Every window the ported modules build goes through here, so this is the one
-- place that decides whether they look like QtUiPlus or like QtUI.
--
-- The QtUI original painted a dark blue-grey fill with the native
-- UI-Tooltip-Border edge art. That is not this addon's panel: core/style.lua
-- uses a near-black fill with a single thin outline and no stock edge art, and
-- deliberately clears the native edge, because SetBackdrop leaves it drawing on
-- top. Routing through U.CreateBackdrop gets that treatment, and any future
-- change to the panel style reaches the ported windows for free.
--
-- U.CreateBackdrop lives in core/style.lua, which loads AFTER this file. That
-- is fine: this runs when a window is built, long after every file has loaded.
function QtP:CreatePanel(name, parent, level)
  local panel = CreateFrame("Frame", name, parent or UIParent)
  panel:SetFrameStrata("BACKGROUND")
  panel:SetFrameLevel(level or 1)

  if type(U.CreateBackdrop) == "function" then
    U.CreateBackdrop(panel)
  elseif panel.SetBackdrop then
    -- Only reachable if core/style.lua failed to load; an opaque panel still
    -- beats a transparent one.
    pcall(panel.SetBackdrop, panel, { bgFile = M.texture.plain })
    pcall(panel.SetBackdropColor, panel, M.Unpack(M.color.background))
    pcall(panel.SetBackdropBorderColor, panel, 0, 0, 0, 0)
  end

  return panel
end

-- ---------------------------------------------------------------------------
-- Panel painting
--
-- The ported windows paint their own chrome inline, in a dozen places, with
-- QtUI's blue-grey literals and the native UI-Tooltip-Border edge. Colouring
-- that backdrop is not enough: the stock edge art is what still reads as QtUI.
-- These helpers route through U.CreateBackdrop so a ported popup gets the same
-- near-black fill and 1px outline as every other QtUiPlus panel.
--
-- Colour arguments are not accepted on purpose: the point is that a ported
-- window cannot invent a shade that the rest of the UI does not use.
-- ---------------------------------------------------------------------------
local function ShowEdges(frame)
  local edges = frame and frame.qtpEdges
  if not edges then return end
  local i
  for i = 1, table.getn(edges) do
    pcall(edges[i].Show, edges[i])
  end
end

local function Paint(frame, fill, edge)
  if not frame then return end
  if type(U.CreateBackdrop) == "function" then
    U.CreateBackdrop(frame, { background = fill, border = edge })
    ShowEdges(frame)
    return
  end
  if not frame.SetBackdropColor then return end
  pcall(frame.SetBackdropColor, frame, M.Unpack(fill))
  if frame.SetBackdropBorderColor then
    pcall(frame.SetBackdropBorderColor, frame, M.Unpack(edge))
  end
end

-- The base panel: menus and popups.
function QtP.PaintPanel(frame)
  Paint(frame, M.color.background, M.color.border)
end

-- A row or button sitting on top of a panel. Same family, lifted just enough
-- to separate from the panel behind it.
function QtP.PaintSurface(frame)
  Paint(frame, M.color.backgroundRaised, M.color.border)
end

-- A hovered or selected row. QtUI used a saturated blue here, which is the one
-- colour that reads as "not this addon" next to the QtUiPlus accent.
function QtP.PaintHover(frame)
  Paint(frame, M.color.accentFill, M.color.accent)
end

-- Settings-sidebar row: no outline, accent fill when selected, a faint lift
-- on hover. Ported lists that still paint boxed QtUI rows go through here.
local function HideEdges(frame)
  local edges = frame and frame.qtpEdges
  if not edges then return end
  local i
  for i = 1, table.getn(edges) do
    pcall(edges[i].Hide, edges[i])
  end
end

function QtP.PaintListRow(frame, selected)
  if not frame then return end
  if type(U.CreateBackdrop) == "function" then
    if selected then
      U.CreateBackdrop(frame, { background = M.color.accentFill, border = false })
    else
      U.CreateBackdrop(frame, { background = { 0, 0, 0, 0 }, border = false })
    end
    HideEdges(frame)
    return
  end
  Paint(frame, selected and M.color.accentFill or M.color.backgroundRaised,
        M.color.border)
end

function QtP.HoverListRow(frame)
  if not frame or frame.qtpActive then return end
  if type(U.SetBackgroundColor) == "function" then
    U.SetBackgroundColor(frame, 1, 1, 1, 0.07)
  end
end

-- Fully transparent, for hiding a panel background.
function QtP.PaintClear(frame)
  if type(U.SetBackdropShown) == "function" then
    U.SetBackdropShown(frame, false)
    return
  end
  if not frame or not frame.SetBackdropColor then return end
  pcall(frame.SetBackdropColor, frame, 0, 0, 0, 0)
  if frame.SetBackdropBorderColor then
    pcall(frame.SetBackdropBorderColor, frame, 0, 0, 0, 0)
  end
end

-- Shared close glyph used by bags/bank, so ported popups do not keep QtUI's
-- gold "X" caption.
function QtP.AttachCloseButton(parent, onClick)
  if type(U.CreateCloseButton) == "function" then
    return U.CreateCloseButton(parent, { size = 16, onClick = onClick })
  end
  local button = CreateFrame("Button", nil, parent)
  button:SetWidth(16)
  button:SetHeight(16)
  pcall(button.EnableMouse, button, true)
  pcall(button.RegisterForClicks, button, "LeftButtonUp")
  button.text = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  button.text:SetPoint("CENTER", button, "CENTER", 0, 0)
  button.text:SetText("X")
  if type(onClick) == "function" then
    button:SetScript("OnClick", onClick)
  end
  return button
end

function QtP.ApplyTitleFont(fontString)
  local c = M.color.textAccent
  QtP:ApplyFont(fontString, 12, c[1], c[2], c[3])
end

function QtP.ApplyBodyFont(fontString)
  local c = M.color.text
  QtP:ApplyFont(fontString, 11, c[1], c[2], c[3])
end

function QtP.ApplyMutedFont(fontString)
  local c = M.color.textDim
  QtP:ApplyFont(fontString, 10, c[1], c[2], c[3])
end

-- QtUI's MoveMode called QtUI:RegisterMovable to enrol a window in edit mode.
-- QtUiPlus has its own mover system, so the ported call is bridged here rather
-- than porting MoveMode.lua alongside a mover that already does the job.
-- Without this the ported windows are simply not draggable: the call sites
-- guard with `if self.RegisterMovable then`, so a missing bridge fails silently
-- and the window just sits where it was put.
function QtP:RegisterMovable(id, label, frame, default)
  if type(id) ~= "string" or not frame then return end
  -- Rebind first: a window that was closed and re-added reuses its id with a
  -- new frame object, and RegisterMover rejects a duplicate id.
  if U.RebindMover(id, frame) then return end
  U.RegisterMover(id, frame, { label = label or id, default = default })
end

-- ---------------------------------------------------------------------------
-- Layout
--
-- Only the keys the ported modules actually read are defined here, carrying
-- QtUI's own defaults and clamps. Anything QtUiPlus already owns -- unit frame
-- sizes, bar geometry, colours -- stays in QtUiPlusDB proper and is not
-- duplicated into a second, competing store.
-- ---------------------------------------------------------------------------
local function Bool(layout, key, default)
  if layout[key] ~= true and layout[key] ~= false then
    layout[key] = default
  end
end

local function Num(layout, key, default, minimum, maximum)
  local value = tonumber(layout[key])
  if not value then value = default end
  if value < minimum then value = minimum end
  if value > maximum then value = maximum end
  layout[key] = value
end

function QtP:EnsureLayoutDefaults()
  local db = EnsureDB()
  if type(db.layout) ~= "table" then db.layout = {} end
  local layout = db.layout

  Bool(layout, "cooldownText", true)
  Bool(layout, "eqCompare", true)
  Bool(layout, "estimateMobHealth", true)
  Bool(layout, "vendorPrices", true)
  Bool(layout, "autoLoot", true)
  Bool(layout, "autoSell", true)

  Bool(layout, "clockLocal", false)
  Bool(layout, "dataTextCompact", false)

  Num(layout, "chatWidth", 380, 180, 700)
  Num(layout, "chatHeight", 190, 80, 500)
  Num(layout, "chatFontSize", 12, 8, 20)
  Bool(layout, "chatTime", true)
  Bool(layout, "chatClassNames", true)
  Bool(layout, "chatSocial", true)

  return layout
end

local layoutCache

function QtP:GetLayout()
  local db = QtPDB
  if layoutCache and db and layoutCache == db.layout then return layoutCache end
  layoutCache = self:EnsureLayoutDefaults()
  return layoutCache
end

-- Ported modules gate themselves on a feature key. Route that to the QtUiPlus
-- per-module enable flag so /qtp and the settings panel stay the one place a
-- feature is turned on or off.
function QtP:IsFeatureEnabled(key)
  if type(key) ~= "string" then return true end
  if not U.db or type(U.db.modules) ~= "table" then return true end
  -- Ported modules ask with QtUI's camelCase feature keys ("eqCompare")
  -- while module names are lowercase. Fold the case so both reach one flag.
  local entry = U.db.modules[string.lower(key)]
  if type(entry) ~= "table" then return true end
  return entry.enabled ~= false
end

-- The layout must exist before any ported module's OnInit reads it. This file
-- is listed ahead of them in the .toc and QtUiPlus runs OnInit in registration
-- order, so registering here is enough.
local Compat = U.RegisterModule("qtcompat")

function Compat:OnInit()
  QtP:EnsureLayoutDefaults()
end
