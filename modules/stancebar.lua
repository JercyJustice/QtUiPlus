-- QtUiPlus :: modules/stancebar.lua
--
-- The stance / shapeshift bar, in the pfUI-modern button style shared with
-- modules/actionbar.lua and modules/petbar.lua. Warrior stances, druid forms,
-- rogue Stealth, priest Shadowform and paladin auras all drive the same native
-- ShapeshiftButton1-10 and are all handled here.
--
-- CLASS GATE REMOVED (QtUiPlus): the UnrealUI original built this bar only for
-- warriors, which left every other stance-using class with no bar at all. QtUI
-- drives it from the form count for any class, which is the behaviour kept
-- here. No class test is needed to do that safely --
-- emberveil.org/wiki/lua/globals/Spell documents GetNumShapeshiftForms as
-- returning "how many stance / shapeshift bar slots the player currently has",
-- including 0 for a class with no stance bar, so the count IS the gate. A mage
-- or hunter still never gets a frame, a mover or a button built.
--
-- Compatibility notes that shaped this file:
--
--   * documentation.json: GetNumShapeshiftForms(), CastShapeshiftForm(id) and
--     GetShapeshiftFormCooldown(id) -> start, duration, enable are
--     OFFICIAL_CLIENT_DOCUMENTATION / DOCUMENTED_NOT_RUNTIME_VERIFIED.
--     GetShapeshiftFormInfo(id) -> texture, name, isActive, isCastable is the
--     same class of evidence, and its return order matches UnrealPfUI's
--     working bar-11 branch (modules/actionbar.lua:608,718,787) --
--     WORKING_SOURCE agreement, not runtime-verified on this client.
--   * behavior.json / actionpaging.eventRegistration: UPDATE_SHAPESHIFT_FORM
--     and PLAYER_AURAS_CHANGED both registered without error on this client
--     (RUNTIME evidence, though not captured on a warrior). UPDATE_SHAPESHIFT_
--     FORMS (plural) is UnrealPfUI's own event for this same bar
--     (modules/actionbar.lua:1447) with no compact record here; kept as a
--     third, harmless accelerator. The periodic slot sweep below is what
--     actually guarantees a refresh if none of the three fire.
--   * GameTooltip:SetShapeshift(index) is OFFICIAL_CLIENT_DOCUMENTATION.
--   * knowledge.json / actionbars.native_stock_children_suppression: the
--     native ShapeshiftBarFrame and its ShapeshiftButton1-N need the same
--     explicit suppress-and-reapply treatment as the other stock bars;
--     UnrealPfUI/modules/actionbar.lua:84,90 names the same frame/prefix
--     (WORKING_SOURCE).

local U = QtUiPlus
local M = U.media

local SB = U.RegisterModule("stancebar")

local ICON_INSET = 2
local SIZE = 30
local SPACING = 3
local MAX_SLOTS = 10 -- native ShapeshiftButton1-10; a warrior only ever fills 3

local COLOR = {
  cooldown = { 1.00, 0.20, 0.20, 1.00 },
}

local frame, buttons = nil, {}
local shown = false
local slotCount = 0
-- Latched once the player is known to have forms, so an unlocked edit-mode
-- placeholder is offered to a class that has a bar but has momentarily
-- reported zero slots (the login race noted in Layout), and never to a class
-- that has none at all.
local everHadForms = false

-- ---------------------------------------------------------------------------
-- Client calls
--
-- Resolved by name and pcall'd, same pattern as modules/actionbar.lua and
-- modules/petbar.lua: a missing call degrades one part of the bar rather than
-- erroring the module.
-- ---------------------------------------------------------------------------
local apiFnCache = {}

local function ResolveApiFn(name)
  local cached = apiFnCache[name]
  if cached ~= nil then
    if cached == false then return nil end
    return cached
  end

  local fn = U.G(name)
  if type(fn) == "function" then
    apiFnCache[name] = fn
    return fn
  end
  apiFnCache[name] = false
  return nil
end

local function Call(name, a, b, c)
  local fn = ResolveApiFn(name)
  if not fn then return nil end
  local ok, r1, r2, r3 = pcall(fn, a, b, c)
  if not ok then return nil end
  return r1, r2, r3
end

local function Has(name)
  return ResolveApiFn(name) and true or false
end

-- GetShapeshiftFormInfo returns four values; the shared Call() above only
-- forwards three, so this gets its own fixed-arity wrapper.
local function GetFormInfo(id)
  local fn = ResolveApiFn("GetShapeshiftFormInfo")
  if not fn then return nil end
  local ok, texture, name, active, castable = pcall(fn, id)
  if not ok then return nil end
  return texture, name, active, castable
end

-- ---------------------------------------------------------------------------
-- Buttons
-- ---------------------------------------------------------------------------
local function ApplyBorder(button)
  if button.qtpCdActive then
    U.SetBorderColor(button, COLOR.cooldown[1], COLOR.cooldown[2], COLOR.cooldown[3], 1)
  elseif button.qtpActive then
    U.SetBorderColor(button, M.Unpack(M.color.accent))
  elseif button.qtpHover then
    U.SetBorderColor(button, 0.55, 0.55, 0.55, 1)
  else
    U.SetBorderColor(button, M.Unpack(M.color.border))
  end
end

local function OnButtonClick(button)
  Call("CastShapeshiftForm", button.qtpIndex)
end

local function ShowTooltip(button)
  local tooltip = U.G("GameTooltip")
  if not tooltip then return end
  pcall(tooltip.SetOwner, tooltip, button, "ANCHOR_RIGHT")
  if pcall(tooltip.SetShapeshift, tooltip, button.qtpIndex) then
    pcall(tooltip.Show, tooltip)
  else
    pcall(tooltip.Hide, tooltip)
  end
end

local function HideTooltip()
  local tooltip = U.G("GameTooltip")
  if tooltip then pcall(tooltip.Hide, tooltip) end
end

local function CreateButton(index)
  local name = "QtUiPlusStanceBarButton" .. index
  local button = CreateFrame("Button", name, frame)
  button.qtpIndex = index

  U.CreateBackdrop(button, {})
  pcall(button.EnableMouse, button, true)
  pcall(button.RegisterForClicks, button, "LeftButtonUp")

  local icon = button:CreateTexture(nil, "ARTWORK")
  pcall(icon.SetTexCoord, icon, 0.08, 0.92, 0.08, 0.92)
  button.qtpIcon = icon

  -- Same Model-frame cooldown swipe as modules/actionbar.lua and
  -- modules/petbar.lua; see actionbar.lua's header note for why this is the
  -- native Vanilla-shaped primitive rather than a synthetic overlay.
  local ok, cooldown = pcall(CreateFrame, "Model", name .. "Cooldown", button,
                             "CooldownFrameTemplate")
  if ok and cooldown and Has("CooldownFrame_SetTimer") then
    pcall(cooldown.SetAllPoints, cooldown, button)
    button.qtpCooldown = cooldown
  end

  button:SetScript("OnClick", function() OnButtonClick(button) end)
  button:SetScript("OnEnter", function()
    button.qtpHover = true
    ApplyBorder(button)
    ShowTooltip(button)
  end)
  button:SetScript("OnLeave", function()
    button.qtpHover = false
    ApplyBorder(button)
    HideTooltip()
  end)

  button:SetWidth(SIZE)
  button:SetHeight(SIZE)
  icon:ClearAllPoints()
  icon:SetPoint("TOPLEFT", button, "TOPLEFT", ICON_INSET, -ICON_INSET)
  icon:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -ICON_INSET, ICON_INSET)

  return button
end

local function HideButton(button)
  button.qtpCdActive = false
  if button.qtpCooldown then pcall(button.qtpCooldown.Hide, button.qtpCooldown) end
  button:Hide()
end

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local function UpdateSlot(button)
  local texture, _, active, castable = GetFormInfo(button.qtpIndex)

  if type(texture) == "string" and texture ~= "" then
    pcall(button.qtpIcon.SetTexture, button.qtpIcon, texture)
    button.qtpIcon:Show()
  else
    pcall(button.qtpIcon.SetTexture, button.qtpIcon, nil)
    button.qtpIcon:Hide()
  end

  pcall(button.qtpIcon.SetDesaturated, button.qtpIcon, not castable)

  button.qtpActive = active and true or false
  ApplyBorder(button)
end

local function UpdateCooldown(button)
  local start, duration, enable = Call("GetShapeshiftFormCooldown", button.qtpIndex)
  start = tonumber(start) or 0
  duration = tonumber(duration) or 0

  if button.qtpCooldown then
    local fn = ResolveApiFn("CooldownFrame_SetTimer")
    if fn then pcall(fn, button.qtpCooldown, start, duration, tonumber(enable) or 1) end
  end

  button.qtpCdActive = (start > 0 and duration > 0) and true or false
  ApplyBorder(button)
end

local function FullUpdate(button)
  UpdateSlot(button)
  UpdateCooldown(button)
end

local function ForEachButton(callback)
  -- /qtp perf stancebar. Both recurring sweeps walk the buttons through here.
  if U.PerfDisabled and U.PerfDisabled("stancebar") then return end
  if not shown then return end
  local i
  for i = 1, table.getn(buttons) do callback(buttons[i]) end
end

-- Highest occupied slot, not the number of occupied slots: buttons are indexed
-- by form id, so a gap must still be spanned or every button past it would be
-- drawn against the wrong form. GetShapeshiftFormInfo "returns no values if id
-- is out of range or the slot has no spell" (client wiki), so a slot with no
-- texture is an empty well -- which is what kept a warrior from being given
-- ten of them when the raw count over-reports.
local function CountForms()
  local raw = tonumber(Call("GetNumShapeshiftForms")) or 0
  if raw > MAX_SLOTS then raw = MAX_SLOTS end

  local highest = 0
  local i
  for i = 1, raw do
    local texture = GetFormInfo(i)
    if texture then highest = i end
  end
  return highest
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------
local function CreateBar()
  frame = CreateFrame("Frame", "QtUiPlusStanceBar", UIParent)
  -- Matches the main action bars and pet bar: stays below overlapping native
  -- interface windows.
  pcall(frame.SetFrameStrata, frame, "LOW")
  frame:SetWidth(100)
  frame:SetHeight(SIZE)

  local i
  for i = 1, MAX_SLOTS do buttons[i] = CreateButton(i) end

  U.RegisterMover("stancebar", frame, {
    label = "Stance Bar",
    default = { point = "BOTTOM", relativePoint = "BOTTOM", x = -120, y = 64 },
  })
end

local function Layout()
  if not frame then return end

  slotCount = CountForms()
  if slotCount > 0 then everHadForms = true end
  -- A bar with zero forms (a brief race right after login, before the
  -- spellbook is synced) could never be dragged into place: keep the same
  -- unlocked-placeholder rule modules/petbar.lua and modules/castbar.lua use.
  -- Gated on everHadForms so a class with no stance bar is not offered an
  -- empty placeholder every time edit mode opens.
  local visible = slotCount > 0 or (U.IsUnlocked() and everHadForms)
  local count = slotCount > 0 and slotCount or 3
  if count > MAX_SLOTS then count = MAX_SLOTS end

  frame:SetWidth(count * SIZE + (count - 1) * SPACING)
  frame:SetHeight(SIZE)

  local i
  for i = 1, MAX_SLOTS do
    local button = buttons[i]
    if visible and i <= count then
      button:ClearAllPoints()
      button:SetPoint("TOPLEFT", frame, "TOPLEFT", (i - 1) * (SIZE + SPACING), 0)
      button:Show()
      FullUpdate(button)
    else
      HideButton(button)
    end
  end

  shown = visible
  if visible then frame:Show() else frame:Hide() end
end

local function Apply()
  -- The form count is the gate (see the header). Nothing is built for a class
  -- that has never reported a slot, so a mage pays one API call per sweep and
  -- gets no frame, no buttons and no mover.
  if not frame then
    if not everHadForms and (tonumber(Call("GetNumShapeshiftForms")) or 0) < 1 then
      return
    end
    CreateBar()
  end
  Layout()
end

-- ---------------------------------------------------------------------------
-- Native bar
-- ---------------------------------------------------------------------------
local NATIVE_PARTS = {
  "Icon", "NormalTexture", "NormalTexture2", "HotKey", "Count",
  "Border", "Cooldown", "Flash", "Name", "AutoCastable",
}

local function SuppressNativeBar()
  local names = { "ShapeshiftBarFrame" }
  local i, j
  for i = 1, MAX_SLOTS do
    local base = "ShapeshiftButton" .. i
    table.insert(names, base)
    for j = 1, table.getn(NATIVE_PARTS) do
      table.insert(names, base .. NATIVE_PARTS[j])
    end
  end
  U.SuppressNativeFrame(names)
end

-- ---------------------------------------------------------------------------
-- Events and refresh
-- ---------------------------------------------------------------------------
local function RegisterEvents()
  U.RegisterEvent("PLAYER_ENTERING_WORLD", function() Apply() end)
  U.RegisterEvent("UPDATE_SHAPESHIFT_FORM", function() ForEachButton(FullUpdate) end)
  U.RegisterEvent("UPDATE_SHAPESHIFT_FORMS", function() Apply() end)
  U.RegisterEvent("PLAYER_AURAS_CHANGED", function() ForEachButton(UpdateSlot) end)
end

function SB:OnEnable()
  -- Suppression is unconditional: ShapeshiftBarFrame and its buttons exist for
  -- every class, and hiding a bar a class never populates costs nothing, while
  -- skipping it for a druid would leave the native bar drawn over this one.
  SuppressNativeBar()
  Apply()
  RegisterEvents()

  -- Two rates, same reasoning as modules/petbar.lua: state (cooldown/active
  -- border) is what the eye tracks and ticks faster; the full slot-contents +
  -- visibility sweep is the low-frequency safety net that catches anything
  -- the accelerator events above missed (including an edit-mode lock/unlock).
  U.RegisterUpdate("stancebar.cooldown", 0.5, function() ForEachButton(UpdateCooldown) end)
  U.RegisterUpdate("stancebar.slots", 0.5, function() Apply() end)
end

-- Reported by /qtp check.
function U.StanceBarReport()
  return {
    everHadForms = everHadForms,
    created = frame and true or false,
    shown = shown,
    slotCount = slotCount,
  }
end
