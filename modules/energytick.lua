-- QtUiPlus :: modules/energytick.lua
--
-- A moving marker across the player power bar showing where the next energy
-- (or mana) regeneration tick lands. Ported from QtUI UnitFrames.lua. Rogues
-- and cat-form druids plan around the two-second energy tick, and casters
-- around the five-second mana rule; this makes both visible.
--
-- The tick is not something the client reports. It is inferred: power going UP
-- means a tick just landed, so the marker restarts from the left and sweeps to
-- the right edge over the expected interval. Two intervals are tracked --
-- 2s for energy, 5s for the mana "five second rule" -- and spending mana
-- restarts the 5s window, which is what the negative-diff branch below is for.
--
-- Two Emberveil quirks decide the implementation, both recorded by QtUI:
--
--  * Texture SetAlpha and the alpha component of SetVertexColor are IGNORED on
--    this client. Backdrop colour is the same path bar-background opacity uses
--    and does work, so the marker is a backdrop-filled frame rather than a
--    texture, and its opacity is set through SetBackdropColor.
--
--  * SetWidth(1) is ignored and WHITE8X8 stays 8x8, so a one-pixel line cannot
--    be made by sizing. The marker is stretched with two corner anchors
--    instead, the same technique the edit-mode grid uses.

local U = QtUiPlus
local M = U.media

local ET = U.RegisterModule("energytick")

-- Power type ids: 0 mana, 3 energy.
local POWER_MANA = 0
local POWER_ENERGY = 3

-- Regeneration intervals, in seconds.
local ENERGY_INTERVAL = 2
local MANA_INTERVAL = 5

local LIMITS = {
  width = { min = 1,  max = 8,   step = 1 },
  alpha = { min = 10, max = 100, step = 5 },   -- stored as a percentage
}

local DEFAULTS = {
  enabled = true,
  width   = 1,
  alpha   = 95,
}

local cfg
local tick        -- the frame overlaying the power bar
local line        -- the moving marker inside it

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

-- Stored as a percentage so core/config.lua only ever persists whole numbers.
local function AlphaFraction()
  return Number("alpha") / 100
end

-- ---------------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------------
local function Paint()
  if not line or not line.SetBackdropColor then return end
  local alpha = 0
  if IsEnabled() then alpha = AlphaFraction() end
  -- M.Unpack's second argument is only a FALLBACK alpha, used when the colour
  -- table has none -- and M.color.accent has one, so it would be ignored. Take
  -- the three channels and pass the configured alpha explicitly.
  local r, g, b = M.Unpack(M.color.accent)
  pcall(line.SetBackdropColor, line, r, g, b, alpha)
end

-- `pos` is an offset in pixels from the bar's left edge.
local function Place(pos)
  if not tick or not line then return end
  pos = tonumber(pos) or 0
  local width = Number("width")
  local px = math.floor(pos + 0.5)

  -- Re-anchoring every frame is wasted work; the marker only moves a pixel at
  -- a time and this runs on every OnUpdate tick.
  if tick.lastPlace == px and tick.lastWidth == width then return end
  tick.lastPlace = px
  tick.lastWidth = width

  line:ClearAllPoints()
  line:SetPoint("TOPLEFT", tick, "TOPLEFT", px, 0)
  line:SetPoint("BOTTOMRIGHT", tick, "BOTTOMLEFT", px + width, 0)
end

-- ---------------------------------------------------------------------------
-- Tracking
-- ---------------------------------------------------------------------------
local function CurrentPower()
  local unitMana = U.G("UnitMana")
  if type(unitMana) ~= "function" then return nil end
  local ok, value = pcall(unitMana, "player")
  if not ok then return nil end
  return tonumber(value)
end

-- Returns "ENERGY", "MANA", or nil when this power type has no tick worth
-- drawing (rage, focus).
local function PowerMode()
  local powerType = U.G("UnitPowerType")
  if type(powerType) ~= "function" then return nil end
  local ok, value = pcall(powerType, "player")
  if not ok then return nil end
  value = tonumber(value)
  if value == POWER_ENERGY then return "ENERGY" end
  if value == POWER_MANA then return "MANA" end
  return nil
end

local function RefreshMode()
  if not tick then return end
  tick.mode = PowerMode()
  if not tick.mode or not IsEnabled() then
    tick:Hide()
  else
    tick:Show()
  end
  Paint()
end

-- Power changed: decide whether that was a regeneration tick, and if so restart
-- the sweep with the right interval.
local function OnPowerChanged()
  if not tick or not tick.mode then return end

  local current = CurrentPower()
  if not current then return end

  local diff = 0
  if tick.lastPower then diff = current - tick.lastPower end
  tick.lastPower = current

  if tick.mode == "MANA" then
    if diff < 0 then
      -- Spending mana restarts the five second rule.
      tick.pending = MANA_INTERVAL
    elseif diff > 0 then
      -- Distinguish a regen tick from a potion/Evocation: a tick is roughly
      -- the same size every time, so anything much larger than the last known
      -- tick is treated as an out-of-band gain and restarts the short window.
      -- `badtick` records the observed tick size to compare against.
      if tick.window ~= MANA_INTERVAL
         and diff > ((tick.badtick and tick.badtick * 1.2) or 5) then
        tick.pending = ENERGY_INTERVAL
      else
        tick.badtick = diff
      end
    end
  elseif tick.mode == "ENERGY" and diff > 0 then
    tick.pending = ENERGY_INTERVAL
  end
end

-- Runs on the shared driver. Reads GetTime directly: core/init.lua measured
-- that this client passes no arguments to OnUpdate and that GetTime is the
-- only reliable clock here.
local function Advance()
  if not tick or not tick.mode or not IsEnabled() then return end

  local now = U.G("GetTime")
  if type(now) ~= "function" then return end
  local ok, time = pcall(now)
  if not ok then return end
  time = tonumber(time)
  if not time then return end

  if tick.pending then
    tick.start = time
    tick.window = tick.pending
    tick.pending = nil
  end
  if not tick.start or not tick.window or tick.window <= 0 then return end

  local elapsed = time - tick.start
  -- The expected tick did not arrive (or the event was missed): roll straight
  -- into the next energy-length window rather than parking at the right edge.
  if elapsed > tick.window then
    tick.start = time
    tick.window = ENERGY_INTERVAL
    elapsed = 0
  end

  local width = tick:GetWidth() or 0
  if width < 1 then return end
  -- Remembered so a settings change can redraw at the current position rather
  -- than snapping the marker back to the left edge.
  tick.lastPos = width * (elapsed / tick.window)
  Place(tick.lastPos)
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------
local function Build()
  local player = U.GetUnitFrame("player")
  local bar = player and player.power
  if not bar then return false end

  -- Parent is the bar's box, not the bar. The mana fill is an ARTWORK texture
  -- on the bar; on this client a child of that bar (even at a higher frame
  -- level) still paints under the fill -- the same stacking that made
  -- unitframes.lua put bar text on a sibling layer at box+10. The tick sits
  -- between them (box+5) so the marker is over the fill and under the numbers.
  local host = bar
  local parentOk, parent = pcall(bar.GetParent, bar)
  if parentOk and parent then host = parent end

  tick = CreateFrame("Frame", "QtUiPlusEnergyTick", host)
  tick:SetAllPoints(bar)
  local levelOk, level = pcall(host.GetFrameLevel, host)
  if levelOk and tonumber(level) then
    pcall(tick.SetFrameLevel, tick, level + 5)
  end
  if tick.EnableMouse then tick:EnableMouse(false) end

  line = CreateFrame("Frame", nil, tick)
  if line.EnableMouse then line:EnableMouse(false) end
  if line.SetBackdrop then
    pcall(line.SetBackdrop, line, {
      bgFile = M.texture.plain,
      insets = { left = 0, right = 0, top = 0, bottom = 0 },
    })
  end

  Paint()
  Place(0)
  return true
end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------
function U.EnergyTickLimits(name)
  local limit = LIMITS[name]
  if not limit then return nil end
  return limit.min, limit.max, limit.step
end

function U.GetEnergyTickSetting(name)
  if not cfg then return nil end
  if name == "enabled" then return cfg.enabled and true or false end
  return Number(name)
end

function U.SetEnergyTickSetting(name, value)
  if not cfg then return nil end
  if name == "enabled" then
    cfg.enabled = value and true or false
  else
    if not LIMITS[name] then return nil end
    cfg[name] = Clamp(name, value)
  end
  -- Force a re-anchor: Place() short-circuits when the position is unchanged,
  -- and a width change alone would otherwise not redraw.
  if tick then tick.lastPlace = nil end
  RefreshMode()
  Place(tick and tick.lastPos or 0)
  return U.GetEnergyTickSetting(name)
end

local SLIDERS = {
  { key = "width", text = "Marker Width" },
  { key = "alpha", text = "Marker Opacity (%)" },
}

local function BuildSettingsPage(parent)
  local widgets, controls = {}, {}

  local header = U.CreateSectionHeader(parent, {
    text = "Energy Tick", width = 484, y = -4,
  })
  table.insert(widgets, header)

  local enable = U.CreateCheckbox(parent, {
    name = "QtUiPlusEnergyTickEnable",
    text = "Enable",
    value = U.GetEnergyTickSetting("enabled"),
    onChange = function(value) U.SetEnergyTickSetting("enabled", value) end,
  })
  enable.SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -34)
  table.insert(widgets, enable)

  local i
  for i = 1, table.getn(SLIDERS) do
    local spec = SLIDERS[i]
    local minimum, maximum, step = U.EnergyTickLimits(spec.key)
    local slider = U.CreateSlider(parent, {
      name = "QtUiPlusEnergyTick" .. spec.key,
      text = spec.text,
      width = 200,
      min = minimum, max = maximum, step = step,
      value = U.GetEnergyTickSetting(spec.key),
      onChange = function(value) U.SetEnergyTickSetting(spec.key, value) end,
    })
    slider.SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -78 - (i - 1) * 44)
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
    hint:SetText("Sweeps across the player power bar between regeneration " ..
                 "ticks. Shown for energy and mana users only.")
    table.insert(widgets, hint)
  end

  local function Refresh()
    enable.SetValue(U.GetEnergyTickSetting("enabled"))
    local j
    for j = 1, table.getn(SLIDERS) do
      local key = SLIDERS[j].key
      if controls[key] then controls[key].SetValue(U.GetEnergyTickSetting(key)) end
    end
  end

  return widgets, Refresh
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
function ET:OnInit()
  cfg = U.ModuleConfig("energytick", DEFAULTS)
  if type(U.RegisterSettingsTab) == "function" then
    U.RegisterSettingsTab("energytick", "Energy Tick", BuildSettingsPage)
  end
end

function ET:OnEnable()
  if not cfg then cfg = U.ModuleConfig("energytick", DEFAULTS) end

  -- modules/unitframes.lua is listed ahead of this file in the .toc, so the
  -- player frame exists by now. Bail out quietly rather than erroring if the
  -- player frame has no power bar (it always does, but this module must not be
  -- the thing that breaks login if that ever changes).
  if not Build() then return end

  tick.lastPower = CurrentPower()
  RefreshMode()

  U.RegisterEvent("PLAYER_ENTERING_WORLD", function()
    tick.lastPower = CurrentPower()
    RefreshMode()
  end)
  U.RegisterEvent("UNIT_DISPLAYPOWER", RefreshMode)
  U.RegisterEvent("UNIT_ENERGY", function(event, unit)
    if not unit or unit == "player" then OnPowerChanged() end
  end)
  U.RegisterEvent("UNIT_MANA", function(event, unit)
    if not unit or unit == "player" then OnPowerChanged() end
  end)

  -- Every tick of the shared driver: this is an animation, not a state read.
  U.RegisterUpdate("energytick.advance", 0, Advance)
  -- The power-type events are not in this client's observed set, so the mode
  -- is also re-checked slowly. Cheap: two API calls a second.
  U.RegisterUpdate("energytick.mode", 1, RefreshMode)
end

-- Reported by /qtp check.
function U.EnergyTickReport()
  return {
    enabled = IsEnabled(),
    created = tick and true or false,
    mode = tick and tick.mode or "none",
    width = Number("width"),
    alpha = Number("alpha"),
  }
end
