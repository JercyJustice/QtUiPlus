-- QtUiPlus :: modules/combopoints.lua
--
-- Standalone combo point display: five squares, movable, with configurable
-- size, spacing, colour and background. Replaces the four-pixel slivers
-- modules/unitframes.lua used to overlay on the player health bar, which were
-- effectively invisible and had no settings of their own.
--
-- Three things the previous implementation got wrong, all fixed here:
--
--  1. API SIGNATURE. It called GetComboPoints("target").
--     emberveil.org/wiki/lua/globals/Character documents GetComboPoints as
--     taking NO arguments and returning the points on the current target --
--     "Only Rogue and Druid can have combo points". core/auradata.lua in this
--     same addon already called it with no arguments, so the two disagreed.
--     The no-argument form is used here, with the two-argument form kept only
--     as a fallback for a client that wants it.
--
--  2. NO POLLING. Refresh was driven purely by UNIT_COMBO_POINTS /
--     PLAYER_COMBO_POINTS. Neither is in this client's observed-event set, and
--     every other bar in QtUiPlus (pet, stance, action) pairs its events with a
--     periodic sweep for exactly that reason. If the events never arrive, the
--     display simply never updates. A sweep is registered below.
--
--  3. CLASS DETECTION. Points were rogue-only, and the druid fix that followed
--     keyed off "count > 0". Neither is right: a druid has combo points in cat
--     form specifically, which is what UnitPowerType("player") == 3 (energy)
--     identifies. That is what QtUI checks, and it means the bar appears on
--     shifting into cat and disappears on leaving it, rather than blinking in
--     and out as points come and go.

local U = QtUiPlus
local M = U.media

local CP = U.RegisterModule("combopoints")

local MAX_POINTS = 5
local PAD = 4
-- Energy. A druid only carries combo points while in cat form, and cat form is
-- the only druid form that uses energy, so the power type is the form test.
local POWER_ENERGY = 3

local LIMITS = {
  size    = { min = 8, max = 28, step = 1 },
  spacing = { min = 0, max = 12, step = 1 },
}

local DEFAULTS = {
  enabled        = true,
  size           = 15,
  spacing        = 2,
  showBackground = true,
}

local cfg
local frame
local slots = {}

-- Filled uses the QtUiPlus accent rather than QtUI's own orange literal, so the
-- bar matches the rest of this UI's chrome. Empty is a dark slot that still
-- reads as a slot against the panel.
local EMPTY_COLOR = { 0.10, 0.10, 0.10, 0.92 }

local function Clamp(name, value)
  local limit = LIMITS[name]
  value = tonumber(value)
  if not limit then return value end
  if not value then return limit.min end
  value = U.Round(value)
  if value < limit.min then value = limit.min end
  if value > limit.max then value = limit.max end
  return value
end

local function Number(name)
  if not cfg then return LIMITS[name] and LIMITS[name].min or 0 end
  return Clamp(name, cfg[name])
end

local function IsEnabled()
  return cfg and cfg.enabled and true or false
end

local function ShowBackground()
  return cfg and cfg.showBackground and true or false
end

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

-- Rogue always; druid only in cat form. Any other class never has points, so
-- the bar stays hidden rather than showing five permanently empty slots.
local function ClassHasPoints()
  local unitClass = U.G("UnitClass")
  if type(unitClass) ~= "function" then return false end
  local ok, _, token = pcall(unitClass, "player")
  if not ok or type(token) ~= "string" then return false end

  if token == "ROGUE" then return true end
  if token ~= "DRUID" then return false end

  local powerType = U.G("UnitPowerType")
  if type(powerType) ~= "function" then
    -- Cannot tell which form: show the bar rather than hide a druid's points.
    return true
  end
  local powerOk, power = pcall(powerType, "player")
  return powerOk and tonumber(power) == POWER_ENERGY
end

local function ComboCount()
  local get = U.G("GetComboPoints")
  if type(get) ~= "function" then return 0 end

  -- Documented as taking no arguments on this client.
  local ok, value = pcall(get)
  if not ok then
    -- Some 1.12 clients want (unit, target); only reached if the no-arg call
    -- actually errored, so it costs nothing on the documented path.
    ok, value = pcall(get, "player", "target")
  end
  if not ok then return 0 end
  return tonumber(value) or 0
end

local function Refresh()
  if not frame then return end

  if not IsEnabled() or not ClassHasPoints() then
    -- Edit mode still needs something to grab, or the bar could never be
    -- placed before the first cat-form pull.
    if U.IsUnlocked() and IsEnabled() then
      frame:Show()
    else
      frame:Hide()
      return
    end
  else
    frame:Show()
  end

  local count = ComboCount()
  local i
  for i = 1, MAX_POINTS do
    local slot = slots[i]
    if slot and slot.fill then
      if i <= count then
        pcall(slot.fill.SetVertexColor, slot.fill, M.Unpack(M.color.accent))
      else
        pcall(slot.fill.SetVertexColor, slot.fill, M.Unpack(EMPTY_COLOR))
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------
local function Layout()
  if not frame then return end

  local size = Number("size")
  local spacing = Number("spacing")

  frame:SetWidth(PAD * 2 + size * MAX_POINTS + spacing * (MAX_POINTS - 1))
  frame:SetHeight(PAD * 2 + size)

  local i
  for i = 1, MAX_POINTS do
    local slot = slots[i]
    if slot then
      local x = PAD + (i - 1) * (size + spacing)
      -- Two-corner anchoring rather than SetWidth/SetHeight: QtUI records that
      -- this client ignores SetWidth on some regions, and a slot sized by its
      -- corners cannot drift from the box the layout computed.
      slot:ClearAllPoints()
      slot:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -PAD)
      slot:SetPoint("BOTTOMRIGHT", frame, "TOPLEFT", x + size, -PAD - size)
    end
  end

  if ShowBackground() then
    U.CreateBackdrop(frame)
  else
    if frame.SetBackdropColor then
      pcall(frame.SetBackdropColor, frame, 0, 0, 0, 0)
    end
    if frame.SetBackdropBorderColor then
      pcall(frame.SetBackdropBorderColor, frame, 0, 0, 0, 0)
    end
  end

  Refresh()
end

local function Build()
  frame = CreateFrame("Frame", "QtUiPlusComboPoints", UIParent)
  frame:SetFrameStrata("MEDIUM")
  U.CreateBackdrop(frame)

  local i
  for i = 1, MAX_POINTS do
    local slot = CreateFrame("Frame", nil, frame)
    slot.fill = slot:CreateTexture(nil, "ARTWORK")
    slot.fill:SetPoint("TOPLEFT", slot, "TOPLEFT", 0, 0)
    slot.fill:SetPoint("BOTTOMRIGHT", slot, "BOTTOMRIGHT", 0, 0)
    pcall(slot.fill.SetTexture, slot.fill, M.texture.plain)
    slots[i] = slot
  end

  U.RegisterMover("combopoints", frame, {
    label = "Combo Points",
    default = { point = "CENTER", relativePoint = "CENTER", x = -140, y = -110 },
  })
end

-- ---------------------------------------------------------------------------
-- Settings API
-- ---------------------------------------------------------------------------
function U.ComboPointLimits(name)
  local limit = LIMITS[name]
  if not limit then return nil end
  return limit.min, limit.max, limit.step
end

function U.GetComboPointSetting(name)
  if not cfg then return nil end
  if name == "enabled" or name == "showBackground" then
    return cfg[name] and true or false
  end
  return Number(name)
end

function U.SetComboPointSetting(name, value)
  if not cfg then return nil end
  if name == "enabled" or name == "showBackground" then
    cfg[name] = value and true or false
  else
    if not LIMITS[name] then return nil end
    cfg[name] = Clamp(name, value)
  end
  Layout()
  return U.GetComboPointSetting(name)
end

local PAGE_WIDTH = 484
local SLIDERS = {
  { key = "size",    text = "Point Size" },
  { key = "spacing", text = "Point Spacing" },
}

local function BuildSettingsPage(parent)
  local widgets, controls = {}, {}

  local header = U.CreateSectionHeader(parent, {
    text = "Combo Points", width = PAGE_WIDTH, y = -4,
  })
  table.insert(widgets, header)

  local enable = U.CreateCheckbox(parent, {
    name = "QtUiPlusComboConfigEnable",
    text = "Enable",
    value = U.GetComboPointSetting("enabled"),
    onChange = function(value) U.SetComboPointSetting("enabled", value) end,
  })
  enable.SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -34)
  table.insert(widgets, enable)

  local background = U.CreateCheckbox(parent, {
    name = "QtUiPlusComboConfigBackground",
    text = "Show background",
    value = U.GetComboPointSetting("showBackground"),
    onChange = function(value) U.SetComboPointSetting("showBackground", value) end,
  })
  background.SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -58)
  table.insert(widgets, background)

  local i
  for i = 1, table.getn(SLIDERS) do
    local spec = SLIDERS[i]
    local minimum, maximum, step = U.ComboPointLimits(spec.key)

    local slider = U.CreateSlider(parent, {
      name = "QtUiPlusComboConfig" .. spec.key,
      text = spec.text,
      width = 200,
      min = minimum, max = maximum, step = step,
      value = U.GetComboPointSetting(spec.key),
      onChange = function(value) U.SetComboPointSetting(spec.key, value) end,
    })
    slider.SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -102 - (i - 1) * 44)

    controls[spec.key] = slider
    table.insert(widgets, slider)
  end

  local hint = U.CreateSettingsLabel(parent, {
    size = M.fontSize.small, color = M.color.textDim,
    inherits = "GameFontNormalSmall", justify = "LEFT",
  })
  if hint then
    local finalSlider = controls[SLIDERS[table.getn(SLIDERS)].key]
    U.AnchorSettingsDescription(hint, finalSlider.box,
                                -math.floor((finalSlider.width - finalSlider.boxWidth) / 2))
    hint:SetText("Shown for rogues, and for druids in cat form. " ..
                 "Drag it in edit mode (|cffffff00/qtp unlock|r).")
    table.insert(widgets, hint)
  end

  local function Refresh_()
    enable.SetValue(U.GetComboPointSetting("enabled"))
    background.SetValue(U.GetComboPointSetting("showBackground"))
    local j
    for j = 1, table.getn(SLIDERS) do
      local key = SLIDERS[j].key
      if controls[key] then controls[key].SetValue(U.GetComboPointSetting(key)) end
    end
  end

  return widgets, Refresh_
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
function CP:OnInit()
  cfg = U.ModuleConfig("combopoints", DEFAULTS)
  if type(U.RegisterSettingsTab) == "function" then
    U.RegisterSettingsTab("combopoints", "Combo Points", BuildSettingsPage, {
      parent = "unitframes",
    })
  end
end

function CP:OnEnable()
  if not cfg then cfg = U.ModuleConfig("combopoints", DEFAULTS) end

  Build()
  Layout()

  U.RegisterEvent("PLAYER_COMBO_POINTS", Refresh)
  U.RegisterEvent("UNIT_COMBO_POINTS", Refresh)
  U.RegisterEvent("PLAYER_TARGET_CHANGED", Refresh)
  U.RegisterEvent("UNIT_DISPLAYPOWER", Refresh)
  U.RegisterEvent("PLAYER_ENTERING_WORLD", Refresh)

  -- The safety net. None of the events above is in this client's observed set,
  -- and combo points are read every frame by the player during a fight, so this
  -- is the fast sweep rather than the 0.5s one the bars use.
  U.RegisterUpdate("combopoints.refresh", 0.2, Refresh)
end

-- Reported by /qtp check.
function U.ComboPointReport()
  return {
    enabled = IsEnabled(),
    classHasPoints = ClassHasPoints(),
    count = ComboCount(),
    created = frame and true or false,
    size = Number("size"),
    spacing = Number("spacing"),
  }
end
