-- QtUiPlus :: modules/xpbar.lua
--
-- Two thin movable bars: player experience (with a rested overlay) and
-- watched-faction reputation. The reputation bar can be hidden from the
-- General settings page; the XP bar is required scope and always shown.
--
-- Evidence gap: query_compat.py has no runtime record for UnitXP, UnitXPMax,
-- GetXPExhaustion, GetFactionInfo, PLAYER_XP_UPDATE, UPDATE_EXHAUSTION,
-- UPDATE_FACTION or PLAYER_LEVEL_UP on this client. Per the evidence-gap
-- fallback this module defaults to UnrealPfUI's demonstrated recipe
-- (modules/xpbar.lua: UnitXP/UnitXPMax/GetXPExhaustion, a GetFactionInfo scan
-- for the watched faction, and that same event list). This is WORKING_SOURCE
-- evidence from a working implementation on this same client, not runtime
-- verification.

local U = QtUiPlus
local M = U.media

local XP = U.RegisterModule("xpbar")

-- Shipped geometry; the settings below override it. Kept as the defaults so
-- there is one source of truth for "how big is this normally".
local WIDTH = 300
local HEIGHT = 7
local GAP = 3

local LIMITS = {
  width    = { min = 80, max = 800, step = 2 },
  height   = { min = 4,  max = 32,  step = 1 },
  fontSize = { min = 8,  max = 18,  step = 1 },
}

local DEFAULTS = {
  repEnabled = true,
  width      = WIDTH,
  height     = HEIGHT,
  showText   = false,
  fontSize   = 10,
}

local COLOR_XP = { 0.55, 0.32, 0.87, 1.00 }
local COLOR_XP_RESTED = { 0.30, 0.20, 0.55, 1.00 }
local COLOR_REP_FALLBACK = { 0.50, 0.50, 0.50, 1.00 }
local COLOR_REP_EMPTY = { 0.35, 0.35, 0.35, 1.00 }

local config
local xpAnchor, xpBar, xpRestedBar
local xpLabelLayer, xpLabel
local repAnchor, repBar
local repLabelLayer, repLabel

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------
local function EnsureConfig()
  if not config then config = U.ModuleConfig("xpbar", DEFAULTS) end
  return config
end

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
  EnsureConfig()
  return Clamp(name, config[name])
end

local function BarWidth() return Number("width") end
local function BarHeight() return Number("height") end
local function ShowText() return config and config.showText and true or false end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------
local function BuildBar(name, fillColor)
  local anchor = CreateFrame("Frame", name, UIParent)
  anchor:SetWidth(BarWidth())
  anchor:SetHeight(BarHeight())
  U.CreateBackdrop(anchor, { background = M.color.healthBg })

  local bar = U.CreateStatusBar(anchor, {
    width = BarWidth() - 2 * U.BorderSize(),
    height = BarHeight() - 2 * U.BorderSize(),
    color = fillColor,
    background = { 0, 0, 0, 0 },
  })
  bar:ClearAllPoints()
  bar:SetPoint("TOPLEFT", anchor, "TOPLEFT", U.BorderSize(), -U.BorderSize())
  bar:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", -U.BorderSize(), U.BorderSize())

  return anchor, bar
end

-- ---------------------------------------------------------------------------
-- Rest XP tooltip (WORKING_SOURCE fallback: UnrealPfUI modules/xpbar.lua
-- OnEnter, since query_compat.py has no runtime record for GetXPExhaustion
-- or IsResting on this client).
-- ---------------------------------------------------------------------------
local function XPTooltipShow()
  local unitXP, unitXPMax = U.G("UnitXP"), U.G("UnitXPMax")
  if type(unitXP) ~= "function" or type(unitXPMax) ~= "function" then return end

  local xpOk, xp = pcall(unitXP, "player")
  local maxOk, xpmax = pcall(unitXPMax, "player")
  xp = (xpOk and tonumber(xp)) or 0
  xpmax = (maxOk and tonumber(xpmax)) or 0
  if xpmax <= 0 then return end

  local rested = 0
  local exhaustion = U.G("GetXPExhaustion")
  if type(exhaustion) == "function" then
    local restOk, value = pcall(exhaustion)
    if restOk then rested = tonumber(value) or 0 end
  end

  local remaining = xpmax - xp

  GameTooltip:SetOwner(xpAnchor, "ANCHOR_CURSOR")
  GameTooltip:ClearLines()
  GameTooltip:AddLine("Experience")
  GameTooltip:AddDoubleLine("XP", xp .. " / " .. xpmax .. " (" .. math.floor(xp / xpmax * 100 + 0.5) .. "%)", 1, 1, 1, 1, 1, 1)
  GameTooltip:AddDoubleLine("Remaining", remaining .. " (" .. math.floor(remaining / xpmax * 100 + 0.5) .. "%)", 1, 1, 1, 1, 1, 1)

  local isResting = U.G("IsResting")
  if type(isResting) == "function" then
    local restingOk, resting = pcall(isResting)
    if restingOk and resting and resting ~= 0 then
      GameTooltip:AddDoubleLine("Status", "Resting", 1, 1, 1, 0.3, 0.7, 1)
    end
  end

  if rested > 0 then
    GameTooltip:AddDoubleLine("Rested", "+" .. rested .. " (" .. math.floor(rested / xpmax * 100 + 0.5) .. "%)", 1, 1, 1, 0.3, 0.3, 1)
  end

  GameTooltip:Show()
end

local function XPTooltipHide()
  GameTooltip:Hide()
end

local function Build()
  xpAnchor, xpBar = BuildBar("QtUiPlusXPBarAnchor", COLOR_XP)

  -- The rested portion sits behind the current-xp fill on its own bar, at a
  -- lower frame level, so it reads as an extension rather than covering it.
  xpRestedBar = U.CreateStatusBar(xpAnchor, {
    width = BarWidth() - 2 * U.BorderSize(),
    height = BarHeight() - 2 * U.BorderSize(),
    color = COLOR_XP_RESTED,
    background = { 0, 0, 0, 0 },
  })
  xpRestedBar:ClearAllPoints()
  xpRestedBar:SetPoint("TOPLEFT", xpAnchor, "TOPLEFT", U.BorderSize(), -U.BorderSize())
  xpRestedBar:SetPoint("BOTTOMRIGHT", xpAnchor, "BOTTOMRIGHT", -U.BorderSize(), U.BorderSize())
  local restedOk, restedLevel = pcall(xpRestedBar.GetFrameLevel, xpRestedBar)
  local barOk, barLevel = pcall(xpBar.GetFrameLevel, xpBar)
  if restedOk and barOk and tonumber(barLevel) then
    pcall(xpRestedBar.SetFrameLevel, xpRestedBar, barLevel)
    pcall(xpBar.SetFrameLevel, xpBar, barLevel + 1)
  end

  U.RegisterMover("xpbar.xp", xpAnchor, {
    label = "Experience Bar",
    default = { point = "BOTTOM", relativePoint = "BOTTOM", x = 0, y = 66 },
  })

  -- The readout sits on its own child layer above both fills: the fills are
  -- sibling frames whose width changes on every refresh, and a label on the
  -- same layer can end up behind them.
  xpLabelLayer = CreateFrame("Frame", nil, xpAnchor)
  xpLabelLayer:SetAllPoints(xpAnchor)
  local layerOk, layerLevel = pcall(xpBar.GetFrameLevel, xpBar)
  if layerOk and tonumber(layerLevel) then
    pcall(xpLabelLayer.SetFrameLevel, xpLabelLayer, layerLevel + 5)
  end
  xpLabel = U.CreateLabel(xpLabelLayer, {
    size = M.fontSize.small,
    color = M.color.text,
    inherits = "GameFontNormalSmall",
  })
  if xpLabel then xpLabel:SetPoint("CENTER", xpLabelLayer, "CENTER", 0, 0) end

  xpAnchor:EnableMouse(true)
  xpAnchor:SetScript("OnEnter", XPTooltipShow)
  xpAnchor:SetScript("OnLeave", XPTooltipHide)

  repAnchor, repBar = BuildBar("QtUiPlusReputationBarAnchor", COLOR_REP_FALLBACK)

  U.RegisterMover("xpbar.reputation", repAnchor, {
    label = "Reputation Bar",
    default = { point = "BOTTOM", relativePoint = "BOTTOM", x = 0, y = 66 - HEIGHT - GAP },
    -- The default offset uses the shipped HEIGHT rather than the configured
    -- one on purpose: a stored position must not move because a slider did.
    -- A disabled bar keeps its stored position but offers no drag handle in
    -- edit mode; see core/mover.lua / modules/microbar.lua.
    visible = function() return config and config.repEnabled end,
  })

  -- Same layered treatment as the experience readout above, and for the same
  -- reason: the fill is a sibling frame whose width changes on every refresh,
  -- so a label on that layer can end up behind it.
  repLabelLayer = CreateFrame("Frame", nil, repAnchor)
  repLabelLayer:SetAllPoints(repAnchor)
  local repLayerOk, repLayerLevel = pcall(repBar.GetFrameLevel, repBar)
  if repLayerOk and tonumber(repLayerLevel) then
    pcall(repLabelLayer.SetFrameLevel, repLabelLayer, repLayerLevel + 5)
  end
  repLabel = U.CreateLabel(repLabelLayer, {
    size = M.fontSize.small,
    color = M.color.text,
    inherits = "GameFontNormalSmall",
  })
  if repLabel then repLabel:SetPoint("CENTER", repLabelLayer, "CENTER", 0, 0) end
end

-- Re-applies the configured geometry to bars that already exist. The fill is
-- derived from the bar's own GetWidth (core/style.lua) with no public
-- recompute call, so the current value is written back after each resize --
-- otherwise a resized bar keeps drawing its previous fill width.
local function ResizeBar(anchor, bar)
  if not anchor then return end
  local border = U.BorderSize()
  anchor:SetWidth(BarWidth())
  anchor:SetHeight(BarHeight())
  if not bar then return end
  bar:SetWidth(BarWidth() - 2 * border)
  bar:SetHeight(BarHeight() - 2 * border)
  if bar.GetValue and bar.SetValue then
    local ok, value = pcall(bar.GetValue, bar)
    if ok then pcall(bar.SetValue, bar, value) end
  end
end

local function ApplyGeometry()
  ResizeBar(xpAnchor, xpBar)
  if xpRestedBar then
    local border = U.BorderSize()
    xpRestedBar:SetWidth(BarWidth() - 2 * border)
    xpRestedBar:SetHeight(BarHeight() - 2 * border)
    if xpRestedBar.GetValue and xpRestedBar.SetValue then
      local ok, value = pcall(xpRestedBar.GetValue, xpRestedBar)
      if ok then pcall(xpRestedBar.SetValue, xpRestedBar, value) end
    end
  end
  ResizeBar(repAnchor, repBar)

  if xpLabel then
    U.SetFont(xpLabel, Number("fontSize"))
    if ShowText() then xpLabel:Show() else xpLabel:Hide() end
  end

  if repLabel then
    U.SetFont(repLabel, Number("fontSize"))
    -- Shown from RefreshReputation rather than here: with no watched faction
    -- there is nothing to write, and an empty label on a bar that is drawn
    -- empty anyway would just be a gap.
    if not ShowText() then repLabel:Hide() end
  end
end

-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------
local function SetBar(bar, value, maximum)
  if not bar then return end
  maximum = tonumber(maximum) or 0
  value = tonumber(value) or 0
  if maximum <= 0 then maximum, value = 1, 0 end
  pcall(bar.SetMinMaxValues, bar, 0, maximum)
  pcall(bar.SetValue, bar, value)
end

local function RefreshXP()
  if not xpAnchor then return end

  local unitXP = U.G("UnitXP")
  local unitXPMax = U.G("UnitXPMax")
  if type(unitXP) ~= "function" or type(unitXPMax) ~= "function" then
    xpAnchor:Hide()
    return
  end

  local xpOk, xp = pcall(unitXP, "player")
  local maxOk, xpmax = pcall(unitXPMax, "player")
  xp = (xpOk and tonumber(xp)) or 0
  xpmax = (maxOk and tonumber(xpmax)) or 0

  -- UnitXPMax reports 0 once no further experience is tracked (max level).
  if xpmax <= 0 then
    xpAnchor:Hide()
    return
  end
  xpAnchor:Show()

  SetBar(xpBar, xp, xpmax)

  local exhaustion = U.G("GetXPExhaustion")
  local rested = 0
  if type(exhaustion) == "function" then
    local restOk, value = pcall(exhaustion)
    if restOk then rested = tonumber(value) or 0 end
  end

  if rested > 0 then
    SetBar(xpRestedBar, math.min(xp + rested, xpmax), xpmax)
    xpRestedBar:Show()
  else
    xpRestedBar:Hide()
  end

  if xpLabel then
    if ShowText() then
      local percent = 0
      if xpmax > 0 then percent = math.floor(xp / xpmax * 100 + 0.5) end
      local text = xp .. " / " .. xpmax .. "  (" .. percent .. "%)"
      if rested > 0 then text = text .. "  |cff8878c8+" .. rested .. "|r" end
      xpLabel:SetText(text)
      xpLabel:Show()
    else
      xpLabel:Hide()
    end
  end
end

-- Standing name for the watched faction. FACTION_STANDING_LABEL1..8 are the
-- client's own localised strings; a client that does not define them costs the
-- word, not the readout.
local function StandingLabel(standingID)
  local id = tonumber(standingID)
  if not id or id < 1 or id > 8 then return nil end
  local label = U.G("FACTION_STANDING_LABEL" .. id)
  if type(label) == "string" and label ~= "" then return label end
  return nil
end

local function SetReputationText(name, standingID, value, maximum)
  if not repLabel then return end

  if not ShowText() or not name then
    repLabel:Hide()
    return
  end

  local percent = 0
  if maximum > 0 then percent = math.floor(value / maximum * 100 + 0.5) end

  local text = name
  local standing = StandingLabel(standingID)
  if standing then text = text .. ": " .. standing end
  text = text .. "  " .. value .. " / " .. maximum .. "  (" .. percent .. "%)"

  repLabel:SetText(text)
  repLabel:Show()
end

local function RefreshReputation()
  if not repAnchor then return end

  if not config or not config.repEnabled then
    repAnchor:Hide()
    return
  end
  repAnchor:Show()

  local getFactionInfo = U.G("GetFactionInfo")
  if type(getFactionInfo) ~= "function" then
    SetBar(repBar, 0, 1)
    U.SetStatusBarColor(repBar, M.Unpack(COLOR_REP_EMPTY))
    SetReputationText(nil)
    return
  end

  local i, name, standingID, barMin, barMax, barValue, isWatched
  local found = false
  for i = 1, 99 do
    local ok, n, _, sID, bMin, bMax, bValue, _, _, _, _, watched =
      pcall(getFactionInfo, i)
    if not ok or n == nil then break end
    name, standingID, barMin, barMax, barValue, isWatched = n, sID, bMin, bMax, bValue, watched
    if isWatched then
      found = true
      break
    end
  end

  if not found then
    SetBar(repBar, 0, 1)
    U.SetStatusBarColor(repBar, M.Unpack(COLOR_REP_EMPTY))
    -- No watched faction: the bar is drawn empty, so a label would be a
    -- caption for nothing.
    SetReputationText(nil)
    return
  end

  local maximum = (tonumber(barMax) or 1) - (tonumber(barMin) or 0)
  local value = (tonumber(barValue) or 0) - (tonumber(barMin) or 0)
  SetBar(repBar, value, maximum)
  SetReputationText(name, standingID, value, maximum)

  local colors = U.G("FACTION_BAR_COLORS")
  local color = type(colors) == "table" and colors[standingID]
  if color and color.r then
    U.SetStatusBarColor(repBar, (color.r + 0.3), (color.g + 0.3), (color.b + 0.3), 1)
  else
    U.SetStatusBarColor(repBar, M.Unpack(COLOR_REP_FALLBACK))
  end
end

-- Public so modules/settings.lua's General page can flip the checkbox without
-- reaching into this module's internals.
function U.ApplyXPBar()
  ApplyGeometry()
  RefreshXP()
  RefreshReputation()
end

-- ---------------------------------------------------------------------------
-- Registration
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------
function U.XPBarLimits(name)
  local limit = LIMITS[name]
  if not limit then return nil end
  return limit.min, limit.max, limit.step
end

function U.GetXPBarSetting(name)
  EnsureConfig()
  if name == "repEnabled" or name == "showText" then
    return config[name] and true or false
  end
  return Number(name)
end

function U.SetXPBarSetting(name, value)
  EnsureConfig()
  if name == "repEnabled" or name == "showText" then
    config[name] = value and true or false
  else
    if not LIMITS[name] then return nil end
    config[name] = Clamp(name, value)
  end
  U.ApplyXPBar()
  return U.GetXPBarSetting(name)
end

local XP_SLIDERS = {
  { key = "width",    text = "Bar Width" },
  { key = "height",   text = "Bar Height" },
  { key = "fontSize", text = "Text Size" },
}

local function BuildSettingsPage(parent)
  local widgets, controls = {}, {}

  local header = U.CreateSectionHeader(parent, {
    text = "Experience Bar", width = 484, y = -4,
  })
  table.insert(widgets, header)

  local text = U.CreateCheckbox(parent, {
    name = "QtUiPlusXPBarText",
    text = "Show text on the bars",
    value = U.GetXPBarSetting("showText"),
    onChange = function(value) U.SetXPBarSetting("showText", value) end,
  })
  text.SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -34)
  table.insert(widgets, text)

  local rep = U.CreateCheckbox(parent, {
    name = "QtUiPlusXPBarRep",
    text = "Show reputation bar",
    value = U.GetXPBarSetting("repEnabled"),
    onChange = function(value) U.SetXPBarSetting("repEnabled", value) end,
  })
  rep.SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -58)
  table.insert(widgets, rep)

  local i
  for i = 1, table.getn(XP_SLIDERS) do
    local spec = XP_SLIDERS[i]
    local minimum, maximum, step = U.XPBarLimits(spec.key)
    local slider = U.CreateSlider(parent, {
      name = "QtUiPlusXPBar" .. spec.key,
      text = spec.text,
      width = 200,
      min = minimum, max = maximum, step = step,
      value = U.GetXPBarSetting(spec.key),
      onChange = function(value) U.SetXPBarSetting(spec.key, value) end,
    })
    slider.SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -102 - (i - 1) * 44)
    controls[spec.key] = slider
    table.insert(widgets, slider)
  end

  local function Refresh()
    text.SetValue(U.GetXPBarSetting("showText"))
    rep.SetValue(U.GetXPBarSetting("repEnabled"))
    local j
    for j = 1, table.getn(XP_SLIDERS) do
      local key = XP_SLIDERS[j].key
      if controls[key] then controls[key].SetValue(U.GetXPBarSetting(key)) end
    end
  end

  return widgets, Refresh
end

function XP:OnInit()
  EnsureConfig()
  if type(U.RegisterSettingsTab) == "function" then
    U.RegisterSettingsTab("xpbar", "Experience Bar", BuildSettingsPage)
  end
end

function XP:OnEnable()
  EnsureConfig()
  if not xpAnchor then Build() end

  local i, events = nil, {
    "PLAYER_ENTERING_WORLD", "PLAYER_XP_UPDATE", "PLAYER_LEVEL_UP", "UPDATE_EXHAUSTION",
  }
  for i = 1, table.getn(events) do U.RegisterEvent(events[i], RefreshXP) end

  local repEvents = { "UPDATE_FACTION", "CHAT_MSG_COMBAT_FACTION_CHANGE", "PLAYER_ENTERING_WORLD" }
  for i = 1, table.getn(repEvents) do U.RegisterEvent(repEvents[i], RefreshReputation) end

  -- Neither event list is confirmed in the compact evidence; polling keeps
  -- both bars correct even when one does not arrive.
  U.RegisterUpdate("xpbar.refresh", 2, function()
    if U.PerfDisabled and U.PerfDisabled("xpbar") then return end
    RefreshXP()
    RefreshReputation()
  end)

  U.ApplyXPBar()
end
