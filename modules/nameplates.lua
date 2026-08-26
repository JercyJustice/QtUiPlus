-- QtUiPlus :: modules/nameplates.lua
--
-- Replaces the client's floating nameplate art with QtUiPlus's own overlay:
--
--   Name .............................. Level
--   [==============  100.0%  ==============]  raid
--   [==============  cast   ==============]
--                                      CP CP
--   [debuff] [debuff] [debuff]
--
-- Name/level stay on the bar's edges (the layout already shipped here). Cast
-- bar, raid icon, combo points, target/mouseover debuffs and totem plates
-- follow pfUI/modules/nameplates.lua as WORKING_SOURCE, adapted to this
-- client's APIs (no SuperWoW GUID, no UnitCastingInfo on non-target units,
-- GetComboPoints() takes no arguments -- emberveil.org/wiki/lua/globals/Character#getcombopoints,
-- UnitDebuff returns texture, stacks -- emberveil.org/wiki/lua/globals/Unit#unitdebuff).
--
-- Compatibility notes that shaped this file:
--
--   * query_compat.py has NO record for nameplates, WorldFrame:GetChildren,
--     GetNumChildren, HookScript, ShowNameplates or the nameplate frame shape on
--     this client. Per the evidence-gap rule the discovery path follows what
--     UnrealPfUI does (modules/nameplates.lua: poll WorldFrame's children, take
--     the plate's regions and StatusBar children, read health from the native
--     bar). That is WORKING_SOURCE evidence, not runtime verification.
--   * UnrealPfUI keys the plate's parts off a fixed region *order*
--     (NAMEPLATE_OBJECTORDER) and a fixed border texture path. This client's
--     stock nameplate does not look like Vanilla's -- the observed plate draws a
--     name and a level and no health bar at all -- so an assumed order would map
--     the wrong region. Parts are therefore classified by what they actually
--     are (FontString vs Texture vs StatusBar child, and the texture's own
--     path), and everything unrecognised is muted. U.NameplateReport() prints
--     what was found so the guess can be replaced with measurement.
--   * A plate with no usable native health bar still gets a name/level row; the
--     bar is simply hidden rather than drawn empty.
--   * knowledge.json / scripts.child_onupdate_unreliable: no frame built here
--     owns an OnUpdate, and no script is hooked onto a native plate. Discovery
--     and refresh both run on the shared U.RegisterUpdate driver.
--   * knowledge.json / statusbar.native_widget_fill_not_laid_out: the bar is
--     U.CreateStatusBar, not the client's StatusBar widget.
--   * knowledge.json / rendering.native_texture_strip_requires_alpha: native
--     plate art is muted with SetTexture(nil) + SetAlpha(0) but deliberately
--     *not* Hide()d -- IsShown() on the native glow and elite icon is still the
--     only signal for mouseover and elite status.
--   * knowledge.json / fonts.stretched_justification_ignored: every label is
--     anchored to the one edge it belongs to, never stretched corner to corner.
--   * knowledge.json / core.getdifficultycolor_missing: level colour is taken
--     from the native level fontstring when it has one, with a local difficulty
--     helper as the fallback. No shim global is installed.

local U = QtUiPlus
local M = U.media

local NP = U.RegisterModule("nameplates")

-- ---------------------------------------------------------------------------
-- Configuration
--
-- Sizes are in plate units, before the UI scale the overlay inherits below.
-- ---------------------------------------------------------------------------
local defaults = {
  enabled        = true,
  width          = 160,
  healthHeight   = 17,
  castHeight     = 8,
  nameSize       = 12,
  levelSize      = 12,
  healthTextSize = 11,
  verticalOffset = 0,
  showHealthText = true,
  fadeOthers     = true,
  otherAlpha     = 0.75,
  showCastbar    = true,
  showDebuffs    = true,
  showCombo      = true,
  showRaidIcon   = true,
  targetGlow     = true,
  hideTotems     = true,
  totemIcons     = false,
  hideCritters   = true,
  classColor     = true,
}

local LIMITS = {
  width        = { min = 80, max = 220, step = 2 },
  healthHeight = { min = 8,  max = 28,  step = 1 },
  castHeight   = { min = 4,  max = 16,  step = 1 },
}

local DEBUFF_SIZE = 14
local DEBUFF_MAX = 8
local COMBO_SIZE = 6
local RAIDICON_SIZE = 16
local RAIDICON_TEXTURE = "Interface\\TargetingFrame\\UI-RaidTargetingIcons"

local cfg = defaults

-- ---------------------------------------------------------------------------
-- Colours
--
-- Read from the native health bar's own tint, the way UnrealPfUI derives unit
-- type, then mapped onto QtUiPlus's muted palette rather than the client's
-- saturated primaries.
-- ---------------------------------------------------------------------------
local UNIT_COLOR = {
  ENEMY         = { 0.75, 0.27, 0.32, 1.00 },
  NEUTRAL       = { 0.80, 0.72, 0.26, 1.00 },
  FRIENDLY_NPC  = { 0.35, 0.66, 0.34, 1.00 },
  FRIENDLY_UNIT = { 0.26, 0.50, 0.82, 1.00 },
}

-- Vanilla shaman totems: name fragment -> icon file (pfUI env/locales_enUS).
local TOTEMS = {
  ["Disease Cleansing Totem"] = "Spell_Nature_DiseaseCleansingTotem",
  ["Earthbind Totem"]         = "Spell_Nature_StrengthOfEarthTotem02",
  ["Fire Nova Totem"]         = "Spell_Fire_SealOfFire",
  ["Fire Resistance Totem"]   = "Spell_FireResistanceTotem_01",
  ["Flametongue Totem"]       = "Spell_Nature_GuardianWard",
  ["Frost Resistance Totem"]  = "Spell_FrostResistanceTotem_01",
  ["Grace of Air Totem"]      = "Spell_Nature_InvisibilityTotem",
  ["Grounding Totem"]         = "Spell_Nature_GroundingTotem",
  ["Healing Stream Totem"]    = "INV_Spear_04",
  ["Magma Totem"]             = "Spell_Fire_SelfDestruct",
  ["Mana Spring Totem"]       = "Spell_Nature_ManaRegenTotem",
  ["Mana Tide Totem"]         = "Spell_Frost_SummonWaterElemental",
  ["Nature Resistance Totem"] = "Spell_Nature_NatureResistanceTotem",
  ["Poison Cleansing Totem"]  = "Spell_Nature_PoisonCleansingTotem",
  ["Searing Totem"]           = "Spell_Fire_SearingTotem",
  ["Sentry Totem"]            = "Spell_Nature_RemoveCurse",
  ["Stoneclaw Totem"]         = "Spell_Nature_StoneClawTotem",
  ["Stoneskin Totem"]         = "Spell_Nature_StoneSkinTotem",
  ["Strength of Earth Totem"] = "Spell_Nature_EarthBindTotem",
  ["Tremor Totem"]            = "Spell_Nature_TremorTotem",
  ["Windfury Totem"]          = "Spell_Nature_Windfury",
  ["Windwall Totem"]          = "Spell_Nature_EarthBind",
}

local CRITTERS = {
  adder=true, beetle=true, chicken=true, cow=true, cat=true, deer=true,
  dog=true, fawn=true, frog=true, gazelle=true, hare=true, horse=true,
  larva=true, rabbit=true, rat=true, sheep=true, snake=true, squirrel=true,
  toad=true, ["black rat"]=true, ["brown prairie dog"]=true,
}

local COMBO_COLOR = {
  { 1.00, 0.30, 0.30, 0.90 },
  { 1.00, 0.30, 0.30, 0.90 },
  { 1.00, 1.00, 0.30, 0.90 },
  { 0.30, 1.00, 0.30, 0.90 },
  { 0.30, 1.00, 0.30, 0.90 },
}

local function UnitTypeFromBarColor(r, g, b)
  if type(r) ~= "number" or type(g) ~= "number" or type(b) ~= "number" then
    return nil
  end
  if r > 0.8 and g < 0.3 and b < 0.3 then return "ENEMY" end
  if r > 0.8 and g > 0.8 and b < 0.3 then return "NEUTRAL" end
  if r < 0.3 and g > 0.8 and b < 0.3 then return "FRIENDLY_NPC" end
  if r < 0.3 and g < 0.3 and b > 0.8 then return "FRIENDLY_UNIT" end
  return nil
end

local function TotemIcon(name)
  if type(name) ~= "string" then return nil end
  local icon = TOTEMS[name]
  if icon then return icon end
  local key, tex
  for key, tex in pairs(TOTEMS) do
    if string.find(name, key, 1, true) then return tex end
  end
  return nil
end

local function IsCritterName(name)
  if type(name) ~= "string" then return false end
  return CRITTERS[string.lower(name)] and true or false
end

local function ComboCount()
  local get = U.G("GetComboPoints")
  if type(get) ~= "function" then return 0 end
  -- Wiki: GetComboPoints() takes no arguments.
  local ok, value = pcall(get)
  if not ok then ok, value = pcall(get, "player", "target") end
  if not ok then return 0 end
  return tonumber(value) or 0
end

-- Wiki: UnitDebuff(unit, index) -> texture, stacks, dispelType
local function DebuffIcon(unit, index)
  local fn = U.G("UnitDebuff")
  if type(fn) ~= "function" then return nil, 0 end
  local ok, texture, stacks = pcall(fn, unit, index)
  if not ok or type(texture) ~= "string" or texture == "" then return nil, 0 end
  return texture, tonumber(stacks) or 0
end

-- ---------------------------------------------------------------------------
-- API access
--
-- Same contract as modules/unitframes.lua: resolve by name once, pcall the
-- call, coerce the result. Nothing here assumes a Vanilla return shape.
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

local function ApiNumber(name, a, b)
  local fn = ResolveApiFn(name)
  if not fn then return nil end
  local ok, value = pcall(fn, a, b)
  if not ok then return nil end
  return tonumber(value)
end

local function ApiString(name, a, b)
  local fn = ResolveApiFn(name)
  if not fn then return nil end
  local ok, value = pcall(fn, a, b)
  if not ok or type(value) ~= "string" then return nil end
  return value
end

local function ApiTruth(name, a, b)
  local fn = ResolveApiFn(name)
  if not fn then return false end
  local ok, value = pcall(fn, a, b)
  if not ok then return false end
  if value == nil or value == false or value == 0 or value == "" then
    return false
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------
-- Reads a method off a widget and calls it with no arguments. Every native
-- plate part is touched through here: the object may not have the method at
-- all on this client, and indexing a widget that is not a table would error
-- before the pcall around the call itself could help.
--
-- Deliberately argument-free. Lua 5.0's implicit `arg` table is not something
-- this runtime is verified to provide, so a vararg forwarder would be its own
-- unverified assumption; nothing here needs one.
--
-- The field read is a named upvalue rather than an anonymous closure: this runs
-- for every part of every plate five times a second, and building a closure per
-- call was the same allocation round 2 of
-- knowledge.json / compat.native_suppression_pcall_burst_stutter hoisted out of
-- core/compat.lua's sweep. The pcall boundary is unchanged -- the read still
-- fails independently of the call.
local readTarget, readMethod, readResult

local function ReadMethod()
  readResult = readTarget[readMethod]
end

local function Call(object, method)
  if not object then return nil end
  readTarget, readMethod, readResult = object, method, nil
  local ok = pcall(ReadMethod)
  local fn = readResult
  readTarget, readResult = nil, nil
  if not ok or type(fn) ~= "function" then return nil end
  local ok2, a, b, c, d = pcall(fn, object)
  if not ok2 then return nil end
  return a, b, c, d
end

local function ObjectType(object)
  local value = Call(object, "GetObjectType")
  if type(value) == "string" then return value end
  return nil
end

local function Clamp(value)
  if value < 0 then return 0 end
  if value > 1 then return 1 end
  return value
end

-- knowledge.json / core.getdifficultycolor_missing. Thresholds are Vanilla's;
-- only used when the native level fontstring has no colour to copy.
local function DifficultyColor(level)
  level = tonumber(level) or 0
  local playerLevel = ApiNumber("UnitLevel", "player") or 1

  if level <= 0 then return 0.69, 0.69, 0.69 end
  if level >= playerLevel + 5 then return 1.00, 0.10, 0.10 end
  if level >= playerLevel + 3 then return 1.00, 0.50, 0.10 end
  if level >= playerLevel - 2 then return 1.00, 1.00, 0.00 end
  if level > playerLevel - 8 then return 0.25, 0.75, 0.25 end
  return 0.50, 0.50, 0.50
end

-- Native plate art is silenced, not removed: IsShown() on the glow and the
-- elite icon stays the only readable signal for mouseover and classification.
-- rendering.native_texture_strip_requires_alpha is why the alpha is zeroed as
-- well as the texture cleared.
local function MuteTexture(region)
  if not region then return end
  pcall(function() region:SetTexture(nil) end)
  pcall(function() region:SetTexCoord(0, 0, 0, 0) end)
  pcall(function() region:SetAlpha(0) end)
end

local function MuteFontString(region)
  if not region then return end
  -- GetText() must keep working: the name and level are read back off these.
  pcall(function() region:SetAlpha(0) end)
end

-- A native bar frame plus its own regions: parent_alpha_not_propagated means
-- zeroing the frame alone is not enough to stop the fill drawing.
local function MuteBar(bar)
  if not bar then return end
  pcall(function() bar:SetStatusBarTexture(nil) end)
  pcall(function() bar:SetAlpha(0) end)

  local ok, regions = pcall(function() return { bar:GetRegions() } end)
  if not ok or type(regions) ~= "table" then return end
  local i
  for i = 1, table.getn(regions) do
    if ObjectType(regions[i]) == "Texture" then MuteTexture(regions[i]) end
  end
end

-- ---------------------------------------------------------------------------
-- Plate discovery
--
-- WORKING_SOURCE (UnrealPfUI modules/nameplates.lua): nameplates are anonymous
-- children of WorldFrame and appear as the child count grows. The *shape* test
-- upstream uses -- first region's texture is Interface\Tooltips\Nameplate-Border
-- -- is not reused, because this client's plate visibly is not Vanilla's.
-- Classification is structural instead.
-- ---------------------------------------------------------------------------
local registry = {}      -- native plate frame -> overlay
local plateOrder = {}    -- stable iteration order for the refresh pass
local scannedChildren = 0
local plateCount = 0

local stats = {
  worldChildren = 0,
  plates = 0,
  rejected = 0,
  withHealthBar = 0,
  detector = "none",
  -- Lowest and highest WorldFrame child count seen this session. This is the
  -- decisive measurement for whether nameplates are Lua frames here at all: if
  -- the count never moves while plates appear and disappear on screen, they are
  -- not WorldFrame children and no overlay approach can reach them.
  minChildren = -1,
  maxChildren = 0,
}

-- Why a WorldFrame child was not adopted. Measured first-pass result on this
-- client: 28 children, 0 plates, 28 rejected -- so the reason has to be
-- reportable rather than inferred from the layout not changing.
local rejectReasons = {}

local function Reject(reason)
  rejectReasons[reason] = (rejectReasons[reason] or 0) + 1
  return nil
end

local function IsNumericText(text)
  if type(text) ~= "string" then return false end
  return tonumber(text) ~= nil
end

-- The roll card is a WorldFrame child on this client (count grows when a roll
-- opens). ClassifyPlate then sees a StatusBar (the timer) plus a FontString
-- (the item name) and adopts it as healthbar+name. BuildOverlay parents a
-- QtUiPlus plate to that frame, so the bar moves with the card and paints
-- FormatHealthText("target") -- USER_CONFIRMED_INGAME, not a world nameplate.
-- Wiki GetName / GetParent: emberveil.org/wiki/lua/widgets/UIObject
-- Wiki GetPoint relative name: emberveil.org/wiki/lua/widgets/Region#getpoint
local function NameLooksLikeLootUi(name)
  if type(name) ~= "string" then return false end
  local lower = string.lower(name)
  if string.find(lower, "grouploot", 1, true) then return true end
  if string.find(lower, "lootframe", 1, true) then return true end
  if string.find(lower, "lootroll", 1, true) then return true end
  return false
end

local function HasLootRollChrome(frame)
  local ok, kids = pcall(function() return { frame:GetChildren() } end)
  if not ok or type(kids) ~= "table" then return false end
  local i
  for i = 1, table.getn(kids) do
    local childName = Call(kids[i], "GetName")
    if type(childName) == "string" then
      local lower = string.lower(childName)
      if string.find(lower, "greedbutton", 1, true) then return true end
      if string.find(lower, "rollbutton", 1, true) then return true end
      if string.find(lower, "needbutton", 1, true) then return true end
      if string.find(lower, "passbutton", 1, true) then return true end
    end
  end
  return false
end

local function IsLootUiPlate(frame)
  if not frame then return false end
  if NameLooksLikeLootUi(Call(frame, "GetName")) then return true end
  if HasLootRollChrome(frame) then return true end

  local parent = Call(frame, "GetParent")
  local depth = 0
  while parent and depth < 8 do
    if NameLooksLikeLootUi(Call(parent, "GetName")) then return true end
    parent = Call(parent, "GetParent")
    depth = depth + 1
  end

  if type(frame.GetPoint) == "function" then
    local ok, _, relName = pcall(frame.GetPoint, frame, 1)
    if ok and NameLooksLikeLootUi(relName) then return true end
  end
  return false
end

-- Sorts a plate's regions and children into the parts QtUiPlus needs. Returns
-- nil when the frame does not look like a nameplate at all.
-- Work counters, same purpose as core/compat.lua's: this client has no
-- intra-frame profiler, so the only way to attribute a spike to a subsystem is
-- to count what it did. classified is the expensive one -- ClassifyPlate walks
-- every region and child of a WorldFrame child, and a *rejected* child is never
-- cached, so it is re-classified in full on every rescan.
local statScans, statRescans, statClassified, statRefreshed = 0, 0, 0, 0

local function ClassifyPlate(frame)
  statClassified = statClassified + 1
  if IsLootUiPlate(frame) then return Reject("loot-ui") end
  -- The object type is recorded, not gated on. Measured: gating on
  -- Button/Frame plus "plates are anonymous" rejected all 28 WorldFrame
  -- children on this client -- and this runtime auto-names objects
  -- (GeneratedLuaUIObject_NNNN appears in frames.getpoint_relative_name_y
  -- _inverted), so a name-based filter cannot distinguish a plate from
  -- anything else here. Structure is the only usable signal.
  local ok, regions = pcall(function() return { frame:GetRegions() } end)
  if not ok or type(regions) ~= "table" then
    return Reject("no-getregions")
  end

  local parts = { textures = {}, fontstrings = {} }
  local i

  for i = 1, table.getn(regions) do
    local region = regions[i]
    local regionType = ObjectType(region)

    if regionType == "FontString" then
      table.insert(parts.fontstrings, region)
    elseif regionType == "Texture" then
      table.insert(parts.textures, region)

      local texture = Call(region, "GetTexture")
      if type(texture) == "string" then
        if string.find(texture, "Nameplate%-Border") then
          parts.border = region
        elseif string.find(texture, "Nameplate%-Glow") or
               string.find(texture, "Glow") then
          parts.glow = region
        elseif string.find(texture, "Elite") or string.find(texture, "Rare") then
          parts.levelicon = region
        elseif string.find(texture, "RaidTargetingIcon") then
          parts.raidicon = region
        end
      end
    end
  end

  local kidsOk, kids = pcall(function() return { frame:GetChildren() } end)
  if kidsOk and type(kids) == "table" then
    for i = 1, table.getn(kids) do
      local kid = kids[i]
      local kidType = ObjectType(kid)
      -- GetValue is the part that matters; the widget's reported type is not
      -- assumed to be "StatusBar" on this client.
      local hasValue = false
      pcall(function() hasValue = type(kid.GetValue) == "function" end)

      if kidType == "StatusBar" or hasValue then
        if not parts.healthbar then
          parts.healthbar = kid
        elseif not parts.castbar then
          parts.castbar = kid
        end
      end
    end
  end

  -- Accept on any of three independent signatures, so a Vanilla-shaped plate
  -- and this client's own shape both resolve. Which one matched is recorded for
  -- U.NameplateReport().
  --
  -- Each signature still demands a *combination*, never a single generic trait:
  -- adopting a plate mutes its native art for the rest of the session, so a
  -- false positive on some other WorldFrame child is not a cosmetic mistake.
  -- /qtp np dumps every child so the threshold can be checked against what is
  -- really there rather than loosened blind.
  local fontCount = table.getn(parts.fontstrings)

  local detector
  if parts.border then
    detector = "border-texture"
  elseif parts.healthbar and fontCount >= 1 then
    detector = "healthbar+name"
  elseif fontCount >= 2 then
    detector = "name+level-fontstrings"
  else
    return Reject("shape " .. tostring(ObjectType(frame)) ..
                  " tex=" .. table.getn(parts.textures) ..
                  " fs=" .. fontCount ..
                  " bar=" .. (parts.healthbar and "y" or "n"))
  end

  parts.detector = detector

  -- The level is whichever fontstring currently reads as a number; the name is
  -- the first one that is not it. Re-checked on refresh, because a plate is
  -- recycled onto a different unit without being rebuilt.
  local first, second = parts.fontstrings[1], parts.fontstrings[2]
  if IsNumericText(Call(first, "GetText")) and second then
    parts.level, parts.name = first, second
  else
    parts.name, parts.level = first, second
  end

  return parts
end

-- ---------------------------------------------------------------------------
-- Overlay construction
-- ---------------------------------------------------------------------------
local LayoutOverlay

local function BuildOverlay(frame, parts)
  plateCount = plateCount + 1

  local overlay = CreateFrame("Frame", "QtUiPlusNamePlate" .. plateCount, frame)
  overlay.plate = frame
  overlay.parts = parts
  overlay.cache = {}

  -- WORKING_SOURCE (UnrealPfUI): a WorldFrame-child overlay is scaled to the UI
  -- scale so plate sizes read in the same units as the rest of the addon.
  pcall(function() overlay:SetScale(UIParent:GetScale()) end)

  -- Size and pin the overlay before extras. If later construction errors,
  -- the plate still has a visible name/health row instead of a muted native
  -- plate with nothing on top.
  overlay:SetWidth(cfg.width)
  overlay:SetHeight(cfg.healthHeight + cfg.nameSize + 4)
  overlay:ClearAllPoints()
  overlay:SetPoint("TOP", frame, "TOP", 0, cfg.verticalOffset)

  local health = U.CreateStatusBar(overlay, {
    width = cfg.width,
    height = cfg.healthHeight,
    color = UNIT_COLOR.ENEMY,
    background = M.color.healthBg,
  })
  -- Border only: U.CreateStatusBar already owns the bar's background texture,
  -- so the full backdrop would just paint a second fill behind it.
  U.CreateBorder(health)
  U.SetBorderColor(health, M.Unpack(M.color.border))
  overlay.health = health
  health:SetPoint("BOTTOM", overlay, "BOTTOM", 0, 0)

  overlay.glow = overlay:CreateTexture(nil, "BACKGROUND")
  pcall(overlay.glow.SetTexture, overlay.glow, M.texture.plain)
  pcall(overlay.glow.SetVertexColor, overlay.glow, 1, 1, 1, 0.25)
  overlay.glow:Hide()

  overlay.healthText = U.CreateLabel(health, {
    size = cfg.healthTextSize,
    color = M.color.text,
    inherits = "GameFontNormal",
  })
  if overlay.healthText then
    overlay.healthText:SetPoint("CENTER", health, "CENTER", 0, 0)
  end

  overlay.name = U.CreateLabel(overlay, {
    size = cfg.nameSize,
    color = { 1, 1, 1, 1 },
    inherits = "GameFontNormal",
  })
  overlay.level = U.CreateLabel(overlay, {
    size = cfg.levelSize,
    color = { 1, 1, 1, 1 },
    inherits = "GameFontNormal",
  })

  pcall(function()
    overlay.raidicon = overlay:CreateTexture(nil, "OVERLAY")
    pcall(overlay.raidicon.SetTexture, overlay.raidicon, RAIDICON_TEXTURE)
    overlay.raidicon:Hide()

    overlay.castbar = U.CreateStatusBar(overlay, {
      width = cfg.width,
      height = cfg.castHeight or 8,
      color = { 0.90, 0.80, 0.00, 1 },
      background = M.color.healthBg,
    })
    U.CreateBorder(overlay.castbar)
    U.SetBorderColor(overlay.castbar, M.Unpack(M.color.border))
    overlay.castbar:Hide()
    overlay.castSpell = U.CreateLabel(overlay.castbar, {
      size = cfg.healthTextSize,
      color = { 1, 1, 1, 1 },
      inherits = "GameFontNormal",
    })
    if overlay.castSpell then
      overlay.castSpell:SetPoint("CENTER", overlay.castbar, "CENTER", 0, 0)
    end

    overlay.combopoints = {}
    local i
    for i = 1, 5 do
      local slot = CreateFrame("Frame", nil, overlay)
      slot:SetWidth(COMBO_SIZE)
      slot:SetHeight(COMBO_SIZE)
      U.CreateBackdrop(slot, {
        background = COMBO_COLOR[i],
        border = M.color.border,
      })
      slot:Hide()
      overlay.combopoints[i] = slot
    end

    overlay.debuffs = {}
    for i = 1, DEBUFF_MAX do
      local icon = CreateFrame("Frame", nil, overlay)
      icon:SetWidth(DEBUFF_SIZE)
      icon:SetHeight(DEBUFF_SIZE)
      U.CreateBackdrop(icon, {
        background = { 0.10, 0.10, 0.10, 0.80 },
        border = M.color.border,
      })
      local tex = icon:CreateTexture(nil, "ARTWORK")
      tex:SetPoint("TOPLEFT", icon, "TOPLEFT", 1, -1)
      tex:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", -1, 1)
      pcall(tex.SetTexCoord, tex, 0.08, 0.92, 0.08, 0.92)
      icon.tex = tex
      icon.stacks = U.CreateLabel(icon, {
        size = 10,
        color = { 1, 1, 0, 1 },
        inherits = "GameFontNormalSmall",
      })
      if icon.stacks then
        icon.stacks:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", -1, 1)
      end
      icon:Hide()
      overlay.debuffs[i] = icon
    end

    overlay.totem = CreateFrame("Frame", nil, overlay)
    overlay.totem:SetWidth(32)
    overlay.totem:SetHeight(32)
    U.CreateBackdrop(overlay.totem, {
      background = { 0.10, 0.10, 0.10, 0.80 },
      border = M.color.border,
    })
    overlay.totem.icon = overlay.totem:CreateTexture(nil, "ARTWORK")
    overlay.totem.icon:SetPoint("TOPLEFT", overlay.totem, "TOPLEFT", 1, -1)
    overlay.totem.icon:SetPoint("BOTTOMRIGHT", overlay.totem, "BOTTOMRIGHT", -1, 1)
    pcall(overlay.totem.icon.SetTexCoord, overlay.totem.icon, 0.08, 0.92, 0.08, 0.92)
    overlay.totem:Hide()
  end)

  pcall(LayoutOverlay, overlay)
  overlay:Show()
  overlay.qtpVisible = true
  return overlay
end

LayoutOverlay = function(overlay)
  if not overlay or not overlay.health then return end
  local width = tonumber(cfg.width) or 160
  local healthH = tonumber(cfg.healthHeight) or 17
  local castH = tonumber(cfg.castHeight) or 8
  local extra = 0
  if cfg.showCastbar then extra = extra + castH + 3 end
  if cfg.showCombo then extra = extra + COMBO_SIZE + 3 end
  if cfg.showDebuffs then extra = extra + DEBUFF_SIZE + 3 end

  overlay:SetWidth(width + 24)
  overlay:SetHeight((cfg.nameSize or 12) + 6 + healthH + extra)
  overlay:ClearAllPoints()
  overlay:SetPoint("TOP", overlay.plate, "TOP", 0, cfg.verticalOffset or 0)

  overlay.health:ClearAllPoints()
  overlay.health:SetWidth(width)
  overlay.health:SetHeight(healthH)
  overlay.health:SetPoint("TOP", overlay, "TOP", 0, -(cfg.nameSize + 2))
  if type(U.SizeStatusBar) == "function" then
    U.SizeStatusBar(overlay.health, width, healthH)
  end

  if overlay.glow then
    overlay.glow:ClearAllPoints()
    overlay.glow:SetPoint("TOPLEFT", overlay.health, "TOPLEFT", -8, 8)
    overlay.glow:SetPoint("BOTTOMRIGHT", overlay.health, "BOTTOMRIGHT", 8, -8)
  end

  if overlay.name then
    overlay.name:ClearAllPoints()
    overlay.name:SetPoint("BOTTOMLEFT", overlay.health, "TOPLEFT", 0, 2)
  end
  if overlay.level then
    overlay.level:ClearAllPoints()
    overlay.level:SetPoint("BOTTOMRIGHT", overlay.health, "TOPRIGHT", 0, 2)
  end

  if overlay.raidicon then
    overlay.raidicon:ClearAllPoints()
    overlay.raidicon:SetWidth(RAIDICON_SIZE)
    overlay.raidicon:SetHeight(RAIDICON_SIZE)
    overlay.raidicon:SetPoint("CENTER", overlay.health, "CENTER", 0, -5)
  end

  if overlay.castbar then
    overlay.castbar:ClearAllPoints()
    overlay.castbar:SetWidth(width)
    overlay.castbar:SetHeight(castH)
    overlay.castbar:SetPoint("TOPLEFT", overlay.health, "BOTTOMLEFT", 0, -3)
    if type(U.SizeStatusBar) == "function" then
      U.SizeStatusBar(overlay.castbar, width, castH)
    end
  end

  local i
  if overlay.combopoints then
    for i = 1, 5 do
      local slot = overlay.combopoints[i]
      if slot then
        slot:ClearAllPoints()
        slot:SetPoint("TOPRIGHT", overlay.health, "BOTTOMRIGHT",
                      -(i - 1) * (COMBO_SIZE + 3), -3)
      end
    end
  end

  if overlay.debuffs then
    for i = 1, DEBUFF_MAX do
      local icon = overlay.debuffs[i]
      if icon then
        icon:ClearAllPoints()
        if i == 1 then
          local anchor = overlay.health
          if cfg.showCastbar and overlay.castbar then anchor = overlay.castbar end
          icon:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -3)
        else
          icon:SetPoint("LEFT", overlay.debuffs[i - 1], "RIGHT", 2, 0)
        end
      end
    end
  end

  if overlay.totem then
    overlay.totem:ClearAllPoints()
    overlay.totem:SetPoint("CENTER", overlay, "CENTER", 0, 0)
  end
end

local function RelayoutAll()
  local i
  for i = 1, table.getn(plateOrder) do
    if plateOrder[i] then LayoutOverlay(plateOrder[i]) end
  end
end

local function MutePlateArt(parts)
  MuteTexture(parts.border)
  MuteTexture(parts.glow)
  MuteTexture(parts.raidicon)
  MuteFontString(parts.name)
  MuteFontString(parts.level)
  MuteBar(parts.healthbar)
  MuteBar(parts.castbar)

  -- Anything not classified above is stock art QtUiPlus is replacing. The elite
  -- icon is the one exception: it is muted but still read via IsShown().
  local i
  for i = 1, table.getn(parts.textures) do
    local region = parts.textures[i]
    if region ~= parts.border and region ~= parts.glow and
       region ~= parts.raidicon then
      MuteTexture(region)
    end
  end
  for i = 1, table.getn(parts.fontstrings) do
    MuteFontString(parts.fontstrings[i])
  end
end

local function AdoptPlate(frame)
  local parts = ClassifyPlate(frame)
  if not parts then
    stats.rejected = stats.rejected + 1
    return nil
  end

  -- Overlay first, mute second. Muting the native art before the overlay
  -- exists leaves a blank plate if BuildOverlay errors.
  local ok, overlay = pcall(BuildOverlay, frame, parts)
  if not ok or not overlay then
    U.Debug("nameplate overlay: " .. tostring(overlay))
    stats.rejected = stats.rejected + 1
    return nil
  end

  MutePlateArt(parts)

  registry[frame] = overlay
  table.insert(plateOrder, overlay)

  stats.plates = stats.plates + 1
  stats.detector = parts.detector
  if parts.healthbar then stats.withHealthBar = stats.withHealthBar + 1 end

  return overlay
end

local function ScanWorldFrame()
  local worldFrame = U.G("WorldFrame")
  if not worldFrame then return end

  local count = tonumber(Call(worldFrame, "GetNumChildren"))
  if not count then return end
  stats.worldChildren = count
  if stats.minChildren < 0 or count < stats.minChildren then
    stats.minChildren = count
  end
  if count > stats.maxChildren then stats.maxChildren = count end

  -- Vanilla never destroys a plate, but a shrinking count would leave the
  -- cursor past the end, so fall back to a full re-scan instead of trusting it.
  if count < scannedChildren then
    scannedChildren = 0
    statRescans = statRescans + 1
  end
  if count == scannedChildren then return end

  statScans = statScans + 1

  local ok, kids = pcall(function() return { worldFrame:GetChildren() } end)
  if not ok or type(kids) ~= "table" then return end

  local i
  for i = scannedChildren + 1, count do
    local child = kids[i]
    if child and not registry[child] then
      local adopted, err = pcall(AdoptPlate, child)
      if not adopted then U.Debug("nameplate adopt: " .. tostring(err)) end
    end
  end

  scannedChildren = count
end

-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------

-- Health for one plate. The native bar is the only source that works for a mob
-- that is neither targeted nor moused over, and on this client it may report a
-- 0..100 scale rather than real hitpoints -- which is exactly why the readout
-- is a percentage.
local function ReadHealth(overlay)
  local bar = overlay.parts.healthbar
  if bar then
    local value = tonumber(Call(bar, "GetValue"))
    local minimum, maximum = Call(bar, "GetMinMaxValues")
    minimum, maximum = tonumber(minimum), tonumber(maximum)
    if value and maximum and maximum > 0 then
      return value, (minimum or 0), maximum
    end
  end

  -- No usable native bar: the unit API can still answer for the target.
  if overlay.isTarget then
    local hp = ApiNumber("UnitHealth", "target")
    local hpMax = ApiNumber("UnitHealthMax", "target")
    if hp and hpMax and hpMax > 0 then return hp, 0, hpMax end
  end

  return nil
end

-- Screen rectangle. Wiki: emberveil.org/wiki/lua/widgets/Region#getleft
-- (also GetRight / GetTop / GetBottom). Bottom-left origin, Y up.
local function ScreenRect(object)
  local left = tonumber(Call(object, "GetLeft"))
  local right = tonumber(Call(object, "GetRight"))
  local top = tonumber(Call(object, "GetTop"))
  local bottom = tonumber(Call(object, "GetBottom"))
  if not left or not right or not top or not bottom then return nil end
  return { left = left, right = right, top = top, bottom = bottom }
end

local function RectsOverlap(a, b)
  if not a or not b then return false end
  if a.right <= b.left or a.left >= b.right then return false end
  if a.top <= b.bottom or a.bottom >= b.top then return false end
  return true
end

-- GroupLootFrame sits on UIParent. Nameplate overlays are WorldFrame children
-- and draw over FULLSCREEN_DIALOG, so strata cannot cover this. A live target
-- plate (fully opaque, "1.7k - 95%" / "Dead") is not caught by the gone-plate
-- gate -- hide the overlay while it overlaps a shown roll card instead.
local function CollectRollRects()
  local rects = {}
  local i
  for i = 1, 4 do
    local frame = U.G("GroupLootFrame" .. i)
    if frame and Call(frame, "IsShown") then
      local rect = ScreenRect(frame)
      if rect then table.insert(rects, rect) end
    end
  end
  return rects
end

local function OverlapsRoll(overlay, rollRects)
  if not rollRects or table.getn(rollRects) == 0 then return false end
  local rect = ScreenRect(overlay) or ScreenRect(overlay.plate)
  if not rect then return false end
  local i
  for i = 1, table.getn(rollRects) do
    if RectsOverlap(rect, rollRects[i]) then return true end
  end
  return false
end

local function RefreshPlate(overlay, rollRects)
  local parts = overlay.parts
  local plate = overlay.plate

  -- A plate that is gone must take its overlay with it.
  --
  -- USER_CONFIRMED_INGAME: a bar reading "Dead", with the target's accent
  -- border, sat on screen over whatever opened there -- the loot roll window,
  -- both while that window was skinned and after the skin was removed, which is
  -- what kept the hunt pointed at the wrong module. It is this overlay, left
  -- behind. It was Show()n once at construction and never hidden again: this
  -- gate used to `return` on an invisible plate, which only skips the *update*,
  -- so the frame kept drawing its last name, last health value and last text.
  -- A mob dies right before a roll window opens, so "Dead" is exactly what it
  -- was frozen on.
  --
  -- Alpha counts as gone as well. This client does not Hide() its plates
  -- (see the header note), and the target-detection below rests on the client
  -- fading non-target plates, so a plate faded all the way out is hidden as far
  -- as the player is concerned even though IsVisible still reports true. Only
  -- ~zero counts: a partly faded plate is a normal, live one.
  --
  -- A *live* target plate is fully opaque, so that gate never fires -- and
  -- WorldFrame children paint over the roll card regardless of its strata.
  -- Overlap with a shown GroupLootFrame is the other "gone" case.
  -- Wiki Hide: emberveil.org/wiki/lua/widgets/Region#hide
  -- Already-adopted roll-card overlays stay hidden. Rejecting in ClassifyPlate
  -- only stops new ones; this client never forgets a plate once it is in
  -- plateOrder.
  if IsLootUiPlate(plate) then
    if overlay.qtpVisible ~= false then
      overlay.qtpVisible = false
      pcall(overlay.Hide, overlay)
    end
    return
  end

  local visible = Call(plate, "IsVisible")
  local plateAlpha = tonumber(Call(plate, "GetAlpha")) or 1
  if not visible or plateAlpha <= 0.01 or OverlapsRoll(overlay, rollRects) then
    if overlay.qtpVisible ~= false then
      overlay.qtpVisible = false
      pcall(overlay.Hide, overlay)
    end
    return
  end
  if overlay.qtpVisible == false then
    overlay.qtpVisible = true
    -- The fade pass below is cached; clear it so it reapplies on the way back.
    overlay.cache.alpha = nil
    pcall(overlay.Show, overlay)
  end

  -- Re-resolve which fontstring is the level: plates are recycled onto new
  -- units, and a name that happens to be numeric is not worth guarding against
  -- once, only every pass.
  local a, b = parts.fontstrings[1], parts.fontstrings[2]
  if b then
    if IsNumericText(Call(a, "GetText")) then
      parts.level, parts.name = a, b
    else
      parts.name, parts.level = a, b
    end
  end

  local name = Call(parts.name, "GetText")
  local levelText = Call(parts.level, "GetText")

  -- WORKING_SOURCE (UnrealPfUI): with no per-plate unit token, the current
  -- target's plate is the fully opaque one.
  local hasTarget = ApiTruth("UnitExists", "target")
  overlay.isTarget = hasTarget and plateAlpha >= 1 and true or false

  -- Name
  if overlay.name and name ~= overlay.cache.name then
    overlay.cache.name = name
    overlay.name:SetText(name or "")
  end

  -- Level, with the stock elite/rare marker kept as a suffix. A plate that
  -- carries no level fontstring at all gets a blank slot rather than "??" --
  -- the target layout is a name row with nothing else in it, not an error.
  if overlay.level then
    local suffix = ""
    if parts.levelicon and Call(parts.levelicon, "IsShown") then suffix = "+" end

    local text = ""
    if parts.level then text = (levelText or "??") .. suffix end
    if text ~= overlay.cache.level then
      overlay.cache.level = text
      overlay.level:SetText(text)

      local r, g, b2 = Call(parts.level, "GetTextColor")
      if type(r) == "number" and type(g) == "number" and type(b2) == "number" then
        -- UnrealPfUI lifts the stock level colour by .3 so it stays legible
        -- against the world rather than the stock plate's dark backing.
        r, g, b2 = Clamp(r + 0.3), Clamp(g + 0.3), Clamp(b2 + 0.3)
      else
        r, g, b2 = DifficultyColor(levelText)
      end
      pcall(overlay.level.SetTextColor, overlay.level, r, g, b2, 1)
    end
  end

  -- Health
  local value, minimum, maximum = ReadHealth(overlay)
  if value then
    overlay.health:Show()
    overlay.health:SetMinMaxValues(minimum, maximum)
    overlay.health:SetValue(value)

    if overlay.healthText then
      local text = ""
      if cfg.showHealthText and maximum > minimum then
        local formatted
        if overlay.isTarget and type(U.FormatHealthText) == "function" then
          formatted = U.FormatHealthText("target")
        end
        if formatted ~= nil then
          text = formatted
        else
          local perc = (value - minimum) / (maximum - minimum) * 100
          text = string.format("%.1f%%", perc)
        end
      end
      overlay.healthText:SetText(text)
    end
  else
    -- No health data at all: a name/level row on its own beats an empty bar.
    overlay.health:Hide()
    if overlay.healthText then overlay.healthText:SetText("") end
  end

  -- Bar colour from the native bar's tint, which is the only unit-type signal
  -- available for a plate that is not the target.
  local r, g, b2 = Call(parts.healthbar, "GetStatusBarColor")
  local unitType = UnitTypeFromBarColor(r, g, b2)

  if not unitType and overlay.isTarget then
    if ApiTruth("UnitIsPlayer", "target") and
       not ApiTruth("UnitCanAttack", "player", "target") then
      unitType = "FRIENDLY_UNIT"
    else
      local reaction = ApiNumber("UnitReaction", "target", "player")
      if reaction then
        if reaction <= 3 then unitType = "ENEMY"
        elseif reaction == 4 then unitType = "NEUTRAL"
        else unitType = "FRIENDLY_NPC" end
      end
    end
  end

  unitType = unitType or "ENEMY"
  if unitType ~= overlay.cache.unitType then
    overlay.cache.unitType = unitType
    U.SetStatusBarColor(overlay.health, M.Unpack(UNIT_COLOR[unitType]))
  end

  -- Target emphasis: the accent border, and everything else dimmed.
  local wantAlpha = 1
  if cfg.fadeOthers and hasTarget and not overlay.isTarget then
    wantAlpha = cfg.otherAlpha
  end
  if wantAlpha ~= overlay.cache.alpha then
    overlay.cache.alpha = wantAlpha
    pcall(overlay.SetAlpha, overlay, wantAlpha)
  end

  local borderKey = overlay.isTarget and "target" or "normal"
  if borderKey ~= overlay.cache.border then
    overlay.cache.border = borderKey
    if overlay.isTarget then
      U.SetBorderColor(overlay.health, M.Unpack(M.color.accent))
    else
      U.SetBorderColor(overlay.health, M.Unpack(M.color.border))
    end
  end

  -- Target glow, raid icon, cast, combo, debuffs, totems. Isolated so a
  -- failure here cannot blank the name/health row.
  pcall(function()
  -- Target glow (pfUI targetglow).
  if overlay.glow then
    if cfg.targetGlow and overlay.isTarget then
      overlay.glow:Show()
    else
      overlay.glow:Hide()
    end
  end

  -- Class colour on the current target only: no SuperWoW name cache here.
  if cfg.classColor and overlay.isTarget and ApiTruth("UnitIsPlayer", "target") then
    local classFn = U.G("UnitClass")
    if type(classFn) == "function" then
      local ok, _, token = pcall(classFn, "target")
      local colors = U.G("RAID_CLASS_COLORS")
      if ok and type(token) == "string" and type(colors) == "table" and
         type(colors[token]) == "table" then
        local c = colors[token]
        U.SetStatusBarColor(overlay.health, c.r, c.g, c.b, 1)
        overlay.cache.unitType = nil
      end
    end
  elseif overlay.isTarget and ApiTruth("UnitIsTapped", "target") and
         not ApiTruth("UnitIsTappedByPlayer", "target") then
    U.SetStatusBarColor(overlay.health, 0.5, 0.5, 0.5, 1)
    overlay.cache.unitType = nil
  end

  -- Totem / critter plates. Wiki UnitName for the target name check only.
  local totemTex = TotemIcon(name)
  if overlay.totem then
    if cfg.totemIcons and totemTex then
      pcall(overlay.totem.icon.SetTexture, overlay.totem.icon,
            "Interface\\Icons\\" .. totemTex)
      overlay.totem:Show()
      overlay.health:Hide()
      if overlay.name then overlay.name:Hide() end
      if overlay.level then overlay.level:Hide() end
      if overlay.castbar then overlay.castbar:Hide() end
      if overlay.raidicon then overlay.raidicon:Hide() end
    else
      overlay.totem:Hide()
      if overlay.name then overlay.name:Show() end
      if overlay.level then overlay.level:Show() end
    end
  end
  if (cfg.hideTotems and totemTex and not cfg.totemIcons) or
     (cfg.hideCritters and IsCritterName(name)) then
    if overlay.health then overlay.health:Hide() end
  end

  local totemMode = cfg.totemIcons and totemTex and true or false

  -- Native raid icon region is muted but still reports IsShown / tex coords.
  if overlay.raidicon and not totemMode then
    local native = parts.raidicon
    if cfg.showRaidIcon and native and Call(native, "IsShown") then
      overlay.raidicon:Show()
      local ok, u1, v1, u2, v2 = pcall(function()
        return native:GetTexCoord()
      end)
      if ok and u1 then
        pcall(overlay.raidicon.SetTexCoord, overlay.raidicon, u1, v1, u2, v2)
      end
    else
      overlay.raidicon:Hide()
    end
  end

  -- Cast bar: native plate child, plus UnitCastingInfo on the target if present.
  local casting = false
  local castName, castCur, castMax
  if cfg.showCastbar and not totemMode then
    local nativeCast = parts.castbar
    if nativeCast and Call(nativeCast, "IsShown") then
      local cur = tonumber(Call(nativeCast, "GetValue"))
      local cmin, cmax = Call(nativeCast, "GetMinMaxValues")
      cmin, cmax = tonumber(cmin), tonumber(cmax)
      if cur and cmax and cmax > (cmin or 0) then
        casting, castCur, castMax = true, cur, cmax
      end
    end
    if not casting and overlay.isTarget then
      local info = U.G("UnitCastingInfo") or U.G("UnitChannelInfo")
      if type(info) ~= "function" then info = U.G("UnitChannelInfo") end
      if type(info) == "function" then
        local ok, spell, _, _, _, startTime, endTime = pcall(info, "target")
        if not ok or not spell then
          local channel = U.G("UnitChannelInfo")
          if type(channel) == "function" then
            ok, spell, _, _, _, startTime, endTime = pcall(channel, "target")
          end
        end
        if ok and spell and tonumber(startTime) and tonumber(endTime) then
          local now = 0
          local gt = U.G("GetTime")
          if type(gt) == "function" then
            local tOk, t = pcall(gt)
            if tOk then now = tonumber(t) or 0 end
          end
          castName = spell
          castMax = (endTime - startTime) / 1000
          castCur = now - startTime / 1000
          if castMax > 0 then casting = true end
        end
      end
    end
  end
  if overlay.castbar then
    if casting then
      overlay.castbar:Show()
      overlay.castbar:SetMinMaxValues(0, castMax)
      overlay.castbar:SetValue(castCur)
      if overlay.castSpell then overlay.castSpell:SetText(castName or "") end
    else
      overlay.castbar:Hide()
      if overlay.castSpell then overlay.castSpell:SetText("") end
    end
  end

  -- Combo points: documented no-arg GetComboPoints, only on the current target.
  local points = 0
  if cfg.showCombo and overlay.isTarget and not totemMode then points = ComboCount() end
  if overlay.combopoints then
    local i
    for i = 1, 5 do
      if overlay.combopoints[i] then
        if i <= points then overlay.combopoints[i]:Show()
        else overlay.combopoints[i]:Hide() end
      end
    end
  end

  -- Debuffs only while we have a UnitID. Wiki UnitDebuff: texture, stacks.
  local unitstr
  if overlay.isTarget then
    local targetName = ApiString("UnitName", "target")
    if targetName and targetName == name then unitstr = "target" end
  elseif ApiTruth("UnitExists", "mouseover") and parts.glow and
         Call(parts.glow, "IsShown") then
    local moName = ApiString("UnitName", "mouseover")
    if moName and moName == name then unitstr = "mouseover" end
  end
  local shownDebuffs = 0
  if cfg.showDebuffs and unitstr and overlay.debuffs and not totemMode then
    local i
    for i = 1, DEBUFF_MAX do
      local texture, stacks = DebuffIcon(unitstr, i)
      local icon = overlay.debuffs[i]
      if icon and texture then
        shownDebuffs = shownDebuffs + 1
        pcall(icon.tex.SetTexture, icon.tex, texture)
        if icon.stacks then
          if stacks > 1 then icon.stacks:SetText(tostring(stacks))
          else icon.stacks:SetText("") end
        end
        if i == 1 then
          local anchor = overlay.health
          if casting and overlay.castbar then anchor = overlay.castbar end
          icon:ClearAllPoints()
          icon:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -3)
        end
        icon:Show()
      elseif icon then
        icon:Hide()
      end
    end
  elseif overlay.debuffs then
    local i
    for i = 1, DEBUFF_MAX do
      if overlay.debuffs[i] then overlay.debuffs[i]:Hide() end
    end
  end
  end)
end

local function RefreshAll()
  statRefreshed = statRefreshed + 1
  local rollRects = CollectRollRects()
  local i
  for i = 1, table.getn(plateOrder) do
    local overlay = plateOrder[i]
    if overlay then
      local ok, err = pcall(RefreshPlate, overlay, rollRects)
      if not ok then U.Debug("nameplate refresh: " .. tostring(err)) end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Diagnostics
--
-- The detection path above is WORKING_SOURCE, not measured. This is what turns
-- one in-game run into the evidence that closes the gap.
-- ---------------------------------------------------------------------------
-- Read by core/perf.lua's export alongside U.SuppressionStats.
function U.NameplateStats()
  return {
    scans = statScans,
    rescans = statRescans,
    classified = statClassified,
    refreshPasses = statRefreshed,
    plates = plateCount,
    worldChildren = stats.worldChildren,
    minChildren = stats.minChildren,
    maxChildren = stats.maxChildren,
  }
end

function U.NameplateReport()
  local report = {
    enabled = cfg.enabled,
    worldChildren = stats.worldChildren,
    scanned = scannedChildren,
    plates = stats.plates,
    rejected = stats.rejected,
    withHealthBar = stats.withHealthBar,
    detector = stats.detector,
    minChildren = stats.minChildren,
    maxChildren = stats.maxChildren,
  }

  -- First live plate, described part by part.
  local i
  for i = 1, table.getn(plateOrder) do
    local overlay = plateOrder[i]
    if overlay and Call(overlay.plate, "IsVisible") then
      local parts = overlay.parts
      report.sample = {
        frameType = ObjectType(overlay.plate),
        regions = table.getn(parts.textures) + table.getn(parts.fontstrings),
        textures = table.getn(parts.textures),
        fontstrings = table.getn(parts.fontstrings),
        name = Call(parts.name, "GetText"),
        level = Call(parts.level, "GetText"),
        hasHealthBar = parts.healthbar and true or false,
        hasCastBar = parts.castbar and true or false,
        hasBorder = parts.border and true or false,
        hasGlow = parts.glow and true or false,
        isTarget = overlay.isTarget,
      }

      local value, minimum, maximum = ReadHealth(overlay)
      report.sample.health = value
      report.sample.healthMin = minimum
      report.sample.healthMax = maximum

      -- The raw tint is printed when it does not map to a known unit type: an
      -- unrecognised triple is the thing that would silently colour every plate
      -- hostile, so it has to be readable rather than inferred.
      local r, g, b = Call(parts.healthbar, "GetStatusBarColor")
      local mapped = UnitTypeFromBarColor(r, g, b)
      if mapped then
        report.sample.barColor = mapped
      elseif type(r) == "number" and type(g) == "number" and type(b) == "number" then
        report.sample.barColor = string.format("unmapped %.2f,%.2f,%.2f", r, g, b)
      else
        report.sample.barColor = "none"
      end
      break
    end
  end

  report.rejectReasons = rejectReasons
  return report
end

-- Raw description of every WorldFrame child, whether or not it was adopted.
--
-- The first in-game run reported 28 children and 0 plates, which says the
-- signature is wrong but not how. This is the readout that answers it: object
-- type, region and child composition, the texture paths and the fontstring
-- text actually present. It reads only -- nothing here mutes or adopts.
function U.NameplateDump()
  local out = {}

  local worldFrame = U.G("WorldFrame")
  if not worldFrame then return out end

  local count = tonumber(Call(worldFrame, "GetNumChildren")) or 0
  local ok, kids = pcall(function() return { worldFrame:GetChildren() } end)
  if not ok or type(kids) ~= "table" then return out end

  local i, j
  for i = 1, count do
    local child = kids[i]
    if child then
      local entry = {
        index = i,
        otype = ObjectType(child) or "?",
        name = Call(child, "GetName"),
        visible = Call(child, "IsVisible") and true or false,
        width = tonumber(Call(child, "GetWidth")),
        height = tonumber(Call(child, "GetHeight")),
        adopted = registry[child] and true or false,
        textures = 0,
        fontstrings = 0,
        children = 0,
        texturePaths = {},
        texts = {},
        childTypes = {},
      }

      local rOk, regions = pcall(function() return { child:GetRegions() } end)
      if rOk and type(regions) == "table" then
        for j = 1, table.getn(regions) do
          local regionType = ObjectType(regions[j])
          if regionType == "Texture" then
            entry.textures = entry.textures + 1
            local path = Call(regions[j], "GetTexture")
            if type(path) == "string" and table.getn(entry.texturePaths) < 4 then
              -- Only the tail is useful and chat lines are short.
              table.insert(entry.texturePaths, string.sub(path, -28))
            end
          elseif regionType == "FontString" then
            entry.fontstrings = entry.fontstrings + 1
            local text = Call(regions[j], "GetText")
            if type(text) == "string" and table.getn(entry.texts) < 3 then
              table.insert(entry.texts, text)
            end
          end
        end
      end

      local cOk, subs = pcall(function() return { child:GetChildren() } end)
      if cOk and type(subs) == "table" then
        entry.children = table.getn(subs)
        for j = 1, entry.children do
          if table.getn(entry.childTypes) < 3 then
            local hasValue = false
            pcall(function() hasValue = type(subs[j].GetValue) == "function" end)
            table.insert(entry.childTypes,
              (ObjectType(subs[j]) or "?") .. (hasValue and "*" or ""))
          end
        end
      end

      table.insert(out, entry)
    end
  end

  return out
end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------
local BOOL_KEYS = {
  enabled = true, showHealthText = true, fadeOthers = true, showCastbar = true,
  showDebuffs = true, showCombo = true, showRaidIcon = true, targetGlow = true,
  hideTotems = true, totemIcons = true, hideCritters = true, classColor = true,
}

local function ClampSetting(name, value)
  local limit = LIMITS[name]
  value = tonumber(value)
  if not limit then return value end
  if not value then return limit.min end
  value = U.Round(value)
  if value < limit.min then value = limit.min end
  if value > limit.max then value = limit.max end
  return value
end

local function StartScan()
  U.RegisterUpdate("nameplates.scan", 0.1, function()
    if U.PerfDisabled and U.PerfDisabled("plates") then return end
    ScanWorldFrame()
    RefreshAll()
  end)
end

function U.GetNameplateSetting(name)
  if not cfg then return nil end
  if BOOL_KEYS[name] then return cfg[name] and true or false end
  return ClampSetting(name, cfg[name])
end

function U.SetNameplateSetting(name, value)
  if not cfg then return nil end
  if BOOL_KEYS[name] then
    cfg[name] = value and true or false
  elseif LIMITS[name] then
    cfg[name] = ClampSetting(name, value)
  else
    return nil
  end
  if name == "enabled" then
    if cfg.enabled then
      StartScan()
    else
      U.UnregisterUpdate("nameplates.scan")
      local i
      for i = 1, table.getn(plateOrder) do
        if plateOrder[i] then pcall(plateOrder[i].Hide, plateOrder[i]) end
      end
    end
  else
    RelayoutAll()
  end
  return U.GetNameplateSetting(name)
end

local NP_CHECKS = {
  { key = "enabled",        text = "Enable nameplates" },
  { key = "showHealthText", text = "Show health text" },
  { key = "fadeOthers",     text = "Fade non-target plates" },
  { key = "showCastbar",    text = "Show cast bar" },
  { key = "showDebuffs",    text = "Show target / mouseover debuffs" },
  { key = "showCombo",      text = "Show combo points on the target" },
  { key = "showRaidIcon",   text = "Show raid target icon" },
  { key = "targetGlow",     text = "Glow the current target" },
  { key = "classColor",     text = "Class colour on player targets" },
  { key = "hideTotems",     text = "Hide totem plates" },
  { key = "totemIcons",     text = "Replace totems with their icon" },
  { key = "hideCritters",   text = "Hide critter health bars" },
}

local NP_SLIDERS = {
  { key = "width",        text = "Width" },
  { key = "healthHeight", text = "Health height" },
  { key = "castHeight",   text = "Cast height" },
}

local function BuildSettingsPage(parent)
  local widgets, controls = {}, {}

  local header = U.CreateSectionHeader(parent, {
    text = "Nameplates", width = 484, y = -4,
  })
  table.insert(widgets, header)

  local i
  for i = 1, table.getn(NP_CHECKS) do
    local spec = NP_CHECKS[i]
    local box = U.CreateCheckbox(parent, {
      name = "QtUiPlusNP" .. spec.key,
      text = spec.text,
      value = U.GetNameplateSetting(spec.key),
      onChange = function(value) U.SetNameplateSetting(spec.key, value) end,
    })
    box.SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -28 - (i - 1) * 22)
    controls[spec.key] = box
    table.insert(widgets, box)
  end

  local checkCount = table.getn(NP_CHECKS)
  for i = 1, table.getn(NP_SLIDERS) do
    local spec = NP_SLIDERS[i]
    local limit = LIMITS[spec.key]
    local slider = U.CreateSlider(parent, {
      name = "QtUiPlusNP" .. spec.key,
      text = spec.text,
      width = 200,
      min = limit.min, max = limit.max, step = limit.step,
      value = U.GetNameplateSetting(spec.key),
      onChange = function(value) U.SetNameplateSetting(spec.key, value) end,
    })
    slider.SetPoint("TOPLEFT", parent, "TOPLEFT", 0,
                    -28 - checkCount * 22 - 16 - (i - 1) * 44)
    controls[spec.key] = slider
    table.insert(widgets, slider)
  end

  local function Refresh()
    local j
    for j = 1, table.getn(NP_CHECKS) do
      local key = NP_CHECKS[j].key
      if controls[key] then controls[key].SetValue(U.GetNameplateSetting(key)) end
    end
    for j = 1, table.getn(NP_SLIDERS) do
      local key = NP_SLIDERS[j].key
      if controls[key] then controls[key].SetValue(U.GetNameplateSetting(key)) end
    end
  end

  return widgets, Refresh
end

-- ---------------------------------------------------------------------------
-- Module lifecycle
-- ---------------------------------------------------------------------------
function NP:OnInit()
  cfg = U.ModuleConfig("nameplates", defaults)
  if type(U.RegisterSettingsTab) == "function" then
    U.RegisterSettingsTab("nameplates", "Nameplates", BuildSettingsPage)
  end
end

function NP:OnEnable()
  if not cfg then cfg = U.ModuleConfig("nameplates", defaults) end
  if not cfg.enabled then return end

  -- Discovery is cheap while the child count is unchanged, so it can share the
  -- refresh tick. 0.1s keeps a new plate from lagging visibly behind the stock
  -- one it replaces.
  StartScan()
end
