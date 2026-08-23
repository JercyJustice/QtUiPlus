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

-- ---------------------------------------------------------------------------
-- Cast without leaving your form (QtUI's unshiftToCast).
--
-- This is a client setting, not something QtUiPlus can implement: the client
-- decides whether casting a non-form spell cancels the current shapeshift.
-- "autoUnshift" is the Vanilla 1.12 CVar name and is NOT verified on this
-- client -- emberveil.org/wiki/lua/globals/Settings documents SetCVar/GetCVar
-- but the wiki does not enumerate CVar names. SetCVar on a name this client
-- does not know is harmless, so the toggle is offered; if it turns out to do
-- nothing in game, this comment is the place to start.
-- ---------------------------------------------------------------------------
local UNSHIFT_CVAR = "autoUnshift"

local function GetUnshift()
  local get = U.G("GetCVar")
  if type(get) ~= "function" then return true end
  local ok, value = pcall(get, UNSHIFT_CVAR)
  if not ok or value == nil then return true end
  return value ~= "0" and value ~= 0
end

local function SetUnshift(enabled)
  local set = U.G("SetCVar")
  if type(set) ~= "function" then return end
  local value = "0"
  if enabled then value = "1" end
  pcall(set, UNSHIFT_CVAR, value)
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
    apply = function()
      if type(U.ApplyStatusOverlay) == "function" then U.ApplyStatusOverlay() end
    end,
  })

  local fontSlider = U.CreateSlider(parent, {
    name = "QtUiPlusQtSettingsStatusFont",
    text = "Status overlay font",
    width = 200,
    min = 8, max = 18, step = 1,
    value = type(U.GetStatusOverlayFontSize) == "function"
            and U.GetStatusOverlayFontSize() or 11,
    onChange = function(value)
      if type(U.SetStatusOverlayFontSize) == "function" then
        U.SetStatusOverlayFontSize(value)
      end
    end,
  })
  fontSlider.SetPoint("TOPLEFT", parent, "TOPLEFT", 258,
                      ROW_START - 6 * ROW_STEP)
  table.insert(widgets, fontSlider)

  -- Not a layout key: this one reads and writes a client CVar, so it gets its
  -- own checkbox rather than going through LayoutToggle.
  local unshift = U.CreateCheckbox(parent, {
    name = "QtUiPlusQtSettingsUnshift",
    text = "Cast without leaving your form",
    value = GetUnshift(),
    onChange = function(value) SetUnshift(value) end,
  })
  unshift.SetPoint("TOPLEFT", parent, "TOPLEFT", 0, ROW_START - 8 * ROW_STEP)
  table.insert(widgets, unshift)

  local unshiftHint = U.CreateSettingsLabel(parent, {
    size = M.fontSize.small, color = M.color.textDim,
    inherits = "GameFontNormalSmall", justify = "LEFT",
  })
  if unshiftHint then
    U.AnchorSettingsDescription(unshiftHint, unshift.box)
    unshiftHint:SetText("Druids and shamans: cast a spell without cancelling " ..
                        "your current form first. This is a client setting.")
    table.insert(widgets, unshiftHint)
  end

  boxes.vendorPrices = LayoutToggle(parent, widgets, 9, {
    key = "vendorPrices",
    text = "Vendor prices on tooltips",
    description = "Adds the vendor sell price to bag, bank, loot and " ..
                  "equipped item tooltips, multiplied by the stack size.",
  })

  boxes.estimateMobHealth = LayoutToggle(parent, widgets, 10, {
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
  meter.SetPoint("TOPLEFT", parent, "TOPLEFT", 0, ROW_START - 11 * ROW_STEP)
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
    unshift.SetValue(GetUnshift())
    if type(U.GetStatusOverlayFontSize) == "function" then
      fontSlider.SetValue(U.GetStatusOverlayFontSize())
    end
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

  -- Window add/close. QtUI put these in its own settings window, which was not
  -- ported, so until now /qtp meter add was the only way to open a second
  -- window and there was no way to discover it.
  local countLabel = U.CreateSettingsLabel(parent, {
    size = M.fontSize.normal, color = M.color.text,
    inherits = "GameFontNormal", justify = "LEFT",
  })

  local UpdateCount
  UpdateCount = function()
    if not countLabel then return end
    local n = 0
    if type(QtP.MeterWindowCount) == "function" then
      n = tonumber(QtP:MeterWindowCount()) or 0
    end
    countLabel:SetText("Open windows: |cffffff00" .. n .. "|r")
  end

  local addButton = U.CreateButton(parent, {
    name = "QtUiPlusMeterAdd",
    text = "Add window",
    width = 140, height = 26,
    onClick = function()
      if type(QtP.AddDamageMeterWindow) ~= "function" then
        U.Print("damage meter is not loaded")
        return
      end
      -- No view argument: the meter then picks the next unused mode, so a new
      -- window shows something different from the ones already open rather
      -- than a duplicate of window 1.
      local frame = QtP:AddDamageMeterWindow()
      if not frame then
        U.Print("cannot add another meter window (limit reached, or the " ..
                "meter is disabled)")
      end
      UpdateCount()
    end,
  })
  addButton:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -290)
  table.insert(widgets, addButton)

  local closeButton = U.CreateButton(parent, {
    name = "QtUiPlusMeterClose",
    text = "Close window",
    width = 140, height = 26,
    onClick = function()
      if type(QtP.CloseLastDamageMeterWindow) == "function" then
        QtP:CloseLastDamageMeterWindow()
      end
      UpdateCount()
    end,
  })
  closeButton:SetPoint("TOPLEFT", parent, "TOPLEFT", 150, -290)
  table.insert(widgets, closeButton)

  if countLabel then
    countLabel:SetPoint("TOPLEFT", parent, "TOPLEFT", 300, -297)
    table.insert(widgets, countLabel)
  end

  local function Refresh()
    UpdateCount()
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
