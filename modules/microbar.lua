-- QtUiPlus :: modules/microbar.lua
--
-- pfUI-style micro button bar: pulls the client's own micro menu buttons
-- (character, spellbook, talent, quest log, social, world map, main menu,
-- help) into one compact, movable row. The buttons' own native art is left
-- completely untouched -- reparented and scaled down only -- which is
-- deliberate, not an omission: see the reskin note below. The enable option
-- lives on the settings window's General page (modules/settings.lua) rather
-- than a dedicated tab, since it is the bar's only setting.
--
-- Evidence gap: query_compat.py has no runtime record for MICRO_BUTTONS or
-- any individual *MicroButton global on this client. UnrealPfUI's own
-- modules/panel.lua and UnrealRuntimeProbe's TargetedProbes.lua already
-- document that gap and fall back to the vanilla candidate names below,
-- checking _G for each before touching it. This module reuses that exact
-- fallback list and existence check. A candidate this client does not have is
-- simply skipped, so the worst case is an empty bar, never an error.
--
-- Reskin history (do not repeat without new evidence): two flat-icon reskin
-- attempts were tried and both regressed visually in-game and were reverted.
-- MEASURED (2026-08-18, /qtp check on this client -- knowledge.json /
-- ui.microbutton_icon_child_absent): none of the 8 candidates expose a
-- "<name>Icon" child distinct from their own Normal/Pushed/Highlight/Disabled
-- state art, unlike quest log/spellbook rows (which do, and are the case
-- core/stockui.lua's U.StyleStockButton was written for). A first attempt
-- drew a flat panel behind the untouched native art -- boxed/broken look. A
-- second attempt cropped the button's own GetNormalTexture() as a substitute
-- icon (the same trim actionbar icons use) with no border/background -- also
-- reported broken/distorted in-game. Native micro button face art is left
-- alone until there is a confirmed technique, not another guess.
--
-- `/qtp check` reports how many candidates resolved.
--
-- Disabling the feature (General page checkbox, U.ModuleConfig "microbar")
-- hands every installed button back to its captured original parent, anchor
-- and scale, so turning it off returns the stock micro menu to where the
-- client originally put it.

local U = QtUiPlus
local M = U.media

local MB = U.RegisterModule("microbar")

local BUTTON_NAMES = {
  "CharacterMicroButton", "SpellbookMicroButton", "TalentMicroButton",
  "QuestLogMicroButton", "SocialsMicroButton", "WorldMapMicroButton",
  "MainMenuMicroButton", "HelpMicroButton",
}

local BUTTON_SCALE = 0.6
local BUTTON_GAP = 0
local HEIGHT = 23
-- pfUI's own microbutton panel is a hard-coded 145 wide for these same 8
-- candidates at the same 0.6 scale (UnrealPfUI modules/panel.lua); reused
-- here as a WORKING_SOURCE width rather than a measured one, scaled down when
-- fewer candidates resolve on this client.
local FULL_WIDTH = 145
local MIN_WIDTH = 40
local GRIP_SIZE = 14
local SIZE_LIMITS = {
  width  = { min = 40, max = 420 },
  height = { min = 14, max = 64 },
}

local config
local anchor
local buttons = {}   -- name -> captured original state + button reference
local buttonScale = BUTTON_SCALE

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------
local function EnsureConfig()
  if not config then
    config = U.ModuleConfig("microbar", {
      enabled = true,
      width = FULL_WIDTH,
      height = HEIGHT,
    })
  end
  return config
end

local function ClampSize(key, value)
  local limit = SIZE_LIMITS[key]
  value = tonumber(value)
  if not value then return nil end
  if value < limit.min then return limit.min end
  if value > limit.max then return limit.max end
  return U.Round(value)
end

local function StoredSize()
  EnsureConfig()
  local w = ClampSize("width", config.width) or FULL_WIDTH
  local h = ClampSize("height", config.height) or HEIGHT
  return w, h
end

-- ---------------------------------------------------------------------------
-- Button capture / install / restore
-- ---------------------------------------------------------------------------

-- Captures a button's pre-microbar state exactly once. U.GetFramePoint already
-- normalises this client's inverted GetPoint Y (core/compat.lua); feeding that
-- normalised tuple straight back into SetPoint against the *original* relative
-- frame is the same round-trip core/mover.lua relies on for saved positions.
local function CaptureOriginal(name, button)
  local entry = buttons[name]
  if entry then return entry end

  local point, relative, relativePoint, x, y = U.GetFramePoint(button, 1)
  local parentOk, parent = pcall(button.GetParent, button)
  local scaleOk, scale = pcall(button.GetScale, button)

  entry = {
    button = button,
    parent = parentOk and parent or nil,
    point = point,
    relative = relative,
    relativePoint = relativePoint,
    x = x,
    y = y,
    scale = (scaleOk and tonumber(scale)) or nil,
  }
  buttons[name] = entry
  return entry
end

-- Reparents every resolved candidate into the bar, left to right in candidate
-- order, and returns how many were actually available on this client.
local function ArrangeButtons()
  local prev, count = nil, 0
  local i

  for i = 1, table.getn(BUTTON_NAMES) do
    local entry = buttons[BUTTON_NAMES[i]]
    if entry and entry.button then
      local button = entry.button

      pcall(button.SetParent, button, anchor)
      pcall(button.ClearAllPoints, button)
      if prev then
        pcall(button.SetPoint, button, "LEFT", prev, "RIGHT", BUTTON_GAP, 0)
      else
        pcall(button.SetPoint, button, "LEFT", anchor, "LEFT", 0, 0)
      end
      pcall(button.SetScale, button, buttonScale)
      pcall(button.Show, button)

      prev = button
      count = count + 1
    end
  end

  return count
end

-- Hands every captured button back to where it came from. Order does not
-- matter here: each entry restores against its own captured relative frame,
-- not against the previous button in the bar.
local function RestoreButtons()
  local i
  for i = 1, table.getn(BUTTON_NAMES) do
    local entry = buttons[BUTTON_NAMES[i]]
    if entry and entry.button then
      local button = entry.button
      pcall(function()
        button:SetParent(entry.parent or UIParent)
        button:ClearAllPoints()
        if entry.point then
          button:SetPoint(entry.point, entry.relative or UIParent,
                          entry.relativePoint or entry.point,
                          entry.x or 0, entry.y or 0)
        end
        if entry.scale then button:SetScale(entry.scale) end
      end)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Bar frame
-- ---------------------------------------------------------------------------
local function ScaleForSize(w, h)
  local scaleW = (w / FULL_WIDTH) * BUTTON_SCALE
  local scaleH = (h / HEIGHT) * BUTTON_SCALE
  local scale = scaleW
  if scaleH < scale then scale = scaleH end
  if scale < 0.35 then scale = 0.35 end
  if scale > 1.15 then scale = 1.15 end
  return scale
end

local function ReadAnchorSize()
  if not anchor then return StoredSize() end
  local w = tonumber(anchor:GetWidth())
  local h = tonumber(anchor:GetHeight())
  local okL, left = pcall(anchor.GetLeft, anchor)
  local okR, right = pcall(anchor.GetRight, anchor)
  local okT, top = pcall(anchor.GetTop, anchor)
  local okB, bottom = pcall(anchor.GetBottom, anchor)
  if okL and okR and tonumber(left) and tonumber(right) then
    local edgeW = math.abs(right - left)
    if edgeW > 1 then w = edgeW end
  end
  if okT and okB and tonumber(top) and tonumber(bottom) then
    local edgeH = math.abs(top - bottom)
    if edgeH > 1 then h = edgeH end
  end
  return ClampSize("width", w) or FULL_WIDTH, ClampSize("height", h) or HEIGHT
end

local function LayoutBar(w, h)
  if not anchor then return end
  w = ClampSize("width", w) or FULL_WIDTH
  h = ClampSize("height", h) or HEIGHT
  buttonScale = ScaleForSize(w, h)
  ArrangeButtons()
  anchor:SetWidth(w)
  anchor:SetHeight(h)
end

local function CommitResize()
  if not anchor then return end
  local w, h = ReadAnchorSize()
  EnsureConfig()
  config.width = w
  config.height = h
  LayoutBar(w, h)
  if type(U.GetFramePoint) == "function" and type(U.SavePosition) == "function" then
    local point, _, relativePoint, x, y = U.GetFramePoint(anchor, 1)
    if point then U.SavePosition("microbar", point, relativePoint, x, y) end
  end
end

local function AttachResizeGrip()
  if not anchor or anchor.qtpResizeGrip then return end

  local grip = CreateFrame("Button", "QtUiPlusMicroBarGrip", anchor)
  grip:SetWidth(GRIP_SIZE)
  grip:SetHeight(GRIP_SIZE)
  grip:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", 2, -2)
  pcall(grip.EnableMouse, grip, true)
  grip:RegisterForDrag("LeftButton")

  local levelOk, level = pcall(anchor.GetFrameLevel, anchor)
  if levelOk and tonumber(level) then
    pcall(grip.SetFrameLevel, grip, tonumber(level) + 30)
  end

  local icon = grip:CreateTexture(nil, "ARTWORK")
  pcall(icon.SetTexture, icon, M.texture.chatResizeGrip)
  icon:SetAllPoints(grip)

  grip:SetScript("OnDragStart", function()
    if not U.IsUnlocked or not U.IsUnlocked() then return end
    pcall(anchor.SetResizable, anchor, true)
    pcall(anchor.SetMinResize, anchor,
          SIZE_LIMITS.width.min, SIZE_LIMITS.height.min)
    pcall(anchor.SetMaxResize, anchor,
          SIZE_LIMITS.width.max, SIZE_LIMITS.height.max)
    pcall(anchor.StartSizing, anchor, "BOTTOMRIGHT")
    if type(U.RegisterUpdate) == "function" then
      U.RegisterUpdate("microbar.resize", 0, function()
        local liveW, liveH = ReadAnchorSize()
        LayoutBar(liveW, liveH)
      end)
    end
  end)
  grip:SetScript("OnDragStop", function()
    if type(U.UnregisterUpdate) == "function" then
      U.UnregisterUpdate("microbar.resize")
    end
    pcall(anchor.StopMovingOrSizing, anchor)
    CommitResize()
  end)

  anchor.qtpResizeGrip = grip
  grip:Hide()
end

local function UpdateResizeGrip()
  local grip = anchor and anchor.qtpResizeGrip
  if not grip then return end
  local show = config and config.enabled and U.IsUnlocked and U.IsUnlocked()
  if show then
    local levelOk, level = pcall(anchor.GetFrameLevel, anchor)
    if levelOk and tonumber(level) then
      pcall(grip.SetFrameLevel, grip, tonumber(level) + 30)
    end
    pcall(grip.Show, grip)
  else
    pcall(grip.Hide, grip)
  end
end

local function Build()
  anchor = CreateFrame("Frame", "QtUiPlusMicroBarAnchor", UIParent)
  local w, h = StoredSize()
  anchor:SetWidth(w)
  anchor:SetHeight(h)
  pcall(anchor.SetFrameStrata, anchor, "MEDIUM")

  U.RegisterMover("microbar", anchor, {
    label = "Micro Bar",
    default = { point = "TOPRIGHT", relativePoint = "TOPRIGHT", x = -190, y = -70 },
    -- A disabled bar keeps its stored position but offers no drag handle in
    -- edit mode; see core/mover.lua.
    visible = function() return config and config.enabled end,
  })
  AttachResizeGrip()
end

-- Applies the current enabled state: installs (and sizes the bar around)
-- every resolved candidate, or restores everything to its stock location.
local function Apply()
  if not anchor then return end

  if not config.enabled then
    RestoreButtons()
    anchor:Hide()
    UpdateResizeGrip()
    return
  end

  local i
  for i = 1, table.getn(BUTTON_NAMES) do
    local name = BUTTON_NAMES[i]
    local button = U.G(name)
    if button then CaptureOriginal(name, button) end
  end

  local count = ArrangeButtons()
  local w, h = StoredSize()
  LayoutBar(w, h)
  anchor:Show()
  UpdateResizeGrip()

  if count == 0 then
    U.Debug("microbar: none of the " .. table.getn(BUTTON_NAMES) ..
            " candidate micro buttons resolved on this client")
  end
end

-- Public so modules/settings.lua's General page can flip the checkbox without
-- reaching into this module's internals.
U.ApplyMicroBar = Apply

-- Measured readout for /qtp check: which candidates resolved, so an empty bar
-- in-game can be told apart from a client that simply has none of these
-- globals.
function U.MicroBarReport()
  local report = { enabled = config and config.enabled, found = {}, missing = {} }
  local i
  for i = 1, table.getn(BUTTON_NAMES) do
    local name = BUTTON_NAMES[i]
    if U.G(name) then
      table.insert(report.found, name)
    else
      table.insert(report.missing, name)
    end
  end
  return report
end

-- ---------------------------------------------------------------------------
-- Registration
-- ---------------------------------------------------------------------------
function MB:OnInit()
  EnsureConfig()
end

function MB:OnEnable()
  EnsureConfig()
  if not anchor then Build() end
  Apply()
  if type(U.RegisterUpdate) == "function" then
    U.RegisterUpdate("microbar.grip", 0.2, UpdateResizeGrip)
  end
end
