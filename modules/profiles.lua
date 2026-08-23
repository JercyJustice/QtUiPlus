-- QtUiPlus :: modules/profiles.lua
--
-- Named snapshots of the whole configuration: frame positions, per-module
-- enable flags, and the ported QtUI layout settings. Save one per character or
-- per resolution and switch between them.
--
-- This is written against the QtUiPlus config rather than ported from QtUI
-- Profiles.lua. QtUI's version serialises QtUI's own layout table and calls
-- back into QtUI:ApplyLayout to re-apply it; neither exists here, and the
-- store it walks has a different shape. The behaviour that mattered -- named
-- profiles, and positions that survive a resolution change -- is reproduced.
--
-- RESOLUTION REMAP: positions are stored with the screen size they were
-- captured at. Loading a profile saved at a different size scales the offsets
-- rather than replaying them literally, so a layout built at 2560x1440 does not
-- put half the UI off-screen at 1920x1080. Anchor points are never scaled --
-- only the offsets from them.
--
-- STORAGE: profiles live under QtUiPlusDB.qt (see core/qtcompat.lua) rather
-- than in the module store, because core/config.lua's SanitizeModules caps a
-- module table at one level of nesting and would flatten them on load.

local U = QtUiPlus
local M = U.media

local P = U.RegisterModule("profiles")

-- A profile that grew without limit would eventually be the largest thing in
-- the saved file. These caps are far above any real layout.
local MAX_PROFILES = 20
local MAX_NAME_LENGTH = 32

-- ---------------------------------------------------------------------------
-- Store
-- ---------------------------------------------------------------------------

local function Store()
  local db = QtP.EnsureDB()
  if type(db.profiles) ~= "table" then db.profiles = {} end
  return db.profiles
end

local function ScreenSize()
  local width, height = 1024, 768
  if UIParent and UIParent.GetWidth then
    local ok, value = pcall(UIParent.GetWidth, UIParent)
    width = (ok and tonumber(value)) or width
  end
  if UIParent and UIParent.GetHeight then
    local ok, value = pcall(UIParent.GetHeight, UIParent)
    height = (ok and tonumber(value)) or height
  end
  if width <= 0 then width = 1024 end
  if height <= 0 then height = 768 end
  return width, height
end

-- Names are used as table keys in the saved file, so they go through the same
-- restriction core/config.lua puts on every persisted string: no backslashes
-- (this client's SavedVariables writer does not escape them safely) and no
-- control characters.
local function CleanName(name)
  if type(name) ~= "string" then return nil end
  name = string.gsub(name, "^%s+", "")
  name = string.gsub(name, "%s+$", "")
  if name == "" then return nil end
  if string.len(name) > MAX_NAME_LENGTH then
    name = string.sub(name, 1, MAX_NAME_LENGTH)
  end
  if string.find(name, "\\", 1, true) then return nil end
  if string.find(name, "%c") then return nil end
  return name
end

-- ---------------------------------------------------------------------------
-- Snapshot / restore
-- ---------------------------------------------------------------------------

local function CopyScalars(source)
  local out = {}
  if type(source) ~= "table" then return out end
  local key, value
  for key, value in pairs(source) do
    local t = type(value)
    if t == "number" or t == "boolean" or t == "string" then
      out[key] = value
    elseif t == "table" then
      out[key] = CopyScalars(value)
    end
  end
  return out
end

local function Snapshot()
  local width, height = ScreenSize()
  local db = QtP.EnsureDB()
  return {
    screenWidth = width,
    screenHeight = height,
    positions = CopyScalars(U.db and U.db.positions),
    modules = CopyScalars(U.db and U.db.modules),
    layout = CopyScalars(db.layout),
  }
end

-- Scales stored offsets from the resolution they were captured at to the
-- current one. A profile with no recorded size (hand-edited, or written by an
-- older build) is applied unscaled rather than guessed at.
local function RemapPositions(positions, sourceWidth, sourceHeight)
  local out = {}
  if type(positions) ~= "table" then return out end

  local width, height = ScreenSize()
  sourceWidth = tonumber(sourceWidth)
  sourceHeight = tonumber(sourceHeight)

  local scaleX, scaleY = 1, 1
  if sourceWidth and sourceHeight and sourceWidth > 0 and sourceHeight > 0 then
    scaleX = width / sourceWidth
    scaleY = height / sourceHeight
  end

  local id, pos
  for id, pos in pairs(positions) do
    if type(pos) == "table" and type(pos.x) == "number" and type(pos.y) == "number" then
      out[id] = {
        point = pos.point,
        relativePoint = pos.relativePoint or pos.point,
        x = pos.x * scaleX,
        y = pos.y * scaleY,
      }
    end
  end
  return out
end

local function Restore(profile)
  if type(profile) ~= "table" or not U.db then return false end

  U.db.positions = RemapPositions(profile.positions,
                                  profile.screenWidth, profile.screenHeight)
  U.db.modules = CopyScalars(profile.modules)

  local db = QtP.EnsureDB()
  db.layout = CopyScalars(profile.layout)
  QtP:EnsureLayoutDefaults()   -- fill anything the profile did not carry

  return true
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function QtP.ProfileNames()
  local names = {}
  local name
  for name in pairs(Store()) do table.insert(names, name) end
  table.sort(names)
  return names
end

function QtP.SaveProfile(name)
  name = CleanName(name)
  if not name then return false, "invalid profile name" end

  local store = Store()
  if not store[name] then
    local count = 0
    local _
    for _ in pairs(store) do count = count + 1 end
    if count >= MAX_PROFILES then
      return false, "profile limit reached (" .. MAX_PROFILES .. ")"
    end
  end

  store[name] = Snapshot()
  return true, name
end

function QtP.LoadProfile(name)
  name = CleanName(name)
  if not name then return false, "invalid profile name" end

  local profile = Store()[name]
  if not profile then return false, "no profile named " .. name end
  if not Restore(profile) then return false, "could not apply profile" end

  return true, name
end

function QtP.DeleteProfile(name)
  name = CleanName(name)
  if not name then return false, "invalid profile name" end

  local store = Store()
  if not store[name] then return false, "no profile named " .. name end
  store[name] = nil
  return true, name
end

-- ---------------------------------------------------------------------------
-- Settings page
--
-- Rows are a fixed pool populated on every open, not built per profile: the
-- build function runs once and only the refresh runs again, so the row count
-- has to be decided up front.
--
-- There is no text-input widget in core/widgets.lua, so saving from this page
-- auto-names the profile ("Profile 1", "Profile 2", ...). A chosen name is
-- still available through |cffffff00/qtp profile save <name>|r.
-- ---------------------------------------------------------------------------
local PAGE_ROWS = 6

local function NextAutoName()
  local existing = {}
  local names = QtP.ProfileNames()
  local i
  for i = 1, table.getn(names) do existing[names[i]] = true end

  local n = 1
  while existing["Profile " .. n] do n = n + 1 end
  return "Profile " .. n
end

local function BuildSettingsPage(parent)
  local widgets, rows = {}, {}

  local header = U.CreateSectionHeader(parent, {
    text = "Profiles", width = 484, y = -4,
  })
  table.insert(widgets, header)

  local Refresh

  local save = U.CreateButton(parent, {
    name = "QtUiPlusProfilesSave",
    text = "Save current layout as a new profile",
    width = 300,
    height = 26,
    onClick = function()
      local ok, result = QtP.SaveProfile(NextAutoName())
      if ok then
        U.Print("saved profile |cffffff00" .. result .. "|r")
      else
        U.Print("could not save: " .. tostring(result))
      end
      if Refresh then Refresh() end
    end,
  })
  save:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -34)
  table.insert(widgets, save)

  local i
  for i = 1, PAGE_ROWS do
    local row = {}
    local y = -74 - (i - 1) * 30

    row.label = U.CreateSettingsLabel(parent, {
      size = M.fontSize.normal, color = M.color.text,
      inherits = "GameFontNormal", justify = "LEFT",
    })
    if row.label then
      row.label:SetPoint("TOPLEFT", parent, "TOPLEFT", 4, y - 6)
      table.insert(widgets, row.label)
    end

    row.load = U.CreateButton(parent, {
      name = "QtUiPlusProfilesLoad" .. i,
      text = "Load",
      width = 80, height = 22,
      onClick = function()
        if not row.name then return end
        local ok, result = QtP.LoadProfile(row.name)
        if ok then
          U.Print("loaded profile |cffffff00" .. result ..
                  "|r - |cffffff00/reload|r to apply it everywhere")
        else
          U.Print("could not load: " .. tostring(result))
        end
      end,
    })
    row.load:SetPoint("TOPLEFT", parent, "TOPLEFT", 200, y)
    table.insert(widgets, row.load)

    row.delete = U.CreateButton(parent, {
      name = "QtUiPlusProfilesDelete" .. i,
      text = "Delete",
      width = 80, height = 22,
      onClick = function()
        if not row.name then return end
        local ok, result = QtP.DeleteProfile(row.name)
        if ok then U.Print("deleted profile |cffffff00" .. result .. "|r") end
        if Refresh then Refresh() end
      end,
    })
    row.delete:SetPoint("TOPLEFT", parent, "TOPLEFT", 290, y)
    table.insert(widgets, row.delete)

    rows[i] = row
  end

  local hint = U.CreateSettingsLabel(parent, {
    size = M.fontSize.small, color = M.color.textDim,
    inherits = "GameFontNormalSmall", justify = "LEFT",
  })
  if hint then
    hint:SetPoint("TOPLEFT", parent, "TOPLEFT", 4, -74 - PAGE_ROWS * 30 - 10)
    hint:SetText("A profile stores frame positions, module toggles and the " ..
                 "extras settings, and rescales positions saved at another " ..
                 "resolution. |cffffff00/qtp profile save <name>|r names one.")
    table.insert(widgets, hint)
  end

  Refresh = function()
    local names = QtP.ProfileNames()
    local j
    for j = 1, PAGE_ROWS do
      local row = rows[j]
      row.name = names[j]
      if row.name then
        if row.label then
          row.label:SetText(row.name)
          row.label:Show()
        end
        row.load:Show()
        row.delete:Show()
      else
        if row.label then row.label:Hide() end
        row.load:Hide()
        row.delete:Hide()
      end
    end
  end

  return widgets, Refresh
end

function P:OnInit()
  if type(U.RegisterSettingsTab) == "function" then
    U.RegisterSettingsTab("profiles", "Profiles", BuildSettingsPage)
  end
end

function P:OnEnable()
  -- Nothing to build. Registered so profiles appear in the module list and the
  -- store is created on a fresh install before the first save.
  Store()
end
