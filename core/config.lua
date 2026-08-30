-- QtUiPlus :: core/config.lua
--
-- Defaults, SavedVariables load/validate, the named profiles those settings
-- live in, and the shared position store used by the mover system.
--
-- knowledge.json / config.savedvariables_backslash_corruption: this client's
-- SavedVariables writer does not escape backslashes safely. A stored path can
-- return with lost separators, and a backslash sequence can come back as a
-- control character. QtUiPlus's answer is to never persist a path at all:
-- config holds numbers, booleans, short identifiers and anchor names only, and
-- every real media path is rebuilt from core/media.lua at runtime.
--
-- The load path still validates defensively, because a corrupted or
-- hand-edited saved file must not be able to break the addon's bootstrap.

local U = QtUiPlus

local CONFIG_VERSION = 2

-- Shape of QtUiPlusProfiles itself, separate from the per-profile config
-- version above: the store can gain structure without every profile inside it
-- needing a migration.
local PROFILE_STORE_VERSION = 1

-- A profile that grew without limit would eventually be the largest thing in
-- the saved file. These caps are far above any real layout.
local MAX_PROFILES = 20
local MAX_NAME_LENGTH = 32

-- Anchor points are the only strings QtUiPlus persists. Whitelisting them means
-- a corrupted value is rejected rather than fed to SetPoint.
local VALID_POINTS = {
  TOP = true, BOTTOM = true, LEFT = true, RIGHT = true, CENTER = true,
  TOPLEFT = true, TOPRIGHT = true, BOTTOMLEFT = true, BOTTOMRIGHT = true,
}

local defaults = {
  version   = CONFIG_VERSION,
  debug     = false,
  -- Visual style; see core/theme.lua. A change takes effect on the next
  -- reload, because already-built frames own tinted textures and font colours
  -- that swapping the token table alone would not revisit.
  themeStyle = "modern",
  -- Diagnostic only, set by /qtp nosuppress. core/compat.lua's native-frame
  -- suppression is applied once at OnEnable and is irreversible within a
  -- session -- Show is replaced by a no-op whose original is not kept, and
  -- UnregisterAllEvents cannot be undone -- so the only way to measure
  -- QtUiPlus *without* it is to skip it at load. Persisted because the skip
  -- has to survive the /reload that applies it.
  noSuppress = false,
  -- Diagnostic bisect of the suppression *recipe*, not just on/off. Measured:
  -- the recipe's permanent state costs +2.66ms/frame (142 -> 103fps) and turns
  -- a 9ms target-change peak into 159ms, while its periodic sweep only costs a
  -- further +1.55ms. So the expensive part is what is done to the ~1275 stock
  -- objects, and this picks how much of it to do:
  --   0  nothing (same as noSuppress)
  --   1  Hide() only
  --   2  + SetAlpha(0)
  --   3  + EnableMouse(false) and the Show() neutraliser
  --   4  + UnregisterAllEvents and the periodic/event re-apply  (shipped behaviour)
  -- A number, not a string: knowledge.json / config.savedvariables_backslash
  -- _corruption means only numbers and booleans are safe to persist here.
  suppressLevel = 4,
  locked    = true,     -- mover mode state; see core/mover.lua
  positions = {},       -- mover id -> { point, relativePoint, x, y }
  modules   = {},       -- module name -> { enabled = true }
}

-- ---------------------------------------------------------------------------
-- Validation
-- ---------------------------------------------------------------------------

-- Rejects any string that could have been mangled by the SavedVariables
-- writer. QtUiPlus has no legitimate reason to persist one.
local function IsSafeString(value)
  if type(value) ~= "string" then return false end
  if string.find(value, "\\", 1, true) then return false end
  if string.find(value, "%c") then return false end
  return true
end

local function IsValidPosition(pos)
  if type(pos) ~= "table" then return false end
  if not VALID_POINTS[pos.point] then return false end
  if pos.relativePoint ~= nil and not VALID_POINTS[pos.relativePoint] then
    return false
  end
  if type(pos.x) ~= "number" or type(pos.y) ~= "number" then return false end
  -- A position far outside any plausible screen is treated as corrupt so the
  -- frame falls back to its default instead of vanishing off-screen.
  if math.abs(pos.x) > 10000 or math.abs(pos.y) > 10000 then return false end
  return true
end

-- Fills in anything missing and replaces anything whose type does not match the
-- default. Free-form subtables (positions, modules) are validated by their own
-- rules below rather than against a fixed shape.
local function ApplyDefaults(stored, template)
  if type(stored) ~= "table" then stored = {} end

  local key, value
  for key, value in pairs(template) do
    if type(value) == "table" then
      stored[key] = ApplyDefaults(stored[key], value)
    elseif type(stored[key]) ~= type(value) then
      stored[key] = value
    elseif type(stored[key]) == "string" and not IsSafeString(stored[key]) then
      stored[key] = value
    end
  end

  return stored
end

local function SanitizePositions(positions)
  if type(positions) ~= "table" then return {} end

  local clean = {}
  local id, pos
  for id, pos in pairs(positions) do
    if IsSafeString(id) and IsValidPosition(pos) then
      clean[id] = {
        point = pos.point,
        relativePoint = pos.relativePoint or pos.point,
        x = pos.x,
        y = pos.y,
      }
    else
      U.Debug("dropped invalid stored position: " .. tostring(id))
    end
  end
  return clean
end

local function SanitizeScalar(target, key, value)
  local t = type(value)
  if t == "number" or t == "boolean" then
    target[key] = value
    return true
  elseif t == "string" and IsSafeString(value) then
    target[key] = value
    return true
  end
  return false
end

-- One level of nesting inside a module's settings.
--
-- Module settings used to be scalars only, and every nested table was dropped
-- silently on load. That is what made the Quest Log's remembered tracked-quest
-- titles (questlog.trackedQuests) reset on every /reload: the module wrote them,
-- the writer stored them, and this sanitizer deleted them on the way back in.
--
-- Nested keys are validated, not just values: unlike a module's own scalar keys,
-- which are identifiers written in QtUiPlus source, these keys are game data
-- (quest titles) and so are exactly the sort of string
-- config.savedvariables_backslash_corruption warns about. Entries are capped so
-- a module cannot grow the saved file without bound, and nesting stops at one
-- level so this stays a set/lookup store rather than an arbitrary object graph.
local MAX_MODULE_TABLE_ENTRIES = 200

local function SanitizeModuleTable(source)
  local clean, count, key, value = {}, 0, nil, nil
  for key, value in pairs(source) do
    if count >= MAX_MODULE_TABLE_ENTRIES then break end
    local keyOk = type(key) == "number" or
                  (type(key) == "string" and IsSafeString(key))
    if keyOk and SanitizeScalar(clean, key, value) then
      count = count + 1
    end
  end
  return clean
end

local function SanitizeModules(modules)
  if type(modules) ~= "table" then return {} end

  local clean = {}
  local name, settings
  for name, settings in pairs(modules) do
    if IsSafeString(name) and type(settings) == "table" then
      local entry, key, value = {}, nil, nil
      for key, value in pairs(settings) do
        if type(value) == "table" then
          entry[key] = SanitizeModuleTable(value)
        else
          SanitizeScalar(entry, key, value)
        end
      end
      clean[name] = entry
    end
  end
  return clean
end

-- ---------------------------------------------------------------------------
-- Profiles
--
-- Settings live in named profiles held account-wide in QtUiPlusProfiles. Each
-- character stores only the name of the profile it uses (QtUiPlusProfileDB),
-- so two characters can share one layout or keep their own.
--
-- A profile carries two tables, not one. QtUiPlus keeps core settings in U.db
-- and the ported QtUI layout in its own store (core/qtcompat.lua); a profile
-- that held only the first would switch half the interface and leave the other
-- half behind. So `core` and `qt` are the two live tables -- the active profile
-- *is* the live state, not a snapshot of it.
-- ---------------------------------------------------------------------------
local profiles = {}      -- name -> { core, qt, screenWidth, screenHeight }
local assignments = {}   -- character key -> profile name
local characterKey = nil

-- Profile names are table keys in the saved file, so they take the same
-- restriction as every other persisted string, plus a length cap.
local function IsSafeProfileName(name)
  if type(name) ~= "string" or name == "" then return false end
  if string.len(name) > MAX_NAME_LENGTH then return false end
  return IsSafeString(name)
end

local function CopyTable(source)
  if type(source) ~= "table" then return {} end
  local out, key, value = {}, nil, nil
  for key, value in pairs(source) do
    if type(value) == "table" then
      out[key] = CopyTable(value)
    else
      out[key] = value
    end
  end
  return out
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

-- Scales stored offsets from the resolution a profile was laid out at to the
-- current one, so a layout built at 2560x1440 does not put half the interface
-- off-screen at 1920x1080. Anchor points are never scaled -- only the offsets
-- from them -- and a profile with no recorded size is applied unscaled rather
-- than guessed at.
local function RemapPositions(positions, sourceWidth, sourceHeight)
  if type(positions) ~= "table" then return {} end

  sourceWidth = tonumber(sourceWidth)
  sourceHeight = tonumber(sourceHeight)
  if not sourceWidth or not sourceHeight or
     sourceWidth <= 0 or sourceHeight <= 0 then
    return positions
  end

  local width, height = ScreenSize()
  if width == sourceWidth and height == sourceHeight then return positions end

  local scaleX, scaleY = width / sourceWidth, height / sourceHeight
  local id, pos
  for id, pos in pairs(positions) do
    if type(pos) == "table" and type(pos.x) == "number" and
       type(pos.y) == "number" then
      pos.x = U.Round(pos.x * scaleX)
      pos.y = U.Round(pos.y * scaleY)
    end
  end

  U.Debug("remapped positions " .. tostring(sourceWidth) .. "x" ..
          tostring(sourceHeight) .. " -> " .. tostring(width) .. "x" ..
          tostring(height))
  return positions
end

-- Everything U.LoadConfig used to do to the one flat table, now applied to
-- each profile's core table as it is read.
local function PrepareConfig(stored)
  local db = ApplyDefaults(stored, defaults)
  db.positions = SanitizePositions(db.positions)
  db.modules = SanitizeModules(db.modules)

  if db.version ~= CONFIG_VERSION then
    U.Debug("config version " .. tostring(db.version) ..
            " -> " .. tostring(CONFIG_VERSION))
    db.version = CONFIG_VERSION
  end
  return db
end

local function NewProfile(core, qt, width, height)
  if not width or not height then width, height = ScreenSize() end
  return {
    core = PrepareConfig(core or {}),
    qt = (type(qt) == "table") and qt or {},
    screenWidth = width,
    screenHeight = height,
  }
end

-- Which profile this character gets when it has never been assigned one.
local function CharacterProfileName()
  local name, realm

  if type(UnitName) == "function" then
    local ok, value = pcall(UnitName, "player")
    if ok and type(value) == "string" and value ~= "" then name = value end
  end
  if type(GetRealmName) == "function" then
    local ok, value = pcall(GetRealmName)
    if ok and type(value) == "string" and value ~= "" then realm = value end
  end

  local candidate
  if name and realm then
    candidate = name .. " - " .. realm
  elseif name then
    candidate = name
  else
    candidate = "Character Profile"
  end

  if IsSafeProfileName(candidate) then return candidate end
  return "Character Profile"
end

local function SortedProfileNames(exclude)
  local names, name = {}, nil
  for name in pairs(profiles) do
    if name ~= exclude then table.insert(names, name) end
  end
  table.sort(names)
  return names
end

local function ProfileCount()
  local count, name = 0, nil
  for name in pairs(profiles) do count = count + 1 end
  return count
end

-- Points the live tables at one profile. Everything else in the addon reads
-- U.db and QtP.EnsureDB(), so this one assignment is the whole switch.
local function SetActiveProfile(name)
  local profile = profiles[name]
  if not IsSafeProfileName(name) or type(profile) ~= "table" then return false end

  -- A layout captured at another resolution is scaled on the way in, and the
  -- profile then records the size it is now laid out for.
  profile.core.positions = RemapPositions(profile.core.positions,
                                          profile.screenWidth,
                                          profile.screenHeight)
  profile.screenWidth, profile.screenHeight = ScreenSize()

  if type(QtUiPlusProfileDB) ~= "table" then QtUiPlusProfileDB = {} end
  QtUiPlusProfileDB.active = name
  if IsSafeProfileName(characterKey) then assignments[characterKey] = name end

  U.profile = profile
  U.db = profile.core
  return true
end

-- The QtUI layout half of the active profile. core/qtcompat.lua resolves its
-- store through this rather than reaching into a global, so a profile switch
-- moves that half of the settings too.
function U.ProfileQtStore()
  if type(U.profile) ~= "table" then return nil end
  if type(U.profile.qt) ~= "table" then U.profile.qt = {} end
  return U.profile.qt
end

-- ---------------------------------------------------------------------------
-- Load
--
-- Migration, and why nothing is deleted
--
--   Before profiles there was one flat QtUiPlusDB plus named snapshots parked
--   in QtUiPlusDB.qt.profiles. Both are read once here and turned into real
--   profiles, and both are then left exactly where they are. A migration that
--   also deleted its own source would leave a player whose first post-upgrade
--   login went wrong with nothing to go back to.
-- ---------------------------------------------------------------------------
local function MigrateLegacy()
  local width, height = ScreenSize()

  -- The old live config becomes this character's own profile.
  local legacyQt = CopyTable((type(QtUiPlusDB.qt) == "table") and QtUiPlusDB.qt or {})
  -- The old snapshots are migrated separately below; they must not be copied
  -- into every profile's layout store as well.
  legacyQt.profiles = nil

  -- ApplyDefaults only walks keys present in its template, so a stray `qt` on
  -- the copied config would survive into every migrated profile as a second,
  -- unread copy of the whole layout store.
  local legacyCore = CopyTable(QtUiPlusDB)
  legacyCore.qt = nil

  profiles[characterKey] = NewProfile(legacyCore, legacyQt, width, height)
  U.Debug("migrated the flat config into profile: " .. tostring(characterKey))

  -- The old named snapshots become profiles of their own. A snapshot held
  -- positions, module flags and the QtUI layout, but not the rest of the core
  -- config, so the live config supplies that base.
  local stored = (type(QtUiPlusDB.qt) == "table") and QtUiPlusDB.qt.profiles or nil
  if type(stored) ~= "table" then return end

  local name, snapshot
  for name, snapshot in pairs(stored) do
    if IsSafeProfileName(name) and type(snapshot) == "table" and
       not profiles[name] and ProfileCount() < MAX_PROFILES then
      local core = CopyTable(QtUiPlusDB)
      core.qt = nil
      core.positions = CopyTable(snapshot.positions)
      core.modules = CopyTable(snapshot.modules)
      profiles[name] = NewProfile(core, { layout = CopyTable(snapshot.layout) },
                                  tonumber(snapshot.screenWidth) or width,
                                  tonumber(snapshot.screenHeight) or height)
      U.Debug("migrated legacy snapshot into profile: " .. name)
    end
  end
end

function U.LoadConfig()
  if type(QtUiPlusDB) ~= "table" then QtUiPlusDB = {} end
  if type(QtUiPlusProfiles) ~= "table" then QtUiPlusProfiles = {} end
  if type(QtUiPlusProfileDB) ~= "table" then QtUiPlusProfileDB = {} end

  characterKey = CharacterProfileName()

  local storedProfiles = QtUiPlusProfiles.profiles
  local storedAssignments = QtUiPlusProfiles.assignments

  profiles = {}
  if type(storedProfiles) == "table" then
    local name, stored
    for name, stored in pairs(storedProfiles) do
      if IsSafeProfileName(name) and type(stored) == "table" then
        profiles[name] = NewProfile(stored.core, stored.qt,
                                    tonumber(stored.screenWidth),
                                    tonumber(stored.screenHeight))
      end
    end
  end

  if ProfileCount() == 0 then MigrateLegacy() end

  assignments = {}
  if type(storedAssignments) == "table" then
    local character, assigned
    for character, assigned in pairs(storedAssignments) do
      if IsSafeProfileName(character) and IsSafeProfileName(assigned) and
         type(profiles[assigned]) == "table" then
        assignments[character] = assigned
      end
    end
  end

  -- This character's own record wins over the account-wide mirror, which is
  -- only there so the UI can tell which profiles are in use elsewhere.
  local active = QtUiPlusProfileDB.active
  if not IsSafeProfileName(active) or type(profiles[active]) ~= "table" then
    active = assignments[characterKey]
  end
  if not IsSafeProfileName(active) or type(profiles[active]) ~= "table" then
    active = characterKey
    if type(profiles[active]) ~= "table" then
      profiles[active] = NewProfile({}, {})
    end
  end

  QtUiPlusProfiles = {
    version = PROFILE_STORE_VERSION,
    profiles = profiles,
    assignments = assignments,
  }

  SetActiveProfile(active)
  return U.db
end

-- ---------------------------------------------------------------------------
-- Profile API
--
-- Used by modules/profiles.lua (the settings page) and core/commands.lua.
-- Every entry point returns ok plus either the name it acted on or a reason,
-- so both frontends can report the same thing without repeating the rules.
-- ---------------------------------------------------------------------------
function U.GetCurrentProfileName()
  if type(QtUiPlusProfileDB) ~= "table" then return "" end
  return QtUiPlusProfileDB.active or ""
end

function U.GetProfileNames(excludeCurrent)
  return SortedProfileNames(excludeCurrent and U.GetCurrentProfileName() or nil)
end

-- Which character, if any, other than this one is assigned to a profile.
function U.ProfileIsAssignedElsewhere(name)
  local character, assigned
  for character, assigned in pairs(assignments) do
    if assigned == name and character ~= characterKey then return character end
  end
  return nil
end

-- A profile still assigned to another character is not offered for deletion:
-- removing it would silently move that character onto a different layout the
-- next time it logs in.
function U.GetDeletableProfileNames()
  local names = SortedProfileNames(U.GetCurrentProfileName())
  local result, i = {}, nil
  for i = 1, table.getn(names) do
    if not U.ProfileIsAssignedElsewhere(names[i]) then
      table.insert(result, names[i])
    end
  end
  return result
end

-- The settings window cannot ask for a name: this client crashes when an
-- addon-created EditBox takes focus. Its Create button therefore generates one,
-- and /qtp profile create <name> is the route to a custom one.
function U.NextProfileName()
  local i
  for i = 1, MAX_PROFILES + 1 do
    local candidate = "Profile " .. i
    if not profiles[candidate] then return candidate end
  end
  return "Profile " .. (MAX_PROFILES + 1)
end

-- A new profile starts at the defaults rather than as a copy of the active
-- one; U.CopyProfile is how a layout is duplicated.
function U.CreateProfile(name, select)
  if not IsSafeProfileName(name) then return false, "invalid profile name" end
  if profiles[name] then return false, "a profile named " .. name .. " exists" end
  if ProfileCount() >= MAX_PROFILES then
    return false, "profile limit (" .. MAX_PROFILES .. ") reached"
  end

  profiles[name] = NewProfile({}, {})
  if select then SetActiveProfile(name) end
  return true, name
end

-- Copies another profile *into* the active one rather than switching to it, so
-- the character keeps the profile it is assigned to and every other character
-- sharing that profile gets the change too.
function U.CopyProfile(name)
  local source = profiles[name]
  if type(source) ~= "table" then
    return false, "no profile named " .. tostring(name)
  end

  local current = U.GetCurrentProfileName()
  if name == current then return false, "that is already the active profile" end

  local target = profiles[current]
  if type(target) ~= "table" then return false, "no active profile" end

  target.core = PrepareConfig(CopyTable(source.core))
  target.qt = CopyTable(source.qt)
  target.screenWidth = source.screenWidth
  target.screenHeight = source.screenHeight

  if not SetActiveProfile(current) then return false, "could not apply the copy" end
  return true, name
end

function U.DeleteProfile(name)
  if type(profiles[name]) ~= "table" then
    return false, "no profile named " .. tostring(name)
  end
  if name == U.GetCurrentProfileName() then
    return false, "cannot delete the active profile"
  end

  local other = U.ProfileIsAssignedElsewhere(name)
  if other then return false, name .. " is in use by " .. other end

  profiles[name] = nil
  return true, name
end

function U.SelectProfile(name)
  if type(profiles[name]) ~= "table" then
    return false, "no profile named " .. tostring(name)
  end
  if not SetActiveProfile(name) then
    return false, "could not select " .. name
  end
  return true, name
end

-- Empties the active profile in place, so every character assigned to it keeps
-- that assignment and gets the defaults.
function U.ResetCurrentProfile()
  local name = U.GetCurrentProfileName()
  local profile = profiles[name]
  if type(profile) ~= "table" then return false, "no active profile" end

  profile.core = PrepareConfig({})
  profile.qt = {}
  profile.screenWidth, profile.screenHeight = ScreenSize()

  if not SetActiveProfile(name) then return false, "could not apply the reset" end
  return true, name
end

-- ---------------------------------------------------------------------------
-- Module settings
-- ---------------------------------------------------------------------------

-- Returns the module's settings table, creating it from the supplied defaults
-- on first use. Modules own their own defaults so core does not accumulate a
-- central schema for every feature.
function U.ModuleConfig(name, moduleDefaults)
  if not U.db then return moduleDefaults or {} end

  if type(U.db.modules[name]) ~= "table" then
    U.db.modules[name] = {}
  end

  local settings = U.db.modules[name]
  if type(moduleDefaults) == "table" then
    local key, value
    for key, value in pairs(moduleDefaults) do
      if type(settings[key]) ~= type(value) then
        settings[key] = value
      end
    end
  end

  return settings
end

-- ---------------------------------------------------------------------------
-- Position store
--
-- Positions are always relative to UIParent, so nothing here has to persist a
-- frame reference or a generated frame name.
-- ---------------------------------------------------------------------------
function U.SavePosition(id, point, relativePoint, x, y)
  if not U.db or not IsSafeString(id) then return false end

  local pos = {
    point = point,
    relativePoint = relativePoint or point,
    x = U.Round(x),
    y = U.Round(y),
  }

  if not IsValidPosition(pos) then
    U.Debug("refused to save invalid position for " .. tostring(id))
    return false
  end

  U.db.positions[id] = pos
  return true
end

function U.GetPosition(id)
  if not U.db or type(id) ~= "string" then return nil end
  return U.db.positions[id]
end

function U.ClearAllPositions()
  if not U.db then return end
  U.db.positions = {}
end
