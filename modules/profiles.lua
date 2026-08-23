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

function P:OnEnable()
  -- Nothing to build. Registered so profiles appear in the module list and the
  -- store is created on a fresh install before the first save.
  Store()
end
