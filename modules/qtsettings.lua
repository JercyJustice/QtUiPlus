-- QtUiPlus :: modules/qtsettings.lua
--
-- Settings page for the features ported from QtUI. They are grouped on their
-- own tab rather than scattered through the existing pages: each one is a
-- self-contained addition rather than an option belonging to an existing
-- surface, and keeping them together makes it obvious what this build adds
-- over the base interface.
--
-- Every toggle writes to the shared QtUI layout table in core/qtcompat.lua,
-- not to a per-module store, because that is the table the ported modules
-- read. The damage meter is the exception: it is gated on the module enable
-- flag, which is what its own OnEnable checks.

local U = QtUiPlus
local M = U.media

local Q = U.RegisterModule("qtsettings")

local ROW_START = -34
local ROW_STEP = 56

-- Builds one checkbox bound to a boolean key on the QtUI layout table, plus
-- its description line. `apply` runs after the value changes, for the toggles
-- that can take effect without a reload.
local function LayoutToggle(parent, widgets, index, options)
  local checkbox = U.CreateCheckbox(parent, {
    name = "QtUiPlusQtSettings" .. options.key,
    text = options.text,
    value = QtP:GetLayout()[options.key] ~= false,
    onChange = function(value)
      QtP:GetLayout()[options.key] = value and true or false
      if options.apply then options.apply(value) end
    end,
  })
  checkbox.SetPoint("TOPLEFT", parent, "TOPLEFT", 0, ROW_START - (index - 1) * ROW_STEP)
  table.insert(widgets, checkbox)

  local hint = U.CreateSettingsLabel(parent, {
    size = M.fontSize.small,
    color = M.color.textDim,
    inherits = "GameFontNormalSmall",
    justify = "LEFT",
  })
  if hint then
    U.AnchorSettingsDescription(hint, checkbox.box)
    hint:SetText(options.description)
    table.insert(widgets, hint)
  end

  return checkbox
end

local function BuildPage(parent)
  local widgets = {}
  local boxes = {}

  local header = U.CreateSectionHeader(parent, {
    text = "Extras",
    width = 700 - 168 - 36,
    y = -4,
  })
  table.insert(widgets, header)

  boxes.autoLoot = LayoutToggle(parent, widgets, 1, {
    key = "autoLoot",
    text = "Auto loot",
    description = "Empties a corpse, container or node as soon as it opens. " ..
                  "Hold Shift while looting to open the window normally.",
  })

  boxes.autoSell = LayoutToggle(parent, widgets, 2, {
    key = "autoSell",
    text = "Auto-sell grey items",
    description = "Sells every poor-quality item when a merchant window " ..
                  "opens, and reports the total.",
  })

  boxes.eqCompare = LayoutToggle(parent, widgets, 3, {
    key = "eqCompare",
    text = "Compare equipped items",
    description = "Shows what you have equipped beside an item tooltip. " ..
                  "Rings, trinkets and one-hand weapons show both slots.",
  })

  boxes.chatTime = LayoutToggle(parent, widgets, 4, {
    key = "chatTime",
    text = "Chat timestamps",
    description = "Prefixes each chat line with the time it arrived.",
  })

  boxes.chatClassNames = LayoutToggle(parent, widgets, 5, {
    key = "chatClassNames",
    text = "Class-coloured names in chat",
    description = "Colours player names by class as they become known, from " ..
                  "your target, your group and the guild roster.",
  })

  boxes.clockLocal = LayoutToggle(parent, widgets, 6, {
    key = "clockLocal",
    text = "Clock shows local time",
    description = "Off shows server time. The clock on the status strip can " ..
                  "also be clicked to switch.",
    apply = function()
      -- The strip repaints on its own 1s poll, so nothing to force here.
    end,
  })

  boxes.dataTextCompact = LayoutToggle(parent, widgets, 7, {
    key = "dataTextCompact",
    text = "Compact status strip",
    description = "Hides the FPS / MS / Durability / Bags captions and keeps " ..
                  "only the values, for a shorter strip.",
  })

  boxes.estimateMobHealth = LayoutToggle(parent, widgets, 8, {
    key = "estimateMobHealth",
    text = "Enemy health from creature table",
    description = "Resolves real hit points for enemies the client reports " ..
                  "only as a percentage. Has no effect when the client " ..
                  "already reports real values.",
  })

  -- The damage meter is gated on the module flag rather than a layout key,
  -- because that is what modules/damagemeter.lua checks in its OnEnable.
  local meter = U.CreateCheckbox(parent, {
    name = "QtUiPlusQtSettingsDamageMeter",
    text = "Damage meter",
    value = U.ModuleConfig("damagemeter", { enabled = true }).enabled,
    onChange = function(value)
      U.ModuleConfig("damagemeter", { enabled = true }).enabled = value
      if value then
        if type(QtP.SetupDamageMeter) == "function" then QtP:SetupDamageMeter() end
      elseif type(QtP.HideDamageMeter) == "function" then
        QtP:HideDamageMeter()
      end
    end,
  })
  meter.SetPoint("TOPLEFT", parent, "TOPLEFT", 0, ROW_START - 8 * ROW_STEP)
  table.insert(widgets, meter)
  boxes.damageMeter = meter

  local meterHint = U.CreateSettingsLabel(parent, {
    size = M.fontSize.small,
    color = M.color.textDim,
    inherits = "GameFontNormalSmall",
    justify = "LEFT",
  })
  if meterHint then
    U.AnchorSettingsDescription(meterHint, meter.box)
    meterHint:SetText("Segmented damage and healing meter. " ..
                      "|cffffff00/qtp meter add|r opens another window.")
    table.insert(widgets, meterHint)
  end

  -- Re-read every value when the page is shown again: a slash command or the
  -- clock's own click handler can change these behind the panel's back.
  local function Refresh()
    local layout = QtP:GetLayout()
    local key, box
    for key, box in pairs(boxes) do
      if key ~= "damageMeter" then
        box.SetValue(layout[key] ~= false)
      end
    end
    boxes.damageMeter.SetValue(U.ModuleConfig("damagemeter", { enabled = true }).enabled)
  end

  return widgets, Refresh
end

-- ---------------------------------------------------------------------------
-- Damage meter page
--
-- The meter reads these straight off the QtUI layout table on its next layout
-- pass, so a change only needs QtP:ApplyDamageMeterLayout() to be visible --
-- there is no separate state to keep in step.
-- ---------------------------------------------------------------------------
local METER_LIMITS = {
  meterWidth      = { min = 140, max = 400, step = 5 },
  meterBars       = { min = 3,   max = 16,  step = 1 },
  meterBarHeight  = { min = 12,  max = 24,  step = 1 },
  meterBarSpacing = { min = 0,   max = 8,   step = 1 },
}

local METER_SLIDERS = {
  { key = "meterWidth",      text = "Window Width" },
  { key = "meterBars",       text = "Visible Bars" },
  { key = "meterBarHeight",  text = "Bar Height" },
  { key = "meterBarSpacing", text = "Bar Spacing" },
}

local function ApplyMeter()
  if type(QtP.ApplyDamageMeterLayout) == "function" then
    QtP:ApplyDamageMeterLayout()
  end
end

local function SetMeter(key, value)
  local layout = QtP:GetLayout()
  local limit = METER_LIMITS[key]
  if limit then
    value = U.Round(tonumber(value) or limit.min)
    if value < limit.min then value = limit.min end
    if value > limit.max then value = limit.max end
  end
  layout[key] = value
  ApplyMeter()
end

local function BuildMeterPage(parent)
  local widgets, controls = {}, {}

  local header = U.CreateSectionHeader(parent, {
    text = "Damage Meter", width = 484, y = -4,
  })
  table.insert(widgets, header)

  local layout = QtP:GetLayout()

  local background = U.CreateCheckbox(parent, {
    name = "QtUiPlusMeterBackground",
    text = "Show window background",
    value = layout.meterShowBackground ~= false,
    onChange = function(value)
      QtP:GetLayout().meterShowBackground = value and true or false
      ApplyMeter()
    end,
  })
  background.SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -34)
  table.insert(widgets, background)

  local askInstance = U.CreateCheckbox(parent, {
    name = "QtUiPlusMeterAskInstance",
    text = "Ask to reset on entering an instance",
    value = layout.meterAskInstance == true,
    onChange = function(value)
      QtP:GetLayout().meterAskInstance = value and true or false
    end,
  })
  askInstance.SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -58)
  table.insert(widgets, askInstance)

  local i
  for i = 1, table.getn(METER_SLIDERS) do
    local spec = METER_SLIDERS[i]
    local limit = METER_LIMITS[spec.key]
    local slider = U.CreateSlider(parent, {
      name = "QtUiPlus" .. spec.key,
      text = spec.text,
      width = 200,
      min = limit.min, max = limit.max, step = limit.step,
      value = QtP:GetLayout()[spec.key],
      onChange = function(value) SetMeter(spec.key, value) end,
    })
    slider.SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -102 - (i - 1) * 44)
    controls[spec.key] = slider
    table.insert(widgets, slider)
  end

  local function Refresh()
    local current = QtP:GetLayout()
    background.SetValue(current.meterShowBackground ~= false)
    askInstance.SetValue(current.meterAskInstance == true)
    local j
    for j = 1, table.getn(METER_SLIDERS) do
      local key = METER_SLIDERS[j].key
      if controls[key] then controls[key].SetValue(current[key]) end
    end
  end

  return widgets, Refresh
end

function Q:OnInit()
  U.RegisterSettingsTab("qtextras", "Extras", BuildPage)
  U.RegisterSettingsTab("damagemeter", "Damage Meter", BuildMeterPage)
end
