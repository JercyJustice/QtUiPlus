-- QtUiPlus :: modules/damagemeter.lua
--
-- Segmented damage/healing meter with per-fight drilldown, ported from QtUI
-- DamageMeter.lua. The combat-log parse is ShaguDPS's, which is locale
-- independent on 1.12 -- it keys off the event token rather than the message
-- text, so it does not need a translated pattern table per client language.
--
-- PORTED AS-IS, deliberately. Two things constrain edits to this file:
--
--  1. Top-level local budget. Lua 5.1 allows 200 local variables per chunk and
--     this file sits at exactly 200 -- the cap, zero headroom. Anything added
--     therefore be a field on an existing table, not a new `local` -- which is
--     why the module registration at the very bottom hangs off QtP rather than
--     binding `local U = QtUiPlus` the way every other QtUiPlus module does.
--
--  2. Handler globals. The handlers below read `this`, `event` and `arg1`
--     directly instead of going through the QtUiPlus dispatcher. core/init.lua
--     documents that this client does not consistently populate those for
--     OnEvent and may pass arguments directly -- but it also records a measured
--     probe showing OnUpdate delivers its delta *only* through the legacy arg1
--     global, and this exact code is what QtUI runs in production on this same
--     client today. Rewriting 75 handler-global reads against an ambiguity that
--     working code already resolves would trade a known-good path for an
--     untested one, so the handlers stand.
--
-- Everything else is a mechanical QtUI -> QtP rename onto core/qtcompat.lua.


local MAX_BARS = 16
local MIN_BARS = 3
local HEADER_PAD = 4
local BTN = 13
local TITLE_H = 19
local METER_PAD = 6

local CLASS_COLORS = {
  WARRIOR = { .78, .61, .43 }, MAGE = { .41, .80, .94 }, ROGUE = { 1, .96, .41 },
  DRUID = { 1, .49, .04 }, HUNTER = { .67, .83, .45 }, SHAMAN = { .14, .35, 1 },
  PRIEST = { 1, 1, 1 }, WARLOCK = { .58, .51, .79 }, PALADIN = { .96, .55, .73 },
}

local INTERNALS = {
  _sum = true, _ctime = true, _tick = true, _esum = true, _effective = true,
  _hits = true, _crits = true, _targets = true,
}

local data = {
  damage = { [0] = {}, [1] = {} },
  heal = { [0] = {}, [1] = {} },
  classes = {},
}

local MAX_FIGHTS = 20
local history = {}
local viewing
local fightDests = {}
local fightDeaths = {}
local fightPullName
local fightStart
local lastFightDuration
local startNextSegment
local PersistMeters
local LoadMeterState
local ShowBarTooltip
local parser = CreateFrame("Frame", "QtPDamageParser")

local validUnits = { player = true }
local validPets = { pet = true }
do
  local i
  for i = 1, 4 do
    validUnits["party" .. i] = true
    validPets["partypet" .. i] = true
  end
  for i = 1, 40 do
    validUnits["raid" .. i] = true
    validPets["raidpet" .. i] = true
  end
end

local function Trim(str)
  return string.gsub(str, "^%s*(.-)%s*$", "%1")
end

local function Round(input, places)
  if type(input) ~= "number" then return 0 end
  places = places or 0
  local pow = 1
  local i
  for i = 1, places do pow = pow * 10 end
  return math.floor(input * pow + .5) / pow
end

local function AnyInCombat()
  if UnitAffectingCombat("player") or UnitAffectingCombat("pet") then return true end
  local raid = tonumber(GetNumRaidMembers()) or 0
  local group = tonumber(GetNumPartyMembers()) or 0
  local i
  if raid >= 1 then
    for i = 1, raid do
      if UnitAffectingCombat("raid" .. i) or UnitAffectingCombat("raidpet" .. i) then return true end
    end
  else
    for i = 1, group do
      if UnitAffectingCombat("party" .. i) or UnitAffectingCombat("partypet" .. i) then return true end
    end
  end
  return nil
end

local SELF_TOKENS = {
  you = true, your = true, yourself = true,
  ihr = true, euer = true, eure = true, euch = true,
}

local function StripMarkup(str)
  if type(str) ~= "string" then return str end
  str = string.gsub(str, "|c%x%x%x%x%x%x%x%x", "")
  str = string.gsub(str, "|r", "")
  str = string.gsub(str, "|H.-|h%[(.-)%]|h", "%1")
  str = string.gsub(str, "|H.-|h(.-)|h", "%1")
  return str
end

local function ResolveName(name)
  if type(name) ~= "string" then return name end
  name = Trim(StripMarkup(name))
  if SELF_TOKENS[string.lower(name)] then
    return UnitName("player") or name
  end
  return name
end

local function ScanName(name)
  name = ResolveName(name)
  if not name then return nil end
  local unit
  for unit in pairs(validUnits) do
    if UnitExists(unit) and UnitName(unit) == name and UnitIsPlayer(unit) then
      local _, class = UnitClass(unit)
      data.classes[name] = class
      return "PLAYER"
    end
  end
  local match, _, owner = string.find(name, "%((.*)%)", 1)
  if match and owner and ScanName(owner) == "PLAYER" then
    data.classes[name] = owner
    return "PET"
  end
  for unit in pairs(validPets) do
    if UnitExists(unit) and UnitName(unit) == name then
      if string.sub(unit, 1, 3) == "pet" then
        data.classes[name] = UnitName("player")
      elseif string.sub(unit, 1, 8) == "partypet" then
        data.classes[name] = UnitName("party" .. string.sub(unit, 9))
      elseif string.sub(unit, 1, 7) == "raidpet" then
        data.classes[name] = UnitName("raid" .. string.sub(unit, 8))
      end
      return "PET"
    end
  end
  return nil
end

local function MarkMetersDirty()
  if QtP.meterFrames then
    local i
    for i = 1, table.getn(QtP.meterFrames) do
      QtP.meterFrames[i].dirty = true
    end
    return
  end
  if QtP.meterFrame then QtP.meterFrame.dirty = true end
end

local function EnsureRowExtras(row)
  if not row._hits then row._hits = {} end
  if not row._crits then row._crits = {} end
  if not row._targets then row._targets = {} end
end

local function AddData(source, action, target, value, school, datatype, crit)
  if type(source) ~= "string" then return end
  if not tonumber(value) then return end
  if not datatype then datatype = "damage" end
  source = ResolveName(source)
  if type(target) == "string" then target = ResolveName(target) end
  if type(action) == "string" then action = StripMarkup(action) end
  if datatype == "damage" and source == target then return end

  if startNextSegment and data.classes[source] and data.classes[source] ~= "__other__" then
    data.damage[1] = {}
    data.heal[1] = {}
    startNextSegment = nil
  end

  local segment
  for segment = 0, 1 do
    local entry = data[datatype][segment]
    if not entry[source] then
      local kind = ScanName(source)
      if kind == "PET" then
        local owner = data.classes[source]
        if not entry[owner] and ScanName(owner) then
          entry[owner] = { _sum = 0, _ctime = 1, _hits = {}, _crits = {}, _targets = {} }
        end
      elseif not kind then
        break
      end
      entry[source] = { _sum = 0, _ctime = 1, _hits = {}, _crits = {}, _targets = {} }
    end

    local writeSource = source
    local writeAction = action
    if data.classes[source] and data.classes[source] ~= "__other__" and entry[data.classes[source]] then
      entry[source] = nil
      writeAction = "Pet: " .. source
      writeSource = data.classes[source]
      if not entry[writeSource] then
        entry[writeSource] = { _sum = 0, _ctime = 1, _hits = {}, _crits = {}, _targets = {} }
      end
    end

    if entry[writeSource] then
      local amount = tonumber(value)
      local row = entry[writeSource]
      EnsureRowExtras(row)
      row[writeAction] = (row[writeAction] or 0) + amount
      row._sum = (row._sum or 0) + amount
      row._hits[writeAction] = (row._hits[writeAction] or 0) + 1
      if crit then
        row._crits[writeAction] = (row._crits[writeAction] or 0) + 1
      end
      if type(target) == "string" and target ~= "" then
        if not row._targets[writeAction] then row._targets[writeAction] = {} end
        row._targets[writeAction][target] = (row._targets[writeAction][target] or 0) + amount
      end
      row._ctime = row._ctime or 1
      row._tick = row._tick or GetTime()
      if row._tick + 5 < GetTime() then
        row._tick = GetTime()
        row._ctime = row._ctime + 5
      else
        row._ctime = row._ctime + (GetTime() - row._tick)
        row._tick = GetTime()
      end
    end
  end

  if datatype == "damage" and type(target) == "string" and target ~= "" then
    local kind = ScanName(target)
    if kind ~= "PLAYER" and kind ~= "PET" then
      fightDests[target] = (fightDests[target] or 0) + (tonumber(value) or 0)
      if not fightPullName then fightPullName = target end
    end
  end

  MarkMetersDirty()
end

local function AddDeath(name)
  if not fightStart then return end
  if type(name) ~= "string" or name == "" then return end
  name = ResolveName(name)
  table.insert(fightDeaths, { name = name, t = GetTime() - fightStart })
end

-- ShaguDPS locale-independent pattern sanitizer.
local sanitizeCache = {}
local function Sanitize(pattern)
  if not pattern then return nil end
  if not sanitizeCache[pattern] then
    local ret = pattern
    ret = string.gsub(ret, "([%+%-%*%(%)%?%[%]%^])", "%%%1")
    ret = string.gsub(ret, "%d%$", "")
    ret = string.gsub(ret, "(%%%a)", "%(%1+%)")
    ret = string.gsub(ret, "%%s%+", ".+")
    ret = string.gsub(ret, "%(.%+%)%(%%d%+%)", "%(.-%)%(%%d%+%)")
    sanitizeCache[pattern] = ret
  end
  return sanitizeCache[pattern]
end

local captureCache = {}
local function Captures(pat)
  local r = captureCache
  if not r[pat] then
    r[pat] = { nil, nil, nil, nil, nil }
    local a, b, c, d, e
    for a, b, c, d, e in string.gfind(string.gsub(pat, "%((.+)%)", "%1"), string.gsub(pat, "%d%$", "%%(.-)$")) do
      r[pat][1] = tonumber(a)
      r[pat][2] = tonumber(b)
      r[pat][3] = tonumber(c)
      r[pat][4] = tonumber(d)
      r[pat][5] = tonumber(e)
    end
  end
  return r[pat][1], r[pat][2], r[pat][3], r[pat][4], r[pat][5]
end

local function CFind(str, pat)
  local a, b, c, d, e = Captures(pat)
  local match, num, va, vb, vc, vd, ve = string.find(str, Sanitize(pat))
  if not match then return nil end
  local ra = e == 1 and ve or d == 1 and vd or c == 1 and vc or b == 1 and vb or va
  local rb = e == 2 and ve or d == 2 and vd or c == 2 and vc or a == 2 and va or vb
  local rc = e == 3 and ve or d == 3 and vd or a == 3 and va or b == 3 and vb or vc
  local rd = e == 4 and ve or a == 4 and va or c == 4 and vc or b == 4 and vb or vd
  local re = a == 5 and va or d == 5 and vd or c == 5 and vc or b == 5 and vb or ve
  return match, num, ra, rb, rc, rd, re
end

-- Emberveil ships almost no FrameXML GlobalStrings. Prefer client strings,
-- then hard-coded enUS / deDE so the Shagu-style matcher still has patterns.
local function GlobalOr(name, fallback)
  local value = getglobal(name)
  if type(value) == "string" and value ~= "" then return value end
  return fallback
end

local combatlogStrings = {
  ["Hit Damage (self vs. other)"] = {
    COMBATHITSELFOTHER, COMBATHITSCHOOLSELFOTHER, COMBATHITCRITSELFOTHER, COMBATHITCRITSCHOOLSELFOTHER
  },
  ["Hit Damage (other vs. self)"] = {
    COMBATHITOTHERSELF, COMBATHITCRITOTHERSELF, COMBATHITSCHOOLOTHERSELF, COMBATHITCRITSCHOOLOTHERSELF
  },
  ["Hit Damage (other vs. other)"] = {
    COMBATHITOTHEROTHER, COMBATHITCRITOTHEROTHER, COMBATHITSCHOOLOTHEROTHER, COMBATHITCRITSCHOOLOTHEROTHER
  },
  ["Spell Damage (self vs. self/other)"] = {
    SPELLLOGSCHOOLSELFSELF, SPELLLOGCRITSCHOOLSELFSELF, SPELLLOGSELFSELF, SPELLLOGCRITSELFSELF,
    SPELLLOGSCHOOLSELFOTHER, SPELLLOGCRITSCHOOLSELFOTHER, SPELLLOGSELFOTHER, SPELLLOGCRITSELFOTHER
  },
  ["Spell Damage (other vs. self)"] = {
    SPELLLOGSCHOOLOTHERSELF, SPELLLOGCRITSCHOOLOTHERSELF, SPELLLOGOTHERSELF, SPELLLOGCRITOTHERSELF
  },
  ["Spell Damage (other vs. other)"] = {
    SPELLLOGSCHOOLOTHEROTHER, SPELLLOGCRITSCHOOLOTHEROTHER, SPELLLOGOTHEROTHER, SPELLLOGCRITOTHEROTHER
  },
  ["Shield Damage (self vs. other)"] = { DAMAGESHIELDSELFOTHER },
  ["Shield Damage (other vs. self/other)"] = { DAMAGESHIELDOTHERSELF, DAMAGESHIELDOTHEROTHER },
  ["Periodic Damage (self/other vs. other)"] = {
    PERIODICAURADAMAGESELFOTHER, PERIODICAURADAMAGEOTHEROTHER
  },
  ["Periodic Damage (self/other vs. self)"] = {
    PERIODICAURADAMAGESELFSELF, PERIODICAURADAMAGEOTHERSELF
  },
  ["Heal (self vs. self/other)"] = {
    HEALEDCRITSELFSELF, HEALEDSELFSELF, HEALEDCRITSELFOTHER, HEALEDSELFOTHER
  },
  ["Heal (other vs. self/other)"] = {
    HEALEDCRITOTHERSELF, HEALEDOTHERSELF, HEALEDCRITOTHEROTHER, HEALEDOTHEROTHER
  },
  ["Periodic Heal (self/other vs. other)"] = {
    PERIODICAURAHEALSELFOTHER, PERIODICAURAHEALOTHEROTHER
  },
  ["Periodic Heal (other vs. self/other)"] = {
    PERIODICAURAHEALSELFSELF, PERIODICAURAHEALOTHERSELF
  },
}

local combatlogEvents = {
  CHAT_MSG_COMBAT_SELF_HITS = combatlogStrings["Hit Damage (self vs. other)"],
  CHAT_MSG_COMBAT_CREATURE_VS_SELF_HITS = combatlogStrings["Hit Damage (other vs. self)"],
  CHAT_MSG_COMBAT_PARTY_HITS = combatlogStrings["Hit Damage (other vs. other)"],
  CHAT_MSG_COMBAT_FRIENDLYPLAYER_HITS = combatlogStrings["Hit Damage (other vs. other)"],
  CHAT_MSG_COMBAT_HOSTILEPLAYER_HITS = combatlogStrings["Hit Damage (other vs. other)"],
  CHAT_MSG_COMBAT_CREATURE_VS_CREATURE_HITS = combatlogStrings["Hit Damage (other vs. other)"],
  CHAT_MSG_COMBAT_CREATURE_VS_PARTY_HITS = combatlogStrings["Hit Damage (other vs. other)"],
  CHAT_MSG_COMBAT_PET_HITS = combatlogStrings["Hit Damage (other vs. other)"],
  CHAT_MSG_SPELL_SELF_DAMAGE = combatlogStrings["Spell Damage (self vs. self/other)"],
  CHAT_MSG_SPELL_CREATURE_VS_SELF_DAMAGE = combatlogStrings["Spell Damage (other vs. self)"],
  CHAT_MSG_SPELL_PARTY_DAMAGE = combatlogStrings["Spell Damage (other vs. other)"],
  CHAT_MSG_SPELL_FRIENDLYPLAYER_DAMAGE = combatlogStrings["Spell Damage (other vs. other)"],
  CHAT_MSG_SPELL_HOSTILEPLAYER_DAMAGE = combatlogStrings["Spell Damage (other vs. other)"],
  CHAT_MSG_SPELL_CREATURE_VS_CREATURE_DAMAGE = combatlogStrings["Spell Damage (other vs. other)"],
  CHAT_MSG_SPELL_CREATURE_VS_PARTY_DAMAGE = combatlogStrings["Spell Damage (other vs. other)"],
  CHAT_MSG_SPELL_PET_DAMAGE = combatlogStrings["Spell Damage (other vs. other)"],
  CHAT_MSG_SPELL_DAMAGESHIELDS_ON_SELF = combatlogStrings["Shield Damage (self vs. other)"],
  CHAT_MSG_SPELL_DAMAGESHIELDS_ON_OTHERS = combatlogStrings["Shield Damage (other vs. self/other)"],
  CHAT_MSG_SPELL_PERIODIC_PARTY_DAMAGE = combatlogStrings["Periodic Damage (self/other vs. other)"],
  CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_DAMAGE = combatlogStrings["Periodic Damage (self/other vs. other)"],
  CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_DAMAGE = combatlogStrings["Periodic Damage (self/other vs. other)"],
  CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE = combatlogStrings["Periodic Damage (self/other vs. other)"],
  CHAT_MSG_SPELL_PERIODIC_SELF_DAMAGE = combatlogStrings["Periodic Damage (self/other vs. self)"],
  CHAT_MSG_SPELL_SELF_BUFF = combatlogStrings["Heal (self vs. self/other)"],
  CHAT_MSG_SPELL_FRIENDLYPLAYER_BUFF = combatlogStrings["Heal (other vs. self/other)"],
  CHAT_MSG_SPELL_HOSTILEPLAYER_BUFF = combatlogStrings["Heal (other vs. self/other)"],
  CHAT_MSG_SPELL_PARTY_BUFF = combatlogStrings["Heal (other vs. self/other)"],
  CHAT_MSG_SPELL_PERIODIC_PARTY_BUFFS = combatlogStrings["Periodic Heal (self/other vs. other)"],
  CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_BUFFS = combatlogStrings["Periodic Heal (self/other vs. other)"],
  CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_BUFFS = combatlogStrings["Periodic Heal (self/other vs. other)"],
  CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS = combatlogStrings["Periodic Heal (other vs. self/other)"],
}

local combatlogParser = {}
if SPELLLOGSCHOOLSELFSELF then
  combatlogParser[SPELLLOGSCHOOLSELFSELF] = function(d, attack, value, school)
    return d.source, attack, d.target, value, school, "damage"
  end
end
if SPELLLOGCRITSCHOOLSELFSELF then
  combatlogParser[SPELLLOGCRITSCHOOLSELFSELF] = function(d, attack, value, school)
    return d.source, attack, d.target, value, school, "damage"
  end
end
if SPELLLOGSELFSELF then
  combatlogParser[SPELLLOGSELFSELF] = function(d, attack, value)
    return d.source, attack, d.target, value, d.school, "damage"
  end
end
if SPELLLOGCRITSELFSELF then
  combatlogParser[SPELLLOGCRITSELFSELF] = function(d, attack, value)
    return d.source, attack, d.target, value, d.school, "damage"
  end
end
if PERIODICAURADAMAGESELFSELF then
  combatlogParser[PERIODICAURADAMAGESELFSELF] = function(d, value, school, attack)
    return d.source, attack, d.target, value, school, "damage"
  end
end
if SPELLLOGSCHOOLSELFOTHER then
  combatlogParser[SPELLLOGSCHOOLSELFOTHER] = function(d, attack, target, value, school)
    return d.source, attack, target, value, school, "damage"
  end
end
if SPELLLOGCRITSCHOOLSELFOTHER then
  combatlogParser[SPELLLOGCRITSCHOOLSELFOTHER] = function(d, attack, target, value, school)
    return d.source, attack, target, value, school, "damage"
  end
end
if SPELLLOGSELFOTHER then
  combatlogParser[SPELLLOGSELFOTHER] = function(d, attack, target, value)
    return d.source, attack, target, value, d.school, "damage"
  end
end
if SPELLLOGCRITSELFOTHER then
  combatlogParser[SPELLLOGCRITSELFOTHER] = function(d, attack, target, value)
    return d.source, attack, target, value, d.school, "damage"
  end
end
if PERIODICAURADAMAGESELFOTHER then
  combatlogParser[PERIODICAURADAMAGESELFOTHER] = function(d, target, value, school, attack)
    return d.source, attack, target, value, school, "damage"
  end
end
if COMBATHITSELFOTHER then
  combatlogParser[COMBATHITSELFOTHER] = function(d, target, value)
    return d.source, d.attack, target, value, d.school, "damage"
  end
end
if COMBATHITCRITSELFOTHER then
  combatlogParser[COMBATHITCRITSELFOTHER] = function(d, target, value)
    return d.source, d.attack, target, value, d.school, "damage"
  end
end
if COMBATHITSCHOOLSELFOTHER then
  combatlogParser[COMBATHITSCHOOLSELFOTHER] = function(d, target, value, school)
    return d.source, d.attack, target, value, school, "damage"
  end
end
if COMBATHITCRITSCHOOLSELFOTHER then
  combatlogParser[COMBATHITCRITSCHOOLSELFOTHER] = function(d, target, value, school)
    return d.source, d.attack, target, value, school, "damage"
  end
end
if DAMAGESHIELDSELFOTHER then
  combatlogParser[DAMAGESHIELDSELFOTHER] = function(d, value, school, target)
    return d.source, "Reflect", target, value, school, "damage"
  end
end
if SPELLLOGSCHOOLOTHERSELF then
  combatlogParser[SPELLLOGSCHOOLOTHERSELF] = function(d, source, attack, value, school)
    return source, attack, d.target, value, school, "damage"
  end
end
if SPELLLOGCRITSCHOOLOTHERSELF then
  combatlogParser[SPELLLOGCRITSCHOOLOTHERSELF] = function(d, source, attack, value, school)
    return source, attack, d.target, value, school, "damage"
  end
end
if SPELLLOGOTHERSELF then
  combatlogParser[SPELLLOGOTHERSELF] = function(d, source, attack, value)
    return source, attack, d.target, value, d.school, "damage"
  end
end
if SPELLLOGCRITOTHERSELF then
  combatlogParser[SPELLLOGCRITOTHERSELF] = function(d, source, attack, value)
    return source, attack, d.target, value, d.school, "damage"
  end
end
if PERIODICAURADAMAGEOTHERSELF then
  combatlogParser[PERIODICAURADAMAGEOTHERSELF] = function(d, value, school, source, attack)
    return source, attack, d.target, value, school, "damage"
  end
end
if COMBATHITOTHERSELF then
  combatlogParser[COMBATHITOTHERSELF] = function(d, source, value)
    return source, d.attack, d.target, value, d.school, "damage"
  end
end
if COMBATHITCRITOTHERSELF then
  combatlogParser[COMBATHITCRITOTHERSELF] = function(d, source, value)
    return source, d.attack, d.target, value, d.school, "damage"
  end
end
if COMBATHITSCHOOLOTHERSELF then
  combatlogParser[COMBATHITSCHOOLOTHERSELF] = function(d, source, value, school)
    return source, d.attack, d.target, value, school, "damage"
  end
end
if COMBATHITCRITSCHOOLOTHERSELF then
  combatlogParser[COMBATHITCRITSCHOOLOTHERSELF] = function(d, source, value, school)
    return source, d.attack, d.target, value, school, "damage"
  end
end
if SPELLLOGSCHOOLOTHEROTHER then
  combatlogParser[SPELLLOGSCHOOLOTHEROTHER] = function(d, source, attack, target, value, school)
    return source, attack, target, value, school, "damage"
  end
end
if SPELLLOGCRITSCHOOLOTHEROTHER then
  combatlogParser[SPELLLOGCRITSCHOOLOTHEROTHER] = function(d, source, attack, target, value, school)
    return source, attack, target, value, school, "damage"
  end
end
if SPELLLOGOTHEROTHER then
  combatlogParser[SPELLLOGOTHEROTHER] = function(d, source, attack, target, value)
    return source, attack, target, value, d.school, "damage"
  end
end
if SPELLLOGCRITOTHEROTHER then
  combatlogParser[SPELLLOGCRITOTHEROTHER] = function(d, source, attack, target, value, school)
    return source, attack, target, value, school or d.school, "damage"
  end
end
if PERIODICAURADAMAGEOTHEROTHER then
  combatlogParser[PERIODICAURADAMAGEOTHEROTHER] = function(d, target, value, school, source, attack)
    return source, attack, target, value, school, "damage"
  end
end
if COMBATHITOTHEROTHER then
  combatlogParser[COMBATHITOTHEROTHER] = function(d, source, target, value)
    return source, d.attack, target, value, d.school, "damage"
  end
end
if COMBATHITCRITOTHEROTHER then
  combatlogParser[COMBATHITCRITOTHEROTHER] = function(d, source, target, value)
    return source, d.attack, target, value, d.school, "damage"
  end
end
if COMBATHITSCHOOLOTHEROTHER then
  combatlogParser[COMBATHITSCHOOLOTHEROTHER] = function(d, source, target, value, school)
    return source, d.attack, target, value, school, "damage"
  end
end
if COMBATHITCRITSCHOOLOTHEROTHER then
  combatlogParser[COMBATHITCRITSCHOOLOTHEROTHER] = function(d, source, target, value, school)
    return source, d.attack, target, value, school, "damage"
  end
end
if DAMAGESHIELDOTHERSELF then
  combatlogParser[DAMAGESHIELDOTHERSELF] = function(d, source, value, school)
    return source, "Reflect", d.target, value, school, "damage"
  end
end
if DAMAGESHIELDOTHEROTHER then
  combatlogParser[DAMAGESHIELDOTHEROTHER] = function(d, source, value, school, target)
    return source, "Reflect", target, value, school, "damage"
  end
end
if HEALEDCRITOTHERSELF then
  combatlogParser[HEALEDCRITOTHERSELF] = function(d, source, spell, value)
    return source, spell, d.target, value, d.school, "heal"
  end
end
if HEALEDOTHERSELF then
  combatlogParser[HEALEDOTHERSELF] = function(d, source, spell, value)
    return source, spell, d.target, value, d.school, "heal"
  end
end
if PERIODICAURAHEALOTHERSELF then
  combatlogParser[PERIODICAURAHEALOTHERSELF] = function(d, value, source, spell)
    return source, spell, d.target, value, d.school, "heal"
  end
end
if HEALEDCRITSELFSELF then
  combatlogParser[HEALEDCRITSELFSELF] = function(d, spell, value)
    return d.source, spell, d.target, value, d.school, "heal"
  end
end
if HEALEDSELFSELF then
  combatlogParser[HEALEDSELFSELF] = function(d, spell, value)
    return d.source, spell, d.target, value, d.school, "heal"
  end
end
if PERIODICAURAHEALSELFSELF then
  combatlogParser[PERIODICAURAHEALSELFSELF] = function(d, value, spell)
    return d.source, spell, d.target, value, d.school, "heal"
  end
end
if HEALEDCRITSELFOTHER then
  combatlogParser[HEALEDCRITSELFOTHER] = function(d, spell, target, value)
    return d.source, spell, target, value, d.school, "heal"
  end
end
if HEALEDSELFOTHER then
  combatlogParser[HEALEDSELFOTHER] = function(d, spell, target, value)
    return d.source, spell, target, value, d.school, "heal"
  end
end
if PERIODICAURAHEALSELFOTHER then
  combatlogParser[PERIODICAURAHEALSELFOTHER] = function(d, target, value, spell)
    return d.source, spell, target, value, d.school, "heal"
  end
end
if HEALEDCRITOTHEROTHER then
  combatlogParser[HEALEDCRITOTHEROTHER] = function(d, source, spell, target, value)
    return source, spell, target, value, d.school, "heal"
  end
end
if HEALEDOTHEROTHER then
  combatlogParser[HEALEDOTHEROTHER] = function(d, source, spell, target, value)
    return source, spell, target, value, d.school, "heal"
  end
end
if PERIODICAURAHEALOTHEROTHER then
  combatlogParser[PERIODICAURAHEALOTHEROTHER] = function(d, target, value, source, spell)
    return source, spell, target, value, d.school, "heal"
  end
end

local allPatterns = {}

local function BindPattern(pattern, handler, eventKeys)
  if type(pattern) ~= "string" or pattern == "" or not handler then return end
  if not combatlogParser[pattern] then
    combatlogParser[pattern] = handler
  end
  table.insert(allPatterns, pattern)
  if eventKeys then
    local i
    for i = 1, table.getn(eventKeys) do
      local list = combatlogEvents[eventKeys[i]]
      if list then table.insert(list, pattern) end
    end
  end
end

-- Handlers match ShaguDPS capture order for the fallback format strings.
local hitSelfOther = function(d, target, value)
  return d.source, d.attack, target, value, d.school, "damage"
end
local hitOtherSelf = function(d, source, value)
  return source, d.attack, d.target, value, d.school, "damage"
end
local hitOtherOther = function(d, source, target, value)
  return source, d.attack, target, value, d.school, "damage"
end
local spellSelfOther = function(d, attack, target, value)
  return d.source, attack, target, value, d.school, "damage"
end
local spellOtherOther = function(d, source, attack, target, value)
  return source, attack, target, value, d.school, "damage"
end
local spellOtherSelf = function(d, source, attack, value)
  return source, attack, d.target, value, d.school, "damage"
end
local healSelfOther = function(d, spell, target, value)
  return d.source, spell, target, value, d.school, "heal"
end
local healSelfSelf = function(d, spell, value)
  return d.source, spell, d.target, value, d.school, "heal"
end
local healOtherOther = function(d, source, spell, target, value)
  return source, spell, target, value, d.school, "heal"
end
local healOtherSelf = function(d, source, spell, value)
  return source, spell, d.target, value, d.school, "heal"
end
local dotSelfOther = function(d, target, value, school, attack)
  return d.source, attack, target, value, school, "damage"
end
local dotOtherOther = function(d, target, value, school, source, attack)
  return source, attack, target, value, school, "damage"
end

local selfHitEvents = { "CHAT_MSG_COMBAT_SELF_HITS" }
local otherSelfHitEvents = { "CHAT_MSG_COMBAT_CREATURE_VS_SELF_HITS" }
local otherHitEvents = {
  "CHAT_MSG_COMBAT_PARTY_HITS", "CHAT_MSG_COMBAT_FRIENDLYPLAYER_HITS",
  "CHAT_MSG_COMBAT_HOSTILEPLAYER_HITS", "CHAT_MSG_COMBAT_CREATURE_VS_CREATURE_HITS",
  "CHAT_MSG_COMBAT_CREATURE_VS_PARTY_HITS", "CHAT_MSG_COMBAT_PET_HITS",
}
local selfSpellEvents = { "CHAT_MSG_SPELL_SELF_DAMAGE" }
local otherSelfSpellEvents = { "CHAT_MSG_SPELL_CREATURE_VS_SELF_DAMAGE" }
local otherSpellEvents = {
  "CHAT_MSG_SPELL_PARTY_DAMAGE", "CHAT_MSG_SPELL_FRIENDLYPLAYER_DAMAGE",
  "CHAT_MSG_SPELL_HOSTILEPLAYER_DAMAGE", "CHAT_MSG_SPELL_CREATURE_VS_CREATURE_DAMAGE",
  "CHAT_MSG_SPELL_CREATURE_VS_PARTY_DAMAGE", "CHAT_MSG_SPELL_PET_DAMAGE",
}
local selfHealEvents = { "CHAT_MSG_SPELL_SELF_BUFF" }
local otherHealEvents = {
  "CHAT_MSG_SPELL_FRIENDLYPLAYER_BUFF", "CHAT_MSG_SPELL_HOSTILEPLAYER_BUFF",
  "CHAT_MSG_SPELL_PARTY_BUFF",
}

BindPattern(GlobalOr("COMBATHITSELFOTHER", "You hit %s for %d."), hitSelfOther, selfHitEvents)
BindPattern("You crit %s for %d.", hitSelfOther, selfHitEvents)
BindPattern("You hit %s for %d %s damage.", hitSelfOther, selfHitEvents)
BindPattern("Ihr trefft %s für %d Schaden.", hitSelfOther, selfHitEvents)
BindPattern("Ihr trefft %s kritisch für %d Schaden.", hitSelfOther, selfHitEvents)
BindPattern(GlobalOr("COMBATHITOTHERSELF", "%s hits you for %d."), hitOtherSelf, otherSelfHitEvents)
BindPattern("%s trifft Euch für %d Schaden.", hitOtherSelf, otherSelfHitEvents)
BindPattern(GlobalOr("COMBATHITOTHEROTHER", "%s hits %s for %d."), hitOtherOther, otherHitEvents)
BindPattern("%s crits %s for %d.", hitOtherOther, otherHitEvents)
BindPattern("%s trifft %s für %d Schaden.", hitOtherOther, otherHitEvents)
BindPattern("%s trifft %s kritisch für %d Schaden.", hitOtherOther, otherHitEvents)
BindPattern(GlobalOr("SPELLLOGSELFOTHER", "Your %s hits %s for %d."), spellSelfOther, selfSpellEvents)
BindPattern("Your %s crits %s for %d.", spellSelfOther, selfSpellEvents)
BindPattern("Your %s hits %s for %d %s damage.", spellSelfOther, selfSpellEvents)
BindPattern("Euer %s trifft %s für %d Schaden.", spellSelfOther, selfSpellEvents)
BindPattern("Euer %s trifft %s kritisch für %d Schaden.", spellSelfOther, selfSpellEvents)
BindPattern(GlobalOr("SPELLLOGOTHEROTHER", "%s's %s hits %s for %d."), spellOtherOther, otherSpellEvents)
BindPattern("%ss %s trifft %s für %d Schaden.", spellOtherOther, otherSpellEvents)
BindPattern(GlobalOr("SPELLLOGOTHERSELF", "%s's %s hits you for %d."), spellOtherSelf, otherSelfSpellEvents)
BindPattern(GlobalOr("HEALEDSELFOTHER", "Your %s heals %s for %d."), healSelfOther, selfHealEvents)
BindPattern("Your %s critically heals %s for %d.", healSelfOther, selfHealEvents)
BindPattern(GlobalOr("HEALEDSELFSELF", "Your %s heals you for %d."), healSelfSelf, selfHealEvents)
BindPattern(GlobalOr("HEALEDOTHEROTHER", "%s's %s heals %s for %d."), healOtherOther, otherHealEvents)
BindPattern(GlobalOr("HEALEDOTHERSELF", "%s's %s heals you for %d."), healOtherSelf, otherHealEvents)
BindPattern(GlobalOr("PERIODICAURADAMAGESELFOTHER", "%s suffers %d %s damage from your %s."), dotSelfOther, {
  "CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE", "CHAT_MSG_SPELL_PERIODIC_PARTY_DAMAGE",
  "CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_DAMAGE", "CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_DAMAGE",
})
BindPattern(GlobalOr("PERIODICAURADAMAGEOTHEROTHER", "%s suffers %d %s damage from %s's %s."), dotOtherOther, {
  "CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE", "CHAT_MSG_SPELL_PERIODIC_PARTY_DAMAGE",
})

local genericRules = {
  { "^You hit (.+) for (%d+)", hitSelfOther },
  { "^You crit (.+) for (%d+)", hitSelfOther },
  { "^Your (.+) hits (.+) for (%d+)", spellSelfOther },
  { "^Your (.+) crits (.+) for (%d+)", spellSelfOther },
  { "^Your (.+) heals you for (%d+)", healSelfSelf },
  { "^Your (.+) heals (.+) for (%d+)", healSelfOther },
  { "^(.+) hits you for (%d+)", hitOtherSelf },
  { "^(.+) crits you for (%d+)", hitOtherSelf },
  { "^(.+)'s (.+) hits you for (%d+)", spellOtherSelf },
  { "^(.+)'s (.+) hits (.+) for (%d+)", spellOtherOther },
  { "^(.+) hits (.+) for (%d+)", hitOtherOther },
  { "^(.+) crits (.+) for (%d+)", hitOtherOther },
  { "^Ihr trefft (.+) kritisch für (%d+)", hitSelfOther },
  { "^Ihr trefft (.+) für (%d+)", hitSelfOther },
  { "^Euer (.+) trifft (.+) kritisch für (%d+)", spellSelfOther },
  { "^Euer (.+) trifft (.+) für (%d+)", spellSelfOther },
  { "^(.+) trifft Euch kritisch für (%d+)", hitOtherSelf },
  { "^(.+) trifft Euch für (%d+)", hitOtherSelf },
  { "^(.+) trifft (.+) kritisch für (%d+)", hitOtherOther },
  { "^(.+) trifft (.+) für (%d+)", hitOtherOther },
}

local event
for event in pairs(combatlogEvents) do
  pcall(parser.RegisterEvent, parser, event)
end
pcall(parser.RegisterEvent, parser, "COMBAT_LOG_EVENT_UNFILTERED")
pcall(parser.RegisterEvent, parser, "COMBAT_LOG_EVENT")
pcall(parser.RegisterEvent, parser, "CHAT_MSG_COMBAT_MISC_INFO")
pcall(parser.RegisterEvent, parser, "CHAT_MSG_COMBAT_FRIENDLY_DEATH")
pcall(parser.RegisterEvent, parser, "CHAT_MSG_COMBAT_HOSTILE_DEATH")
pcall(parser.RegisterEvent, parser, "CHAT_MSG_COMBAT_CREATURE_VS_SELF_HITS")

local pattern
for pattern in pairs(combatlogParser) do
  Sanitize(pattern)
end

local absorb = ABSORB_TRAILER and Sanitize(ABSORB_TRAILER)
local resist = RESIST_TRAILER and Sanitize(RESIST_TRAILER)
local empty = ""
local defaults = {}
local lastParse, lastParseTime = "", 0

local function PrepareMessage(msg)
  if type(msg) ~= "string" then return nil end
  msg = StripMarkup(msg)
  if absorb then msg = string.gsub(msg, absorb, empty) end
  if resist then msg = string.gsub(msg, resist, empty) end
  return msg
end

local function ParseCombatMessage(msg, eventName)
  msg = PrepareMessage(msg)
  if not msg or msg == "" then return end
  local now = GetTime()
  if msg == lastParse and now - lastParseTime < .05 then return end

  if string.find(msg, "You die", 1, true) or string.find(msg, "Ihr sterbt", 1, true) then
    lastParse, lastParseTime = msg, now
    AddDeath(UnitName("player"))
    return
  end
  local _, _, dead = string.find(msg, "^(.+) dies%.")
  if not dead then _, _, dead = string.find(msg, "^(.+) stirbt") end
  if dead then
    lastParse, lastParseTime = msg, now
    AddDeath(dead)
    return
  end

  local crit
  local lower = string.lower(msg)
  if string.find(lower, "crit", 1, true) or string.find(msg, "kritisch", 1, true) then
    crit = true
  end

  defaults.source = UnitName("player")
  defaults.target = defaults.source
  defaults.school = "physical"
  defaults.attack = "Auto Hit"

  local function TryList(list)
    if not list then return nil end
    local _, pat
    for _, pat in pairs(list) do
      if pat and combatlogParser[pat] then
        local result, _, a1, a2, a3, a4, a5 = CFind(msg, pat)
        if result then
          lastParse, lastParseTime = msg, now
          local s, a, t, v, sc, dt = combatlogParser[pat](defaults, a1, a2, a3, a4, a5)
          AddData(s, a, t, v, sc, dt, crit)
          return true
        end
      end
    end
    return nil
  end

  if TryList(eventName and combatlogEvents[eventName]) then return end

  local i
  for i = 1, table.getn(genericRules) do
    local rule = genericRules[i]
    local found, _, a1, a2, a3, a4 = string.find(msg, rule[1])
    if found then
      lastParse, lastParseTime = msg, now
      local s, a, t, v, sc, dt = rule[2](defaults, a1, a2, a3, a4)
      AddData(s, a, t, v, sc, dt, crit)
      return
    end
  end

  TryList(allPatterns)
end

local function HandleCLEU()
  local subevent, source, dest, swingAmt, spellName, spellAmt
  if type(CombatLogGetCurrentEventInfo) == "function" then
    local ok, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16 = pcall(CombatLogGetCurrentEventInfo)
    if ok and type(a2) == "string" then
      subevent = a2
      if a3 == true or a3 == false then
        if type(a7) == "number" then
          source, dest = a5, a9
          swingAmt, spellName, spellAmt = a12, a13, a16
        else
          source, dest = a5, a8
          swingAmt, spellName, spellAmt = a10, a11, a13
        end
      else
        source, dest = a4, a7
        swingAmt, spellName, spellAmt = a9, a10, a12
      end
    end
  end
  if not subevent then
    subevent = arg2
    if type(subevent) ~= "string" then return end
    if arg3 == true or arg3 == false or arg3 == 0 or arg3 == 1 then
      source, dest = arg5, arg8
      swingAmt, spellName, spellAmt = arg10, arg11, arg13
    else
      source, dest = arg4, arg7
      swingAmt, spellName, spellAmt = arg9, arg10, arg12
    end
  end
  if subevent == "SWING_DAMAGE" then
    AddData(source, "Auto Hit", dest, swingAmt, nil, "damage")
  elseif subevent == "SPELL_DAMAGE" or subevent == "RANGE_DAMAGE" or subevent == "SPELL_PERIODIC_DAMAGE" or subevent == "DAMAGE_SHIELD" or subevent == "DAMAGE_SPLIT" then
    AddData(source, spellName or "Spell", dest, spellAmt or swingAmt, nil, "damage")
  elseif subevent == "SPELL_HEAL" or subevent == "SPELL_PERIODIC_HEAL" then
    AddData(source, spellName or "Heal", dest, spellAmt or swingAmt, nil, "heal")
  elseif subevent == "UNIT_DIED" or subevent == "UNIT_DESTROYED" then
    AddDeath(dest)
  end
end

parser:SetScript("OnEvent", function()
  if event == "COMBAT_LOG_EVENT_UNFILTERED" or event == "COMBAT_LOG_EVENT" then
    HandleCLEU()
    return
  end
  if arg1 then ParseCombatMessage(arg1, event) end
end)

local function HookChatMeter(frame)
  if not frame or frame.qtMeterHooked then return end
  local orig = frame.AddMessage
  if type(orig) ~= "function" then return end
  frame.qtMeterHooked = true
  frame.AddMessage = function(self, msg, r, g, b, id)
    if type(msg) == "string" then pcall(ParseCombatMessage, msg, nil) end
    return orig(self, msg, r, g, b, id)
  end
end

HookChatMeter(DEFAULT_CHAT_FRAME)
HookChatMeter(ChatFrame1)
HookChatMeter(ChatFrame2)

local function CopyTableDeep(src, depth)
  if type(src) ~= "table" then return src end
  depth = depth or 3
  local out = {}
  local k, v
  for k, v in pairs(src) do
    if type(v) == "table" and depth > 1 then
      out[k] = CopyTableDeep(v, depth - 1)
    else
      out[k] = v
    end
  end
  return out
end

local function CopySegment(src)
  return CopyTableDeep(src, 3)
end

local function SegmentHasData(seg)
  if type(seg) ~= "table" then return nil end
  local _
  for _ in pairs(seg) do return true end
  return nil
end

local function FormatDuration(sec)
  sec = tonumber(sec) or 0
  if sec < 0 then sec = 0 end
  local m = math.floor(sec / 60)
  local s = math.floor(sec - m * 60)
  if m < 1 then return tostring(s) .. "s" end
  return tostring(m) .. ":" .. string.format("%02d", s)
end

local function UniqueFightName(base)
  if not base or base == "" then base = "Combat" end
  local n = 0
  local i
  for i = 1, table.getn(history) do
    local name = history[i].name
    if name == base or string.find(name, base .. " ", 1, true) == 1 then
      n = n + 1
    end
  end
  if n < 1 then return base end
  return base .. " " .. tostring(n + 1)
end

local function ArchiveCurrentFight()
  if not SegmentHasData(data.damage[1]) and not SegmentHasData(data.heal[1]) then
    return
  end
  local name = fightPullName
  if not name then
    local best, bestAmt, dest, amt
    for dest, amt in pairs(fightDests) do
      if not best or amt > bestAmt then
        best = dest
        bestAmt = amt
      end
    end
    name = best
  end
  local duration = 0
  if fightStart then duration = GetTime() - fightStart end
  if duration < 1 then duration = 1 end
  lastFightDuration = duration
  table.insert(history, 1, {
    name = UniqueFightName(name),
    damage = CopySegment(data.damage[1]),
    heal = CopySegment(data.heal[1]),
    duration = duration,
    deaths = fightDeaths,
  })
  if viewing then
    viewing = viewing + 1
    if viewing > MAX_FIGHTS then viewing = nil end
  end
  while table.getn(history) > MAX_FIGHTS do
    table.remove(history)
  end
  PersistMeters()
  fightDests = {}
  fightDeaths = {}
  fightPullName = nil
  fightStart = nil
end

local function BeginFight()
  fightDests = {}
  fightDeaths = {}
  fightStart = GetTime()
  lastFightDuration = nil
  fightPullName = nil
  if type(UnitExists) == "function" and UnitExists("target") then
    local hostile = true
    if type(UnitCanAttack) == "function" then
      local ok, can = pcall(UnitCanAttack, "player", "target")
      hostile = ok and (can == true or can == 1 or can == "1")
    end
    if hostile then
      fightPullName = UnitName("target")
    end
  end
end

local function GetActiveSegment(frame)
  local view = frame and frame.view or "damage"
  local segmentId = frame and frame.segment or 1
  if segmentId == 1 and viewing and history[viewing] then
    if view == "heal" then return history[viewing].heal or {} end
    return history[viewing].damage or {}
  end
  local store = view == "heal" and data.heal or data.damage
  return store[segmentId] or {}
end

local function ActiveFightDuration(frame)
  if not frame or (frame.segment or 1) == 0 then return nil end
  if viewing and history[viewing] then return history[viewing].duration end
  if fightStart then return GetTime() - fightStart end
  return lastFightDuration
end

local combatWatch = CreateFrame("Frame", "QtPDamageCombat")
combatWatch.state = "NO_COMBAT"
combatWatch:RegisterEvent("PLAYER_REGEN_DISABLED")
combatWatch:RegisterEvent("PLAYER_REGEN_ENABLED")
local function UpdateCombatState()
  local state = AnyInCombat() and "COMBAT" or "NO_COMBAT"
  if combatWatch.state ~= state then
    combatWatch.state = state
    if state == "COMBAT" then
      BeginFight()
    else
      ArchiveCurrentFight()
      startNextSegment = true
    end
  end
end
combatWatch:SetScript("OnEvent", function()
  UpdateCombatState()
  if combatWatch.state == "COMBAT" then
    combatWatch.elapsed = 0
    combatWatch:SetScript("OnUpdate", function()
      this.elapsed = this.elapsed + (arg1 or 0)
      if this.elapsed < 1 then return end
      this.elapsed = 0
      UpdateCombatState()
      if this.state == "COMBAT" then
        MarkMetersDirty()
      else
        this:SetScript("OnUpdate", nil)
      end
    end)
  else
    combatWatch:SetScript("OnUpdate", nil)
  end
end)
combatWatch.elapsed = 0

local function SortedNames(segment, byRate)
  local keys = {}
  local name
  for name in pairs(segment) do
    table.insert(keys, name)
  end
  table.sort(keys, function(a, b)
    local sa, sb = segment[a]._sum or 0, segment[b]._sum or 0
    if byRate then
      local ca, cb = segment[a]._ctime or 1, segment[b]._ctime or 1
      if ca < 1 then ca = 1 end
      if cb < 1 then cb = 1 end
      return (sb / cb) < (sa / ca)
    end
    return sb < sa
  end)
  return keys
end

local function ClassColor(name)
  local class = data.classes[name]
  local c = class and CLASS_COLORS[class]
  if c then return c[1], c[2], c[3] end
  return .35, .4, .45
end

local function ShortNumber(value)
  value = tonumber(value) or 0
  if value >= 1000000 then return string.format("%.1fm", value / 1000000) end
  if value >= 10000 then return string.format("%.1fk", value / 1000) end
  return tostring(math.floor(value + .5))
end

local MAX_WINDOWS = 6
local MODES = {
  { view = "damage", segment = 1, label = "Current Damage" },
  { view = "dps",    segment = 1, label = "Current DPS" },
  { view = "heal",   segment = 1, label = "Current Heal" },
  { view = "damage", segment = 0, label = "Overall Damage" },
  { view = "dps",    segment = 0, label = "Overall DPS" },
  { view = "heal",   segment = 0, label = "Overall Heal" },
}

local function ModeLabel(view, segment)
  local i
  for i = 1, table.getn(MODES) do
    if MODES[i].view == view and MODES[i].segment == segment then
      return MODES[i].label
    end
  end
  return "Current Damage"
end

local function ModeIndex(view, segment)
  local i
  for i = 1, table.getn(MODES) do
    if MODES[i].view == view and MODES[i].segment == segment then return i end
  end
  return 1
end

local function MeterMoveKey(id)
  if tonumber(id) == 1 then return "damageMeter" end
  return "damageMeter" .. tostring(id)
end

local function FormatRate(value)
  value = tonumber(value) or 0
  if value >= 10000 then return ShortNumber(value) end
  if value >= 100 then return string.format("%.0f", value) end
  return string.format("%.1f", value)
end

local SHARE_PREFIX = "QtP"

local function AnnounceLine(text, chatType)
  if QtP.Print then QtP:Print(text) end
  if type(chatType) ~= "string" or chatType == "" or chatType == "SELF" then return end
  if type(SendAddonMessage) ~= "function" then return end
  pcall(SendAddonMessage, SHARE_PREFIX, "R:" .. tostring(text), chatType)
end

local function HandleAddonShare()
  local prefix = arg1
  local message = arg2
  local sender = arg4
  if type(prefix) == "string" and string.sub(prefix, 1, 5) == "QtP\t" then
    message = string.sub(prefix, 6)
    prefix = SHARE_PREFIX
    sender = arg3 or arg4
  end
  if prefix ~= SHARE_PREFIX or type(message) ~= "string" then return end
  if string.sub(message, 1, 2) ~= "R:" then return end
  local me
  if type(UnitName) == "function" then me = UnitName("player") end
  if sender and me and string.lower(sender) == string.lower(me) then return end
  if QtP.Print then
    QtP:Print("|cff88ccff" .. (sender or "?") .. "|r " .. string.sub(message, 3))
  end
end

local shareWatch = CreateFrame("Frame", "QtPMeterShare")
shareWatch:RegisterEvent("CHAT_MSG_ADDON")
shareWatch:SetScript("OnEvent", function()
  if event == "CHAT_MSG_ADDON" then HandleAddonShare() end
end)

local function ReportMeter(frame, chatType)
  if not frame then return end
  local view = frame.view or "damage"
  local segmentId = frame.segment or 1
  local segment = GetActiveSegment(frame)
  local keys = SortedNames(segment, view == "dps")
  local count = table.getn(keys)
  if count < 1 then
    AnnounceLine("QtP - " .. ModeLabel(view, segmentId) .. ": no data", chatType)
    return
  end
  AnnounceLine("QtP - " .. ModeLabel(view, segmentId) .. ":", chatType)
  if count > 8 then count = 8 end
  local n
  for n = 1, count do
    local name = keys[n]
    local row = segment[name]
    local sum = row._sum or 0
    local ctime = row._ctime or 1
    if ctime < 1 then ctime = 1 end
    local rate = sum / ctime
    if view == "dps" then
      AnnounceLine(n .. ". " .. name .. " " .. FormatRate(rate) .. " (" .. ShortNumber(sum) .. ")", chatType)
    else
      AnnounceLine(n .. ". " .. name .. " " .. ShortNumber(sum) .. " (" .. FormatRate(rate) .. ")", chatType)
    end
  end
end

local reportMenu
local reportSource
local reportOpen

local function ParkPopup(frame)
  if not frame then return end
  frame:ClearAllPoints()
  frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -4000, 4000)
  if frame.EnableMouse then frame:EnableMouse(false) end
end

-- Emberveil Hide() re-enters OnHide. Calling Hide from OnHide stacks until
-- the client hangs / AVs (crash 0x338). Park first, Hide once, never nest.
local function SafeHidePopup(frame)
  if not frame or frame.qtHiding or frame.qtShowing then return end
  frame.qtHiding = true
  ParkPopup(frame)
  if frame.Hide then pcall(frame.Hide, frame) end
  frame.qtHiding = nil
end

local function HideReportMenu()
  reportOpen = nil
  reportSource = nil
  SafeHidePopup(reportMenu)
end

local function EnsureReportMenu()
  if reportMenu then return reportMenu end
  local menu = CreateFrame("Frame", "QtPMeterReportMenu", UIParent)
  menu:SetFrameStrata("TOOLTIP")
  menu:SetFrameLevel(200)
  QtP.PaintPanel(menu)
  local channels = {
    { "SELF", "Self" },
    { "PARTY", "Party" },
    { "RAID", "Raid" },
    { "GUILD", "Guild" },
  }
  local rowH = 18
  local width = 72
  local height = 8 + table.getn(channels) * rowH
  menu:ClearAllPoints()
  menu:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -2000, 2000)
  menu:SetPoint("BOTTOMRIGHT", UIParent, "TOPLEFT", -2000 + width, 2000 - height)
  local i
  for i = 1, table.getn(channels) do
    local spec = channels[i]
    local btn = CreateFrame("Button", nil, menu)
    btn:SetPoint("TOPLEFT", menu, "TOPLEFT", 4, -(4 + (i - 1) * rowH))
    btn:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -4, -(4 + (i - 1) * rowH))
    btn:SetPoint("BOTTOMLEFT", menu, "TOPLEFT", 4, -(4 + i * rowH))
    btn:EnableMouse(true)
    btn:RegisterForClicks("LeftButtonUp")
    btn.chatType = spec[1]
    btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    btn.text:SetPoint("LEFT", btn, "LEFT", 6, 0)
    btn.text:SetText(spec[2])
    QtP.ApplyBodyFont(btn.text)
    btn:SetScript("OnEnter", function()
      if this.text then this.text:SetTextColor(.96, .68, .04) end
    end)
    btn:SetScript("OnLeave", function()
      if this.text then this.text:SetTextColor(.90, .90, .90) end
    end)
    btn:SetScript("OnClick", function()
      local source = reportSource
      HideReportMenu()
      if source then ReportMeter(source, this.chatType) end
    end)
  end
  menu:EnableMouse(true)
  menu:SetScript("OnLeave", function()
    local focus = GetMouseFocus and GetMouseFocus()
    if focus and focus.GetParent and focus:GetParent() == this then return end
    HideReportMenu()
  end)
  reportMenu = menu
  ParkPopup(menu)
  return menu
end

local function ToggleReportMenu(anchor, frame)
  local menu = EnsureReportMenu()
  if reportOpen and reportSource == frame then
    HideReportMenu()
    return
  end
  reportSource = frame
  reportOpen = true
  menu:ClearAllPoints()
  local width, height = 72, 80
  menu:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -2)
  menu:SetPoint("BOTTOMLEFT", anchor, "BOTTOMRIGHT", -width, -2 - height)
  if menu.EnableMouse then menu:EnableMouse(true) end
  if menu.Show then pcall(menu.Show, menu) end
  if menu.SetFrameLevel then pcall(menu.SetFrameLevel, menu, 200) end
end

local PlaceBox
local SpellList
local function SpellHits(row, spell)
  local hits = 0
  local crits = 0
  if row and row._hits then hits = row._hits[spell] or 0 end
  if row and row._crits then crits = row._crits[spell] or 0 end
  return hits, crits
end
local MAX_DETAIL = 16
local MAX_ROSTER = 16
local DETAIL_W = 560
local DETAIL_ROW = 16
local ROSTER_W = 172
local FOOTER_H = 20
local detailFrame
local detailOpen
local detailView = "damage"
local detailSegment = 1
local detailUnit
local detailCmp
local detailPick
local detailMode = "spells"
local detailSpell
local detailRosterScroll = 0
local detailSpellScroll = 0
local RefreshOverview
local ShowSpellDetails
local MakeDetailBar

local function HideSpellDetails()
  if detailFrame and (detailFrame.qtHiding or detailFrame.qtShowing) then return end
  detailOpen = nil
  detailPick = nil
  detailMode = "spells"
  detailSpell = nil
  if not detailFrame then return end
  detailFrame._placed = nil
  SafeHidePopup(detailFrame)
end

MakeDetailBar = function(parent)
  local bar = CreateFrame("StatusBar", nil, parent)
  bar:SetStatusBarTexture(QtP.media.statusbar)
  bar:SetMinMaxValues(0, 1)
  bar.bg = bar:CreateTexture(nil, "BACKGROUND")
  bar.bg:SetAllPoints(bar)
  bar.bg:SetTexture("Interface\\Buttons\\WHITE8X8")
  bar.bg:SetVertexColor(.10, .10, .10, .90)
  bar.left = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  bar.left:SetPoint("LEFT", bar, "LEFT", 4, 0)
  bar.left:SetJustifyH("LEFT")
  bar.right = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  bar.right:SetPoint("RIGHT", bar, "RIGHT", -4, 0)
  bar.right:SetJustifyH("RIGHT")
  QtP.ApplyBodyFont(bar.left)
  QtP.ApplyMutedFont(bar.right)
  return bar
end

local function ParkDetailBar(bar)
  if not bar then return end
  bar:ClearAllPoints()
  bar:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -4000, 4000)
  bar.spell = nil
  bar.click = nil
  bar.unit = nil
  bar.row = nil
  if bar.EnableMouse then bar:EnableMouse(false) end
  if bar.Hide then pcall(bar.Hide, bar) end
end

local function OverviewHeight()
  return TITLE_H + MAX_DETAIL * DETAIL_ROW + FOOTER_H + 10
end

local function FormatDiff(a, b)
  local d = (tonumber(a) or 0) - (tonumber(b) or 0)
  if d > 0 then return "+" .. ShortNumber(d) end
  if d < 0 then return "-" .. ShortNumber(-d) end
  return "="
end

local function DetailTag(view)
  if view == "heal" then return "Healing" end
  if view == "dps" then return "DPS" end
  return "Damage"
end

local function DetailStore()
  return GetActiveSegment({ view = detailView, segment = detailSegment })
end

local function UnionSpells(rowA, rowB)
  local seen = {}
  local spells = {}
  local function addFrom(row)
    if type(row) ~= "table" then return end
    local key
    for key in pairs(row) do
      if not INTERNALS[key] and not seen[key] then
        seen[key] = true
        table.insert(spells, key)
      end
    end
  end
  addFrom(rowA)
  addFrom(rowB)
  table.sort(spells, function(a, b)
    local ma, mb = 0, 0
    if rowA then
      ma = rowA[a] or 0
      mb = rowA[b] or 0
    end
    if rowB then
      local oa = rowB[a] or 0
      local ob = rowB[b] or 0
      if oa > ma then ma = oa end
      if ob > mb then mb = ob end
    end
    return mb < ma
  end)
  return spells
end

local function SpellRowsFor(unit, row, view)
  local rows = {}
  if not unit or not row then
    table.insert(rows, { label = "(no data)", value = 0, right = "" })
    return rows
  end
  local spells = SpellList(row)
  local sum = row._sum or 0
  local ctime = row._ctime or 1
  if ctime < 1 then ctime = 1 end
  local i
  local count = table.getn(spells)
  if count < 1 then
    table.insert(rows, { label = "(none)", value = 0, right = "" })
    return rows
  end
  for i = 1, count do
    local spell = spells[i]
    local amount = spell and (row[spell] or 0) or 0
    local pct = sum > 0 and (amount / sum * 100) or 0
    local hits, crits = SpellHits(row, spell)
    local right = ShortNumber(amount) .. "  " .. FormatRate(amount / ctime) .. "  " .. string.format("%.0f%%", pct)
    if hits > 0 then
      right = right .. "  " .. tostring(hits) .. "h"
      if crits > 0 then right = right .. "/" .. tostring(crits) .. "c" end
    end
    table.insert(rows, {
      label = spell or "(none)",
      value = amount,
      right = right,
      spell = spell,
      row = row,
      unit = unit,
      click = function()
        detailMode = "targets"
        detailSpell = spell
        RefreshOverview()
      end,
    })
  end
  return rows
end

local function CompareRows(unitA, rowA, unitB, rowB)
  local rows = {}
  local spells = UnionSpells(rowA, rowB)
  local i
  local count = table.getn(spells)
  if count < 1 then
    table.insert(rows, { label = "(none)", value = 0, right = "" })
    return rows
  end
  for i = 1, count do
    local spell = spells[i]
    local a = (rowA and spell and rowA[spell]) or 0
    local b = (rowB and spell and rowB[spell]) or 0
    local best = a
    if b > best then best = b end
    local tint = { .45, .45, .48 }
    if a > b then tint = { .25, .75, .30 } end
    if b > a then tint = { .75, .20, .18 } end
    table.insert(rows, {
      label = spell or "(none)",
      value = a,
      best = best,
      right = ShortNumber(a) .. "  " .. ShortNumber(b) .. "  " .. FormatDiff(a, b),
      color = tint,
      spell = spell,
      row = rowA,
      unit = unitA,
      click = function()
        detailMode = "targets"
        detailSpell = spell
        RefreshOverview()
      end,
    })
  end
  return rows
end

local function TargetRows(unit, spell, row)
  local rows = {}
  local hits = row and row._targets and row._targets[spell]
  local names = {}
  if hits then
    local dest
    for dest in pairs(hits) do table.insert(names, dest) end
    table.sort(names, function(a, b) return (hits[b] or 0) < (hits[a] or 0) end)
  end
  local total = (row and spell and row[spell]) or 0
  local i
  local count = table.getn(names)
  if count < 1 then
    table.insert(rows, { label = "(no targets)", value = 0, right = "" })
    return rows
  end
  for i = 1, count do
    local dest = names[i]
    local amount = dest and hits[dest] or 0
    local pct = total > 0 and (amount / total * 100) or 0
    table.insert(rows, {
      label = dest or "(no targets)",
      value = amount,
      right = dest and (ShortNumber(amount) .. "  " .. string.format("%.0f%%", pct)) or "",
    })
  end
  return rows
end

local function FillDetailBars(frame, rows, left, width, height, color, y0, offset)
  offset = tonumber(offset) or 0
  y0 = y0 or (TITLE_H + 20)
  local total = table.getn(rows)
  local best = 1
  local i
  for i = 1, total do
    local val = rows[i].best or rows[i].value or 0
    if val > best then best = val end
  end
  for i = 1, MAX_DETAIL do
    local bar = frame.bars[i]
    local spec = rows[i + offset]
    if spec then
      local y = y0 + (i - 1) * DETAIL_ROW
      PlaceBox(bar, frame, left, height - y - DETAIL_ROW + 2, width, DETAIL_ROW - 2)
      bar:SetMinMaxValues(0, best)
      bar:SetValue(spec.value or 0)
      local tint = spec.color or color
      bar:SetStatusBarColor(tint[1], tint[2], tint[3], .9)
      bar.left:SetText((i + offset) .. ". " .. (spec.label or ""))
      bar.right:SetText(spec.right or "")
      bar.spell = spec.spell
      bar.row = spec.row
      bar.unit = spec.unit
      bar.click = spec.click
      if bar.Show then pcall(bar.Show, bar) end
      if bar.EnableMouse then bar:EnableMouse(true) end
      bar:SetScript("OnMouseUp", function()
        if this.click then this.click() end
      end)
    else
      ParkDetailBar(bar)
    end
  end
end

local function LayoutCenterPanel(frame, width, height, title, hint)
  local sw = (UIParent.GetWidth and UIParent:GetWidth()) or 1024
  local sh = (UIParent.GetHeight and UIParent:GetHeight()) or 768
  if sw < 200 then sw = 1024 end
  if sh < 200 then sh = 768 end
  local left = math.floor((sw - width) / 2)
  local bottom = math.floor((sh - height) / 2)
  PlaceBox(frame, UIParent, left, bottom, width, height)
  frame.qtW = width
  frame.qtH = height
  frame.lastLeft = left
  frame.lastBottom = bottom
  PlaceBox(frame.close, frame, width - 22, height - 20, 16, 16)
  frame.title:ClearAllPoints()
  frame.title:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 10, height - 16)
  frame.title:SetPoint("TOPRIGHT", frame, "BOTTOMLEFT", width - 28, height - 4)
  frame.title:SetText(title or "")
  if hint and hint ~= "" then
    frame.hint:ClearAllPoints()
    frame.hint:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 10, height - TITLE_H - 2)
    frame.hint:SetText(hint)
  else
    frame.hint:SetText("")
    frame.hint:ClearAllPoints()
    frame.hint:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -4000, 4000)
  end
  if frame.EnableMouse then frame:EnableMouse(true) end
  frame.qtShowing = true
  if frame.Show then pcall(frame.Show, frame) end
  frame.qtShowing = nil
end

local function SelectOverviewPlayer(name)
  if not name then return end
  if detailPick then
    if name ~= detailUnit then
      detailCmp = name
    end
    detailPick = nil
    detailMode = "spells"
    RefreshOverview()
    return
  end
  if name == detailUnit then
    detailMode = "spells"
    detailSpell = nil
    RefreshOverview()
    return
  end
  detailUnit = name
  if detailCmp == name then detailCmp = nil end
  detailMode = "spells"
  detailSpell = nil
  RefreshOverview()
end

local function ToggleCompare()
  if detailCmp or detailPick then
    detailCmp = nil
    detailPick = nil
    detailMode = "spells"
    RefreshOverview()
    return
  end
  detailPick = true
  RefreshOverview()
end

local function EnsureSpellDetails()
  if detailFrame then return detailFrame end
  local frame = CreateFrame("Frame", "QtPMeterDetails", UIParent)
  frame:SetFrameStrata("FULLSCREEN")
  frame:SetFrameLevel(180)
  QtP.PaintPanel(frame)
  frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  frame.title:SetJustifyH("LEFT")
  QtP.ApplyTitleFont(frame.title)
  frame.hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  QtP.ApplyMutedFont(frame.hint)
  frame.sub = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  frame.sub:SetJustifyH("LEFT")
  QtP.ApplyBodyFont(frame.sub)
  frame.split = frame:CreateTexture(nil, "ARTWORK")
  frame.split:SetTexture("Interface\\Buttons\\WHITE8X8")
  do
    local border = QtUiPlus.media.color.border
    frame.split:SetVertexColor(border[1], border[2], border[3], 1)
  end
  frame.close = QtP.AttachCloseButton(frame, HideSpellDetails)
  frame.compare = CreateFrame("Button", nil, frame)
  frame.compare:EnableMouse(true)
  frame.compare:RegisterForClicks("LeftButtonUp")
  QtP.PaintSurface(frame.compare)
  frame.compare.text = frame.compare:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  frame.compare.text:SetPoint("CENTER", frame.compare, "CENTER", 0, 0)
  frame.compare.text:SetText("Compare")
  QtP.ApplyBodyFont(frame.compare.text)
  frame.compare:SetScript("OnEnter", function()
    QtP.PaintHover(this)
  end)
  frame.compare:SetScript("OnLeave", function()
    QtP.PaintSurface(this)
  end)
  frame.compare:SetScript("OnClick", ToggleCompare)
  frame.roster = {}
  frame.bars = {}
  local i
  for i = 1, MAX_ROSTER do
    local bar = MakeDetailBar(frame)
    bar:EnableMouse(true)
    if bar.RegisterForClicks then bar:RegisterForClicks("LeftButtonUp") end
    bar:SetScript("OnMouseUp", function()
      if this.unit then SelectOverviewPlayer(this.unit) end
    end)
    if bar.EnableMouseWheel then bar:EnableMouseWheel(1) end
    bar:SetScript("OnMouseWheel", function()
      local delta = tonumber(arg1) or 0
      if delta > 0 then delta = 1 else delta = -1 end
      detailRosterScroll = (detailRosterScroll or 0) - delta
      RefreshOverview()
    end)
    frame.roster[i] = bar
  end
  for i = 1, MAX_DETAIL do
    local bar = MakeDetailBar(frame)
    if bar.EnableMouseWheel then bar:EnableMouseWheel(1) end
    bar:SetScript("OnMouseWheel", function()
      local delta = tonumber(arg1) or 0
      if delta > 0 then delta = 1 else delta = -1 end
      detailSpellScroll = (detailSpellScroll or 0) - delta
      RefreshOverview()
    end)
    frame.bars[i] = bar
  end
  if frame.EnableMouseWheel then frame:EnableMouseWheel(1) end
  frame:SetScript("OnMouseWheel", function()
    local delta = tonumber(arg1) or 0
    if delta > 0 then delta = 1 else delta = -1 end
    detailSpellScroll = (detailSpellScroll or 0) - delta
    RefreshOverview()
  end)
  if UISpecialFrames then table.insert(UISpecialFrames, "QtPMeterDetails") end
  frame:SetScript("OnHide", HideSpellDetails)
  detailFrame = frame
  ParkPopup(frame)
  return frame
end

local overviewBusy
RefreshOverview = function()
  if not detailOpen or overviewBusy then return end
  overviewBusy = true
  local frame = EnsureSpellDetails()
  local segment = DetailStore()
  local byRate = detailView == "dps"
  local keys = SortedNames(segment, byRate)
  if not detailUnit or not segment[detailUnit] then
    detailUnit = keys[1]
  end
  if detailCmp and not segment[detailCmp] then
    detailCmp = nil
  end
  if detailCmp == detailUnit then detailCmp = nil end
  local width = DETAIL_W
  local height = OverviewHeight()
  local tag = DetailTag(detailView)
  local title = tag .. " overview"
  if detailPick then
    title = "Click a second player"
  elseif detailCmp then
    title = tag .. " compare"
  elseif detailMode == "targets" then
    title = tag .. " targets"
  end
  if not frame._placed then
    LayoutCenterPanel(frame, width, height, title, "")
    frame._placed = true
    PlaceBox(frame.split, frame, 8 + ROSTER_W + 4, 8, 1, height - TITLE_H - 10)
    PlaceBox(frame.compare, frame, 8, 6, ROSTER_W, 16)
  else
    if frame.title then frame.title:SetText(title) end
    if frame.EnableMouse then frame:EnableMouse(true) end
    if frame.Show then pcall(frame.Show, frame) end
  end
  frame.title:ClearAllPoints()
  frame.title:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 10, height - 16)
  frame.title:SetPoint("TOPRIGHT", frame, "BOTTOMLEFT", 8 + ROSTER_W, height - 4)
  if frame.close and frame.close.SetFrameLevel then frame.close:SetFrameLevel(190) end
  if frame.compare and frame.compare.SetFrameLevel then frame.compare:SetFrameLevel(190) end
  if frame.compare.text then
    if detailCmp or detailPick then
      frame.compare.text:SetText("Clear vs")
    else
      frame.compare.text:SetText("Compare")
    end
  end
  if frame.compare.EnableMouse then frame.compare:EnableMouse(true) end
  if frame.compare.Show then pcall(frame.compare.Show, frame.compare) end

  local total = 0
  local rosterBest = 1
  local n
  for n = 1, table.getn(keys) do
    local row = segment[keys[n]]
    local sum = (row and row._sum) or 0
    total = total + sum
    local ctime = (row and row._ctime) or 1
    if ctime < 1 then ctime = 1 end
    local val = sum
    if byRate then val = sum / ctime end
    if val > rosterBest then rosterBest = val end
  end
  local rosterMax = table.getn(keys) - MAX_ROSTER
  if rosterMax < 0 then rosterMax = 0 end
  if detailRosterScroll < 0 then detailRosterScroll = 0 end
  if detailRosterScroll > rosterMax then detailRosterScroll = rosterMax end
  local listTop = TITLE_H + 4
  for n = 1, MAX_ROSTER do
    local bar = frame.roster[n]
    local name = keys[n + detailRosterScroll]
    local row = name and segment[name] or nil
    if name and row then
      local y = listTop + (n - 1) * DETAIL_ROW
      PlaceBox(bar, frame, 8, height - y - DETAIL_ROW + 2, ROSTER_W, DETAIL_ROW - 2)
      local sum = row._sum or 0
      local ctime = row._ctime or 1
      if ctime < 1 then ctime = 1 end
      local rate = sum / ctime
      local pct = total > 0 and (sum / total * 100) or 0
      bar:SetMinMaxValues(0, rosterBest)
      if byRate then
        bar:SetValue(rate)
        bar.right:SetText(FormatRate(rate))
      else
        bar:SetValue(sum)
        bar.right:SetText(ShortNumber(sum) .. "  " .. string.format("%.0f%%", pct))
      end
      local r, g, b = ClassColor(name)
      local label = (n + detailRosterScroll) .. ". " .. name
      if name == detailUnit then
        bar:SetStatusBarColor(r, g, b, .95)
        label = "> " .. label
      elseif name == detailCmp then
        bar:SetStatusBarColor(.96, .68, .04, .95)
        label = "vs " .. label
      else
        bar:SetStatusBarColor(r * .7, g * .7, b * .7, .75)
      end
      bar.left:SetText(label)
      bar.unit = name
      bar.row = row
      if bar.Show then pcall(bar.Show, bar) end
      if bar.EnableMouse then bar:EnableMouse(true) end
    else
      ParkDetailBar(bar)
    end
  end

  local rowA = detailUnit and segment[detailUnit] or nil
  local rowB = detailCmp and segment[detailCmp] or nil
  local paneLeft = 8 + ROSTER_W + 10
  local paneW = width - paneLeft - 8
  local sub = ""
  if detailUnit and rowA then
    local sum = rowA._sum or 0
    local ctime = rowA._ctime or 1
    if ctime < 1 then ctime = 1 end
    sub = detailUnit .. "  " .. ShortNumber(sum) .. "  " .. FormatRate(sum / ctime)
    if detailCmp and rowB and detailMode ~= "targets" then
      local sumB = rowB._sum or 0
      local ctimeB = rowB._ctime or 1
      if ctimeB < 1 then ctimeB = 1 end
      sub = detailUnit .. " vs " .. detailCmp .. "  " .. ShortNumber(sum) .. " / " .. ShortNumber(sumB) .. "  " .. FormatDiff(sum, sumB)
    elseif detailMode == "targets" and detailSpell then
      sub = detailUnit .. "  -  " .. detailSpell .. " hits"
    end
  else
    sub = "No player selected"
  end
  frame.sub:ClearAllPoints()
  frame.sub:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", paneLeft, height - 16)
  frame.sub:SetPoint("TOPRIGHT", frame, "BOTTOMLEFT", width - 22, height - 4)
  frame.sub:SetText(sub)

  local rows
  local tint = { .45, .45, .48 }
  if detailMode == "targets" and detailUnit and detailSpell and rowA then
    rows = TargetRows(detailUnit, detailSpell, rowA)
    tint = { .96, .68, .04 }
  elseif detailCmp and rowA then
    rows = CompareRows(detailUnit, rowA, detailCmp, rowB)
  else
    rows = SpellRowsFor(detailUnit, rowA, detailView)
    if detailUnit then
      local r, g, b = ClassColor(detailUnit)
      tint = { r, g, b }
    end
  end
  local spellMax = table.getn(rows) - MAX_DETAIL
  if spellMax < 0 then spellMax = 0 end
  if detailSpellScroll < 0 then detailSpellScroll = 0 end
  if detailSpellScroll > spellMax then detailSpellScroll = spellMax end
  FillDetailBars(frame, rows, paneLeft, paneW, height, tint, TITLE_H + 4, detailSpellScroll)
  overviewBusy = nil
end

local function ShowSpellTargets(unit, spell, row)
  if not unit or not spell then return end
  detailUnit = unit
  detailMode = "targets"
  detailSpell = spell
  detailOpen = true
  RefreshOverview()
end

ShowSpellDetails = function(unit, row, viewOrFrame)
  if not unit then return end
  if type(viewOrFrame) == "table" then
    detailView = viewOrFrame.view or "damage"
    detailSegment = viewOrFrame.segment or 1
  elseif type(viewOrFrame) == "string" then
    detailView = viewOrFrame
  end
  detailUnit = unit
  detailCmp = nil
  detailPick = nil
  detailMode = "spells"
  detailSpell = nil
  detailRosterScroll = 0
  detailSpellScroll = 0
  EnsureSpellDetails()
  detailOpen = true
  if not pcall(RefreshOverview) then overviewBusy = nil end
end

local FIGHTS_PER_PAGE = 10
local FIGHT_ROW = 20
local FIGHT_W = 300
local fightPage = 1
local fightPicker

local fightOpen

local function HideFightMenu()
  fightOpen = nil
  SafeHidePopup(fightPicker)
end

local function FightRows()
  local rows = { { label = "Current fight", index = nil } }
  local i
  for i = 1, table.getn(history) do
    local snap = history[i]
    local extra = snap.name .. "  " .. FormatDuration(snap.duration)
    local dead = snap.deaths and table.getn(snap.deaths) or 0
    if dead > 0 then extra = extra .. "  (" .. tostring(dead) .. " dead)" end
    table.insert(rows, { label = extra, index = i })
  end
  return rows
end

local function SelectFight(index)
  viewing = index
  HideFightMenu()
  MarkMetersDirty()
  local i
  for i = 1, table.getn(QtP.meterFrames or {}) do
    -- Not RefreshMeter(): that local is declared ~540 lines below this point,
    -- so the bare name here would bind to the global of that name, which is
    -- nil. Inherited from QtUI, where picking a fight from the list errors.
    -- A `local RefreshMeter` forward declaration is the usual fix and is not
    -- available here: this chunk sits at exactly 200 top-level locals, Lua
    -- 5.1's hard cap, with zero headroom. The reference goes through QtP
    -- instead, assigned at the definition site, which runs at load time --
    -- long before any click can reach this line.
    if QtP.RefreshMeterWindow then
      QtP.RefreshMeterWindow(QtP.meterFrames[i])
    end
  end
end

local function EnsureFightPicker()
  if fightPicker then return fightPicker end
  local frame = CreateFrame("Frame", "QtPMeterFights", UIParent)
  frame:SetFrameStrata("FULLSCREEN")
  frame:SetFrameLevel(185)
  QtP.PaintPanel(frame)
  frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  frame.title:SetJustifyH("LEFT")
  QtP.ApplyTitleFont(frame.title)
  frame.hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  QtP.ApplyMutedFont(frame.hint)
  frame.close = QtP.AttachCloseButton(frame, HideFightMenu)
  frame.rows = {}
  local i
  for i = 1, FIGHTS_PER_PAGE do
    local btn = CreateFrame("Button", nil, frame)
    btn:EnableMouse(true)
    btn:RegisterForClicks("LeftButtonUp")
    QtP.PaintSurface(btn)
    btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    btn.text:SetPoint("LEFT", btn, "LEFT", 8, 0)
    btn.text:SetJustifyH("LEFT")
    QtP.ApplyBodyFont(btn.text)
    btn:SetScript("OnEnter", function()
      QtP.PaintHover(this)
    end)
    btn:SetScript("OnLeave", function()
      QtP.PaintSurface(this)
    end)
    btn:SetScript("OnClick", function()
      SelectFight(this.fightIndex)
    end)
    frame.rows[i] = btn
  end
  frame.prev = CreateFrame("Button", nil, frame)
  frame.prev:EnableMouse(true)
  frame.prev:RegisterForClicks("LeftButtonUp")
  frame.prev.text = frame.prev:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  frame.prev.text:SetPoint("CENTER", frame.prev, "CENTER", 0, 0)
  frame.prev.text:SetText("<")
  QtP.ApplyBodyFont(frame.prev.text)
  frame.prev:SetScript("OnClick", function()
    if fightPage > 1 then
      fightPage = fightPage - 1
      if QtP.ShowFightPage then QtP.ShowFightPage() end
    end
  end)
  frame.next = CreateFrame("Button", nil, frame)
  frame.next:EnableMouse(true)
  frame.next:RegisterForClicks("LeftButtonUp")
  frame.next.text = frame.next:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  frame.next.text:SetPoint("CENTER", frame.next, "CENTER", 0, 0)
  frame.next.text:SetText(">")
  QtP.ApplyBodyFont(frame.next.text)
  frame.next:SetScript("OnClick", function()
    fightPage = fightPage + 1
    if QtP.ShowFightPage then QtP.ShowFightPage() end
  end)
  frame.page = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  frame.page:SetJustifyH("CENTER")
  if UISpecialFrames then table.insert(UISpecialFrames, "QtPMeterFights") end
  frame:SetScript("OnHide", HideFightMenu)
  fightPicker = frame
  ParkPopup(frame)
  return frame
end

local function ShowFightPage()
  local frame = EnsureFightPicker()
  local rows = FightRows()
  local total = table.getn(rows)
  local pages = math.floor((total - 1) / FIGHTS_PER_PAGE) + 1
  if pages < 1 then pages = 1 end
  if fightPage < 1 then fightPage = 1 end
  if fightPage > pages then fightPage = pages end
  local first = (fightPage - 1) * FIGHTS_PER_PAGE + 1
  local last = first + FIGHTS_PER_PAGE - 1
  if last > total then last = total end
  local visible = last - first + 1
  if visible < 1 then visible = 1 end
  local showPager = total > FIGHTS_PER_PAGE
  local pagerH = 0
  if showPager then pagerH = 24 end
  local width = FIGHT_W
  local height = TITLE_H + 12 + visible * FIGHT_ROW + pagerH + 8
  LayoutCenterPanel(frame, width, height, "Fights", "Select a fight.")
  local i
  for i = 1, FIGHTS_PER_PAGE do
    local btn = frame.rows[i]
    local spec = rows[first + i - 1]
    if spec and i <= visible then
      local y = TITLE_H + 8 + (i - 1) * FIGHT_ROW
      PlaceBox(btn, frame, 10, height - y - FIGHT_ROW + 2, width - 20, FIGHT_ROW - 3)
      btn.fightIndex = spec.index
      local active = (viewing == spec.index) or (not viewing and not spec.index)
      if active then
        btn.text:SetText("|cffffd24d" .. spec.label .. "|r")
      else
        btn.text:SetText(spec.label)
      end
      if btn.Show then pcall(btn.Show, btn) end
      if btn.EnableMouse then btn:EnableMouse(true) end
    else
      btn.fightIndex = nil
      btn:ClearAllPoints()
      btn:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -4000, 4000)
      if btn.EnableMouse then btn:EnableMouse(false) end
    end
  end
  if showPager then
    PlaceBox(frame.prev, frame, 10, 8, 28, 18)
    PlaceBox(frame.next, frame, width - 38, 8, 28, 18)
    frame.page:ClearAllPoints()
    frame.page:SetPoint("CENTER", frame, "BOTTOMLEFT", width / 2, 17)
    frame.page:SetText(tostring(fightPage) .. " / " .. tostring(pages))
    if frame.prev.Show then pcall(frame.prev.Show, frame.prev) end
    if frame.next.Show then pcall(frame.next.Show, frame.next) end
    if frame.prev.EnableMouse then frame.prev:EnableMouse(fightPage > 1) end
    if frame.next.EnableMouse then frame.next:EnableMouse(fightPage < pages) end
  else
    frame.prev:ClearAllPoints()
    frame.prev:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -4000, 4000)
    frame.next:ClearAllPoints()
    frame.next:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -4000, 4000)
    frame.page:ClearAllPoints()
    frame.page:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -4000, 4000)
    if frame.prev.EnableMouse then frame.prev:EnableMouse(false) end
    if frame.next.EnableMouse then frame.next:EnableMouse(false) end
  end
end
QtP.ShowFightPage = ShowFightPage

local function ToggleFightMenu(anchor)
  if HideReportMenu then HideReportMenu() end
  if QtP.HideMeterModeMenu then QtP.HideMeterModeMenu() end
  if fightOpen then
    HideFightMenu()
    return
  end
  fightPage = 1
  fightOpen = true
  ShowFightPage()
end

function QtP:FillMeterDemo()
  local kits = {
    WARRIOR = {
      dmg = {
        { "Mortal Strike", 22 }, { "Heroic Strike", 16 }, { "Whirlwind", 14 },
        { "Bloodthirst", 12 }, { "Execute", 10 }, { "Cleave", 8 },
        { "Overpower", 6 }, { "Slam", 5 }, { "Deep Wounds", 4 }, { "Auto Hit", 18 },
      },
      heal = {},
    },
    ROGUE = {
      dmg = {
        { "Backstab", 20 }, { "Sinister Strike", 16 }, { "Eviscerate", 14 },
        { "Ambush", 10 }, { "Hemorrhage", 8 }, { "Rupture", 7 },
        { "Ghostly Strike", 6 }, { "Instant Poison", 8 }, { "Deadly Poison", 6 }, { "Auto Hit", 12 },
      },
      heal = {},
    },
    MAGE = {
      dmg = {
        { "Fireball", 24 }, { "Scorch", 10 }, { "Pyroblast", 12 }, { "Fire Blast", 8 },
        { "Frostbolt", 18 }, { "Cone of Cold", 6 }, { "Blizzard", 8 },
        { "Arcane Explosion", 7 }, { "Arcane Missiles", 9 }, { "Auto Hit", 3 },
      },
      heal = {},
    },
    PRIEST = {
      dmg = {
        { "Mind Blast", 18 }, { "Mind Flay", 16 }, { "Shadow Word: Pain", 14 },
        { "Smite", 10 }, { "Holy Fire", 8 }, { "Devouring Plague", 6 }, { "Starshards", 5 },
      },
      heal = {
        { "Flash Heal", 22 }, { "Greater Heal", 20 }, { "Heal", 12 },
        { "Renew", 14 }, { "Prayer of Healing", 16 }, { "Power Word: Shield", 8 },
      },
    },
    WARLOCK = {
      dmg = {
        { "Shadow Bolt", 24 }, { "Immolate", 12 }, { "Corruption", 12 },
        { "Curse of Agony", 10 }, { "Searing Pain", 8 }, { "Conflagrate", 7 },
        { "Siphon Life", 6 }, { "Death Coil", 5 }, { "Rain of Fire", 8 }, { "Auto Hit", 3 },
      },
      heal = { { "Drain Life", 10 }, { "Death Coil", 4 } },
    },
    HUNTER = {
      dmg = {
        { "Aimed Shot", 22 }, { "Auto Shot", 18 }, { "Multi-Shot", 12 },
        { "Arcane Shot", 10 }, { "Serpent Sting", 10 }, { "Volley", 8 },
        { "Raptor Strike", 6 }, { "Mongoose Bite", 4 }, { "Auto Hit", 5 },
      },
      heal = {},
    },
    DRUID = {
      dmg = {
        { "Starfire", 20 }, { "Wrath", 14 }, { "Moonfire", 12 }, { "Insect Swarm", 8 },
        { "Hurricane", 8 }, { "Shred", 10 }, { "Ferocious Bite", 8 },
        { "Rake", 5 }, { "Rip", 6 }, { "Maul", 7 }, { "Auto Hit", 6 },
      },
      heal = {
        { "Healing Touch", 22 }, { "Rejuvenation", 16 }, { "Regrowth", 14 },
        { "Tranquility", 10 }, { "Swiftmend", 8 },
      },
    },
    SHAMAN = {
      dmg = {
        { "Lightning Bolt", 20 }, { "Chain Lightning", 16 }, { "Earth Shock", 10 },
        { "Flame Shock", 10 }, { "Stormstrike", 12 }, { "Frost Shock", 6 },
        { "Searing Totem", 8 }, { "Magma Totem", 6 }, { "Auto Hit", 8 },
      },
      heal = {
        { "Healing Wave", 20 }, { "Lesser Healing Wave", 16 }, { "Chain Heal", 18 },
        { "Healing Stream Totem", 8 },
      },
    },
    PALADIN = {
      dmg = {
        { "Seal of Command", 18 }, { "Judgement", 16 }, { "Consecration", 14 },
        { "Hammer of Wrath", 10 }, { "Exorcism", 8 }, { "Holy Wrath", 6 }, { "Auto Hit", 16 },
      },
      heal = {
        { "Flash of Light", 22 }, { "Holy Light", 20 }, { "Holy Shock", 12 }, { "Lay on Hands", 6 },
      },
    },
  }

  local function BuildRow(parts, total, duration, dests)
    local row = { _sum = 0, _ctime = duration or 30, _hits = {}, _crits = {}, _targets = {} }
    if type(parts) ~= "table" or table.getn(parts) < 1 or total < 1 then return row end
    local weight = 0
    local i
    for i = 1, table.getn(parts) do
      weight = weight + (parts[i][2] or 1)
    end
    if weight < 1 then weight = 1 end
    for i = 1, table.getn(parts) do
      local spec = parts[i]
      local spell = spec[1]
      local share = math.floor(total * (spec[2] or 1) / weight)
      if share < 1 then share = 1 end
      row[spell] = (row[spell] or 0) + share
      row._sum = row._sum + share
      local hits = math.floor(4 + share / 420)
      if hits < 3 then hits = 3 end
      local crits = math.floor(hits * .22)
      row._hits[spell] = hits
      row._crits[spell] = crits
      row._targets[spell] = {}
      if dests and table.getn(dests) > 0 then
        local d
        local left = share
        for d = 1, table.getn(dests) do
          local slice = math.floor(share / table.getn(dests))
          if d == table.getn(dests) then slice = left end
          left = left - slice
          row._targets[spell][dests[d]] = slice
        end
      end
    end
    return row
  end

  local function ScaleRow(row, factor, duration)
    local out = CopyTableDeep(row, 3)
    out._ctime = duration or out._ctime
    out._sum = math.floor((out._sum or 0) * factor)
    local k, v
    for k, v in pairs(out) do
      if not INTERNALS[k] and type(v) == "number" then
        out[k] = math.floor(v * factor)
      end
    end
    if out._hits then
      for k, v in pairs(out._hits) do
        out._hits[k] = math.floor(v * factor)
        if out._hits[k] < 1 then out._hits[k] = 1 end
      end
    end
    if out._crits then
      for k, v in pairs(out._crits) do
        out._crits[k] = math.floor(v * factor)
      end
    end
    if out._targets then
      local spell, dests
      for spell, dests in pairs(out._targets) do
        local dest, amt
        for dest, amt in pairs(dests) do
          dests[dest] = math.floor(amt * factor)
        end
      end
    end
    return out
  end

  local roster = {
    { "Thrall", "SHAMAN", 16800, 9200 },
    { "Jaina", "MAGE", 17600, 0 },
    { "Sylvanas", "HUNTER", 15400, 0 },
    { "Anduin", "PRIEST", 4200, 14800 },
    { "Valeera", "ROGUE", 16100, 0 },
    { "Medivh", "MAGE", 14900, 0 },
    { "Tyrande", "DRUID", 13200, 11200 },
    { "Gul'dan", "WARLOCK", 15800, 1800 },
    { "Uther", "PALADIN", 9800, 12600 },
    { "Garrosh", "WARRIOR", 17100, 0 },
    { "Cairne", "WARRIOR", 14200, 0 },
    { "Proudmoore", "MAGE", 13900, 0 },
    { "Vol'jin", "SHAMAN", 12100, 6400 },
    { "Malfurion", "DRUID", 10800, 9800 },
  }

  data.damage[0] = {}
  data.damage[1] = {}
  data.heal[0] = {}
  data.heal[1] = {}
  data.classes = {}

  local i
  for i = 1, table.getn(roster) do
    local spec = roster[i]
    local name, class, dmg, heal = spec[1], spec[2], spec[3], spec[4]
    local kit = kits[class] or kits.WARRIOR
    data.classes[name] = class
    data.damage[1][name] = BuildRow(kit.dmg, dmg, 48, { "Onyxia" })
    data.heal[1][name] = BuildRow(kit.heal, heal, 48, { name, "Thrall", "Garrosh" })
    data.damage[0][name] = ScaleRow(data.damage[1][name], 3.4, 214)
    data.heal[0][name] = ScaleRow(data.heal[1][name], 3.4, 214)
  end

  local me = UnitName and UnitName("player")
  if me and me ~= "" then
    local _, class = UnitClass("player")
    if not class or not kits[class] then class = "DRUID" end
    data.classes[me] = class
    local kit = kits[class]
    data.damage[1][me] = BuildRow(kit.dmg, 18200, 48, { "Onyxia" })
    data.heal[1][me] = BuildRow(kit.heal, 7600, 48, { me, "Thrall" })
    data.damage[0][me] = ScaleRow(data.damage[1][me], 3.4, 214)
    data.heal[0][me] = ScaleRow(data.heal[1][me], 3.4, 214)
  end

  local fights = {
    { "Onyxia", 186, 1.00, { "Onyxia" }, { { "Anduin", 64 }, { "Valeera", 141 } } },
    { "Ragnaros", 312, 1.35, { "Ragnaros" }, { { "Jaina", 88 }, { "Anduin", 140 }, { "Medivh", 201 } } },
    { "Majordomo Executus", 154, .82, { "Majordomo Executus", "Flamewaker Elite" }, { { "Proudmoore", 71 } } },
    { "Garr", 128, .74, { "Garr", "Firesworn" }, {} },
    { "Baron Geddon", 96, .68, { "Baron Geddon" }, { { "Thrall", 44 }, { "Uther", 80 } } },
    { "Magmadar", 118, .71, { "Magmadar" }, { { "Cairne", 52 } } },
    { "Lucifron", 64, .55, { "Lucifron", "Flamewaker Protector" }, {} },
    { "Gehennas", 72, .58, { "Gehennas" }, { { "Vol'jin", 39 } } },
    { "Shazzrah", 58, .50, { "Shazzrah" }, {} },
    { "Sulfuron Harbinger", 88, .62, { "Sulfuron Harbinger" }, { { "Malfurion", 61 } } },
    { "Golemagg the Incinerator", 142, .79, { "Golemagg the Incinerator" }, { { "Sylvanas", 97 } } },
    { "Vaelastrasz the Corrupt", 76, .88, { "Vaelastrasz the Corrupt" }, { { "Garrosh", 22 }, { "Jaina", 41 }, { "Anduin", 55 } } },
    { "Razorgore the Untamed", 204, .66, { "Razorgore the Untamed" }, { { "Valeera", 110 } } },
    { "Chromaggus", 168, .91, { "Chromaggus" }, { { "Tyrande", 73 }, { "Medivh", 119 } } },
    { "Nefarian", 248, 1.22, { "Nefarian" }, { { "Anduin", 90 }, { "Uther", 133 }, { "Gul'dan", 188 } } },
    { "Core Hound Pack", 38, .32, { "Core Hound", "Ancient Core Hound" }, {} },
    { "Molten Giant", 44, .36, { "Molten Giant" }, {} },
    { "Lava Surger", 29, .28, { "Lava Surger" }, {} },
  }

  history = {}
  local f
  for f = 1, table.getn(fights) do
    local spec = fights[f]
    local dmg, heal = {}, {}
    for i = 1, table.getn(roster) do
      local who = roster[i][1]
      if data.damage[1][who] then
        dmg[who] = ScaleRow(data.damage[1][who], spec[3], spec[2])
        local spell, dests
        for spell, dests in pairs(dmg[who]._targets or {}) do
          dmg[who]._targets[spell] = {}
          local d
          for d = 1, table.getn(spec[4]) do
            dmg[who]._targets[spell][spec[4][d]] = math.floor((dmg[who][spell] or 0) / table.getn(spec[4]))
          end
        end
      end
      if data.heal[1][who] then
        heal[who] = ScaleRow(data.heal[1][who], spec[3] * .9, spec[2])
      end
    end
    if me and data.damage[1][me] then
      dmg[me] = ScaleRow(data.damage[1][me], spec[3], spec[2])
      heal[me] = ScaleRow(data.heal[1][me], spec[3] * .9, spec[2])
    end
    table.insert(history, {
      name = spec[1],
      duration = spec[2],
      damage = dmg,
      heal = heal,
      deaths = spec[5],
    })
  end
  viewing = nil
  MarkMetersDirty()
  if self.ApplyDamageMeterLayout then self:ApplyDamageMeterLayout() end
end

local function ResetSegment(segmentId)
  segmentId = tonumber(segmentId)
  if segmentId ~= 0 and segmentId ~= 1 then return end
  data.damage[segmentId] = {}
  data.heal[segmentId] = {}
  MarkMetersDirty()
  PersistMeters()
end

PersistMeters = function()
  if not QtP.GetLayout then return end
  local layout = QtP:GetLayout()
  if not layout then return end
  layout.meterWindows = {}
  local frames = QtP.meterFrames
  if frames then
    local i
    for i = 1, table.getn(frames) do
      local frame = frames[i]
      table.insert(layout.meterWindows, {
        id = frame.meterId,
        view = frame.view,
        segment = frame.segment,
      })
    end
  end
  if not QtPDB then return end
  QtPDB.meter = {
    damage = CopyTableDeep(data.damage, 5),
    heal = CopyTableDeep(data.heal, 5),
    classes = CopyTableDeep(data.classes, 3),
    history = CopyTableDeep(history, 5),
    viewing = viewing,
  }
end

LoadMeterState = function()
  local snap = QtPDB and QtPDB.meter
  if type(snap) ~= "table" then return end
  if type(snap.damage) == "table" then
    data.damage = snap.damage
    if type(data.damage[0]) ~= "table" then data.damage[0] = {} end
    if type(data.damage[1]) ~= "table" then data.damage[1] = {} end
  end
  if type(snap.heal) == "table" then
    data.heal = snap.heal
    if type(data.heal[0]) ~= "table" then data.heal[0] = {} end
    if type(data.heal[1]) ~= "table" then data.heal[1] = {} end
  end
  if type(snap.classes) == "table" then data.classes = snap.classes end
  if type(snap.history) == "table" then history = snap.history end
  viewing = snap.viewing
end

local function MeterLayout()
  local width, bars, barH, spacing = 190, 8, 16, 0
  if QtP.GetLayout then
    local layout = QtP:GetLayout()
    if layout then
      width = tonumber(layout.meterWidth) or width
      bars = tonumber(layout.meterBars) or bars
      barH = tonumber(layout.meterBarHeight) or barH
      spacing = tonumber(layout.meterBarSpacing) or spacing
    end
  end
  if width < 140 then width = 140 end
  if width > 400 then width = 400 end
  if bars < MIN_BARS then bars = MIN_BARS end
  if bars > MAX_BARS then bars = MAX_BARS end
  if barH < 12 then barH = 12 end
  if barH > 24 then barH = 24 end
  if spacing < 0 then spacing = 0 end
  if spacing > 8 then spacing = 8 end
  local height = TITLE_H + bars * barH + (bars - 1) * spacing + METER_PAD
  return width, height, bars, barH, spacing
end

local function SizeMeterFrame(frame, width, height)
  if not frame then return end
  frame.qtW = width
  frame.qtH = height
  if frame.SetWidth then
    frame:SetWidth(width + 1)
    if frame.SetHeight then frame:SetHeight(height + 1) end
    frame:SetWidth(width)
    if frame.SetHeight then frame:SetHeight(height) end
  end
end

local function PlaceBar(bar, frame, index, barH, visible, spacing)
  if not bar then return end
  if index <= visible then
    spacing = spacing or 0
    local y = TITLE_H + (index - 1) * (barH + spacing)
    bar:ClearAllPoints()
    bar:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, -y)
    bar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -y)
    bar:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 4, -(y + barH))
    if bar.SetHeight then
      bar:SetHeight(barH + 1)
      bar:SetHeight(barH)
    end
    if bar.EnableMouse then bar:EnableMouse(true) end
    if bar.SetAlpha then bar:SetAlpha(1) end
    if bar.Show then pcall(bar.Show, bar) end
  else
    bar:ClearAllPoints()
    bar:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -2000, 2000)
    if bar.EnableMouse then bar:EnableMouse(false) end
    if bar.SetAlpha then bar:SetAlpha(0) end
  end
end

-- Published on QtP as RefreshMeterWindow just below, for SelectFight further
-- up the file, which cannot see this local. Do not rename without updating it.
local function RefreshMeter(frame)
  if not frame then return end
  local view = frame.view or "damage"
  local segmentId = frame.segment or 1
  local segment = GetActiveSegment(frame)
  local byRate = view == "dps"
  local keys = SortedNames(segment, byRate)
  local best = 0
  local bestRate = 0
  local total = 0
  local n
  for n = 1, table.getn(keys) do
    local row = segment[keys[n]]
    local sum = row._sum or 0
    local ctime = row._ctime or 1
    if ctime < 1 then ctime = 1 end
    local rate = sum / ctime
    total = total + sum
    if sum > best then best = sum end
    if rate > bestRate then bestRate = rate end
  end
  if best < 1 then best = 1 end
  if bestRate < .01 then bestRate = 1 end

  if frame.titleText then
    local title = ModeLabel(view, segmentId)
    if segmentId == 1 and viewing and history[viewing] then
      local tag = "Dmg"
      if view == "dps" then tag = "DPS" end
      if view == "heal" then tag = "Heal" end
      title = history[viewing].name .. " " .. tag
    end
    local dur = ActiveFightDuration(frame)
    if dur and dur >= 1 then
      title = title .. "  " .. FormatDuration(dur)
    end
    frame.titleText:SetText(title)
  end

  local _, _, visible = MeterLayout()
  local totalKeys = table.getn(keys)
  local maxScroll = totalKeys - visible
  if maxScroll < 0 then maxScroll = 0 end
  local offset = tonumber(frame.scroll) or 0
  if offset < 0 then offset = 0 end
  if offset > maxScroll then offset = maxScroll end
  frame.scroll = offset
  for n = 1, MAX_BARS do
    local bar = frame.bars[n]
    if bar then
      local rank = n + offset
      local name = n <= visible and keys[rank] or nil
      if name and segment[name] then
        local row = segment[name]
        local sum = row._sum or 0
        local ctime = row._ctime or 1
        if ctime < 1 then ctime = 1 end
        local rate = sum / ctime
        local pct = total > 0 and (sum / total * 100) or 0
        if byRate then
          bar:SetMinMaxValues(0, bestRate)
          bar:SetValue(rate)
          bar.right:SetText(FormatRate(rate) .. "  " .. ShortNumber(sum) .. "  " .. string.format("%.0f%%", pct))
        else
          bar:SetMinMaxValues(0, best)
          bar:SetValue(sum)
          bar.right:SetText(ShortNumber(sum) .. "  " .. FormatRate(rate) .. "  " .. string.format("%.0f%%", pct))
        end
        local r, g, b = ClassColor(name)
        bar:SetStatusBarColor(r, g, b, .85)
        bar.left:SetText(rank .. ". " .. name)
        bar.unit = name
        bar.row = row
      else
        bar:SetValue(0)
        bar.left:SetText("")
        bar.right:SetText("")
        bar.unit = nil
        bar.row = nil
      end
    end
  end
  if detailOpen and RefreshOverview and not overviewBusy then RefreshOverview() end
end

local function WheelDelta(a, b)
  local delta = tonumber(arg1)
  if (not delta or delta == 0) and type(b) == "number" then delta = b end
  if (not delta or delta == 0) and type(a) == "number" then delta = a end
  return tonumber(delta) or 0
end

local function ScrollMeter(frame, delta)
  if not frame then return end
  delta = tonumber(delta) or 0
  if delta == 0 then return end
  if delta > 0 then delta = 1 else delta = -1 end
  local _, _, visible = MeterLayout()
  local segment = GetActiveSegment(frame)
  local keys = SortedNames(segment, frame.view == "dps")
  local maxScroll = table.getn(keys) - visible
  if maxScroll < 0 then maxScroll = 0 end
  local scroll = tonumber(frame.scroll) or 0
  scroll = scroll - delta
  if scroll < 0 then scroll = 0 end
  if scroll > maxScroll then scroll = maxScroll end
  if frame.scroll == scroll then return end
  frame.scroll = scroll
  RefreshMeter(frame)
end

local function CursorUI()
  local x, y = GetCursorPosition()
  local scale = 1
  if UIParent.GetEffectiveScale then scale = UIParent:GetEffectiveScale() or 1 end
  if scale < .01 then scale = 1 end
  return (x or 0) / scale, (y or 0) / scale
end

local function BarAtCursor(frame)
  if not frame or not frame.bars then return nil end
  local x, y = CursorUI()
  local i
  for i = 1, table.getn(frame.bars) do
    local bar = frame.bars[i]
    if bar and bar.unit and bar.GetLeft then
      local l, r = bar:GetLeft(), bar:GetRight()
      local t, b = bar:GetTop(), bar:GetBottom()
      if l and r and t and b and x >= l and x <= r then
        local lo, hi = b, t
        if t < b then lo, hi = t, b end
        if y >= lo and y <= hi then return bar end
      end
    end
  end
  return nil
end

local function RaiseMeterChrome(frame)
  if not frame then return end
  local lvl = (frame.GetFrameLevel and frame:GetFrameLevel() or 4) + 30
  local catch = frame.wheelCatch
  if catch and catch.GetFrameLevel then
    local cl = catch:GetFrameLevel() or 0
    if lvl <= cl then lvl = cl + 2 end
  end
  local widgets = { frame.title, frame.btnReset, frame.btnReport, frame.btnFight }
  local i
  for i = 1, table.getn(widgets) do
    local w = widgets[i]
    if w then
      if w.SetFrameLevel then w:SetFrameLevel(lvl) end
      if w.EnableMouse then w:EnableMouse(true) end
    end
  end
end

local function SizeWheelCatch(frame)
  local catch = frame and frame.wheelCatch
  if not catch then return end
  local w = frame.qtW or 190
  local h = frame.qtH or 160
  -- Keep the header (R/P/F + title) free so those buttons receive clicks.
  local listH = h - TITLE_H
  if listH < 20 then listH = 20 end
  catch:ClearAllPoints()
  catch:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
  catch:SetPoint("TOPRIGHT", frame, "BOTTOMLEFT", w, listH)
  if catch.SetWidth then
    catch:SetWidth(w + 1)
    catch:SetWidth(w)
  end
  if catch.SetHeight then
    catch:SetHeight(listH + 1)
    catch:SetHeight(listH)
  end
  RaiseMeterChrome(frame)
end

local function FrameContainsCursor(frame)
  if not frame then return nil end
  if frame.IsShown then
    local ok, shown = pcall(frame.IsShown, frame)
    if ok and not (shown == true or shown == 1 or shown == "1") then return nil end
  end
  local x, y = CursorUI()
  local l = frame.GetLeft and frame:GetLeft()
  local r = frame.GetRight and frame:GetRight()
  local t = frame.GetTop and frame:GetTop()
  local b = frame.GetBottom and frame:GetBottom()
  if l and r then
    if r < l then l, r = r, l end
    if x < l or x > r then return nil end
    if t and b then
      local lo, hi = b, t
      if t < b then lo, hi = t, b end
      if y >= lo and y <= hi then return true end
    end
  end
  local w, h = frame.qtW, frame.qtH
  local left, bottom = frame.lastLeft, frame.lastBottom
  if (not left or not bottom) and l and b then
    left, bottom = l, b
    if t and b and t < b then bottom = t end
  end
  if left and bottom and w and h then
    if x >= left and x <= left + w and y >= bottom and y <= bottom + h then return true end
  end
  return nil
end

local function MeterUnderCursor()
  local frames = QtP.meterFrames
  if not frames then return nil end
  local i
  for i = 1, table.getn(frames) do
    if FrameContainsCursor(frames[i]) then return frames[i] end
  end
  return nil
end

local function ScrollDetail(delta)
  if not detailOpen or not detailFrame then return nil end
  if not FrameContainsCursor(detailFrame) then return nil end
  delta = tonumber(delta) or 0
  if delta == 0 then return true end
  if delta > 0 then delta = 1 else delta = -1 end
  local x = CursorUI()
  local left = detailFrame.GetLeft and detailFrame:GetLeft()
  local roster = true
  if left and x > left + 8 + ROSTER_W + 6 then roster = nil end
  if roster then
    detailRosterScroll = (detailRosterScroll or 0) - delta
  else
    detailSpellScroll = (detailSpellScroll or 0) - delta
  end
  RefreshOverview()
  return true
end

local function HookCameraForMeterScroll()
  if QtP.meterZoomHooked then return end
  if type(CameraZoomIn) ~= "function" and type(CameraZoomOut) ~= "function" then return end
  QtP.meterZoomHooked = true
  local zoomIn = CameraZoomIn
  local zoomOut = CameraZoomOut
  CameraZoomIn = function(inc)
    local meter = MeterUnderCursor()
    if meter then
      ScrollMeter(meter, 1)
      return
    end
    if ScrollDetail(1) then return end
    if type(zoomIn) == "function" then return zoomIn(inc) end
  end
  CameraZoomOut = function(inc)
    local meter = MeterUnderCursor()
    if meter then
      ScrollMeter(meter, -1)
      return
    end
    if ScrollDetail(-1) then return end
    if type(zoomOut) == "function" then return zoomOut(inc) end
  end
end

local function AttachMeterWheel(frame)
  if not frame then return end
  HookCameraForMeterScroll()
  if frame.wheelCatch then
    SizeWheelCatch(frame)
    return
  end
  local catch = CreateFrame("Button", "QtPMeterWheel" .. tostring(frame.meterId or 1), frame)
  catch:SetFrameLevel((frame.GetFrameLevel and frame:GetFrameLevel() or 4) + 8)
  catch:EnableMouse(true)
  catch:EnableMouseWheel(true)
  if catch.EnableMouseWheel then catch:EnableMouseWheel(1) end
  catch:RegisterForClicks("LeftButtonUp")
  catch:SetScript("OnMouseWheel", function(a, b)
    ScrollMeter(frame, WheelDelta(a, b))
  end)
  catch:SetScript("OnMouseUp", function()
    local bar = BarAtCursor(frame)
    if bar and bar.unit and bar.row then
      pcall(ShowSpellDetails, bar.unit, bar.row, frame)
    end
  end)
  catch:SetScript("OnEnter", function()
    this.hover = true
  end)
  catch:SetScript("OnLeave", function()
    this.hover = nil
    this.tipBar = nil
    if GameTooltip then GameTooltip:Hide() end
  end)
  catch.tipElapsed = 0
  catch:SetScript("OnUpdate", function()
    if not this.hover then return end
    this.tipElapsed = this.tipElapsed + (arg1 or 0)
    if this.tipElapsed < .12 then return end
    this.tipElapsed = 0
    local bar = BarAtCursor(frame)
    if bar ~= this.tipBar then
      this.tipBar = bar
      if bar then
        local prev = this
        this = bar
        ShowBarTooltip()
        this = prev
      elseif GameTooltip then
        GameTooltip:Hide()
      end
    end
  end)
  frame.wheelCatch = catch
  SizeWheelCatch(frame)
end

function SpellList(row)
  local spells = {}
  if type(row) ~= "table" then return spells end
  local key
  for key in pairs(row) do
    if not INTERNALS[key] then table.insert(spells, key) end
  end
  table.sort(spells, function(a, b)
    return (row[b] or 0) < (row[a] or 0)
  end)
  return spells
end

ShowBarTooltip = function()
  if not this.unit or not this.row or not GameTooltip then return end
  GameTooltip:SetOwner(this, "ANCHOR_NONE")
  GameTooltip:ClearLines()
  GameTooltip:AddLine(this.unit)
  local sum = this.row._sum or 0
  local ctime = this.row._ctime or 1
  if ctime < 1 then ctime = 1 end
  GameTooltip:AddDoubleLine("Total", ShortNumber(sum))
  GameTooltip:AddDoubleLine("Per second", FormatRate(sum / ctime))
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Abilities:")
  local spells = SpellList(this.row)
  local i
  local max = table.getn(spells)
  if max > 12 then max = 12 end
  for i = 1, max do
    local amount = this.row[spells[i]] or 0
    local pct = sum > 0 and (amount / sum * 100) or 0
    local hits, crits = SpellHits(this.row, spells[i])
    local extra = ShortNumber(amount) .. "  " .. string.format("%.0f%%", pct)
    if hits > 0 then
      extra = extra .. "  " .. tostring(hits) .. "h"
      if crits > 0 then extra = extra .. "/" .. tostring(crits) .. "c" end
    end
    GameTooltip:AddDoubleLine(spells[i], extra)
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Click for the full list.", .7, .75, .8)
  GameTooltip:Show()
  GameTooltip:ClearAllPoints()
  GameTooltip:SetPoint("LEFT", this, "RIGHT", 6, 0)
end

local function TitleInset(showFight)
  local n = 2
  if showFight then n = 3 end
  return HEADER_PAD + (BTN + 2) * n
end

-- Emberveil ignores TOP offsets and FontString JustifyV. Place chrome from
-- the frame's BOTTOMLEFT with a second corner, same as every other QtP box.
function PlaceBox(widget, parent, left, bottom, width, height)
  if not widget then return end
  widget:ClearAllPoints()
  widget:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", left, bottom)
  widget:SetPoint("TOPRIGHT", parent, "BOTTOMLEFT", left + width, bottom + height)
  if widget.SetWidth then
    widget:SetWidth(width + 1)
    if widget.SetHeight then widget:SetHeight(height + 1) end
    widget:SetWidth(width)
    if widget.SetHeight then widget:SetHeight(height) end
  end
end

local function TooltipOn(frame, lines)
  frame:SetScript("OnEnter", function()
    if not GameTooltip then return end
    GameTooltip:SetOwner(this, "ANCHOR_NONE")
    GameTooltip:ClearLines()
    local i
    for i = 1, table.getn(lines) do
      if i == 1 then
        GameTooltip:AddLine(lines[i])
      else
        GameTooltip:AddLine(lines[i], .8, .85, .9)
      end
    end
    GameTooltip:Show()
    GameTooltip:ClearAllPoints()
    GameTooltip:SetPoint("BOTTOM", this, "TOP", 0, 4)
  end)
  frame:SetScript("OnLeave", function()
    if GameTooltip then GameTooltip:Hide() end
  end)
end

local METER_ICON = "Interface\\AddOns\\QtUiPlus\\media\\"

local function MakeMeterButton(parent, caption, lines, onClick, icon)
  local btn = CreateFrame("Button", nil, parent)
  btn:EnableMouse(true)
  btn:RegisterForClicks("LeftButtonUp")
  QtP.PaintSurface(btn)
  if icon then
    btn.icon = btn:CreateTexture(nil, "ARTWORK")
    btn.icon:SetPoint("TOPLEFT", btn, "TOPLEFT", 3, -3)
    btn.icon:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -3, 3)
    btn.icon:SetTexture(METER_ICON .. icon)
  else
    btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    btn.text:SetPoint("CENTER", btn, "CENTER", 0, 0)
    btn.text:SetText(caption)
  end
  btn:SetScript("OnClick", onClick)
  TooltipOn(btn, lines)
  return btn
end

local function LayoutMeterChrome(frame, width, height)
  if not frame then return end
  width = width or frame.qtW
  height = height or frame.qtH
  if not width or not height then
    width, height = MeterLayout()
  end
  frame.qtW = width
  frame.qtH = height

  local headerBottom = height - TITLE_H
  local btnBottom = headerBottom + HEADER_PAD - 3
  local resetLeft = width - HEADER_PAD - 2 - BTN
  PlaceBox(frame.btnReset, frame, resetLeft, btnBottom, BTN, BTN)
  if frame.btnReport then
    PlaceBox(frame.btnReport, frame, resetLeft - (BTN + 2), btnBottom, BTN, BTN)
  end
  local showFight = (frame.segment or 1) ~= 0
  if frame.btnFight then
    if showFight then
      PlaceBox(frame.btnFight, frame, resetLeft - (BTN + 2) * 2, btnBottom, BTN, BTN)
      if frame.btnFight.EnableMouse then frame.btnFight:EnableMouse(true) end
    else
      frame.btnFight:ClearAllPoints()
      frame.btnFight:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -4000, 4000)
      if frame.btnFight.EnableMouse then frame.btnFight:EnableMouse(false) end
      if HideFightMenu then HideFightMenu() end
    end
  end

  local titleW = width - TitleInset(showFight) - HEADER_PAD
  if titleW < 40 then titleW = 40 end
  PlaceBox(frame.title, frame, HEADER_PAD, headerBottom, titleW, TITLE_H)
  RaiseMeterChrome(frame)

  local label = ""
  if frame.titleText and frame.titleText.GetText then
    label = frame.titleText:GetText() or ""
  end
  if label == "" then
    label = ModeLabel(frame.view, frame.segment)
  end
  -- Emberveil draws FontStrings at the top of their box and ignores
  -- JustifyV. A short box on the button midline is what actually centers it.
  local textH = 12
  local textBottom = headerBottom - 1
  local fs = frame.titleText
  if not fs then
    fs = frame.title:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.titleText = fs
  end
  fs:ClearAllPoints()
  fs:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", HEADER_PAD + 4, textBottom)
  fs:SetPoint("TOPRIGHT", frame, "BOTTOMLEFT", HEADER_PAD + titleW + 2, textBottom + textH)
  fs:SetJustifyH("LEFT")
  fs:SetText(label)
end

local function ApplyMeterWindow(frame)
  if not frame then return end
  local width, height, visible, barH, spacing = MeterLayout()
  SizeMeterFrame(frame, width, height)
  local showBg = true
  if QtP.GetLayout then
    local layout = QtP:GetLayout()
    local flag = layout and layout.meterShowBackground
    if flag == false or flag == 0 or flag == "0" then showBg = nil end
  end
  if frame.SetBackdropColor then
    if showBg then
      QtP.PaintPanel(frame)
    else
      QtP.PaintClear(frame)
    end
  end
  LayoutMeterChrome(frame, width, height)
  local i
  for i = 1, MAX_BARS do
    PlaceBar(frame.bars[i], frame, i, barH, visible, spacing)
  end
  SizeWheelCatch(frame)
  frame.dirty = true
  RefreshMeter(frame)
end

local function PlaceMeterWindow(frame)
  if not frame then return end
  local key = MeterMoveKey(frame.meterId)

  -- Read the position from the QtUiPlus mover store, not QtPDB.positions --
  -- that was QtUI MoveMode's own store and nothing writes it here, so the
  -- lookup always missed and fell through to the default anchor below. Since
  -- ShowMeterWindow calls this on every show, that recomputed default is what
  -- snapped a window the player had dragged back into the corner.
  --
  -- Reapplying the stored point, rather than returning early, keeps this
  -- idempotent whether it is reached from window creation or from a show.
  -- Fully qualified: this file is at Lua 5.1's 200 top-level local cap and
  -- cannot afford a `local U`.
  local stored = QtUiPlus.GetPosition(key)
  if stored then
    QtUiPlus.ApplyFramePoint(frame, stored)
    return
  end
  local index = 1
  local i
  for i = 1, table.getn(QtP.meterFrames or {}) do
    if QtP.meterFrames[i] == frame then index = i end
  end
  frame:ClearAllPoints()
  frame:SetPoint("RIGHT", UIParent, "RIGHT", -20 - ((index - 1) * 24), -80 - ((index - 1) * 28))
end

local function ShowMeterWindow(frame)
  if not frame then return end
  PlaceMeterWindow(frame)
  if frame.Show then pcall(frame.Show, frame) end
  if frame.EnableMouse then frame:EnableMouse(true) end
  if frame.SetAlpha then frame:SetAlpha(1) end
end

local function HideMeterWindow(frame)
  if not frame then return end
  frame:ClearAllPoints()
  frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -2000, 2000)
  if frame.EnableMouse then frame:EnableMouse(false) end
  if frame.Hide then pcall(frame.Hide, frame) end
end

QtP.RefreshMeterWindow = RefreshMeter

local function RefreshMeterCanClose()
  local frames = QtP.meterFrames
  if not frames then return end
  local i
  for i = 1, table.getn(frames) do
    LayoutMeterChrome(frames[i])
  end
end

local CreateMeterWindow

local function NextMeterId()
  local used = {}
  local i
  for i = 1, table.getn(QtP.meterFrames or {}) do
    used[QtP.meterFrames[i].meterId] = true
  end
  for i = 1, MAX_WINDOWS do
    if not used[i] then return i end
  end
  return nil
end

local function NextUnusedMode()
  local used = {}
  local i
  for i = 1, table.getn(QtP.meterFrames or {}) do
    local frame = QtP.meterFrames[i]
    used[ModeIndex(frame.view, frame.segment)] = true
  end
  for i = 1, table.getn(MODES) do
    if not used[i] then return MODES[i] end
  end
  return MODES[1]
end

local function ApplyMeterMode(frame, mode)
  if not frame or not mode then return end
  frame.view = mode.view
  frame.segment = mode.segment
  PersistMeters()
  LayoutMeterChrome(frame)
  RefreshMeter(frame)
end

local modePicker
local modeSource

local modeOpen

local function HideModeMenu()
  modeOpen = nil
  modeSource = nil
  SafeHidePopup(modePicker)
end
QtP.HideMeterModeMenu = HideModeMenu

local function EnsureModePicker()
  if modePicker then return modePicker end
  local frame = CreateFrame("Frame", "QtPMeterModes", UIParent)
  frame:SetFrameStrata("FULLSCREEN")
  frame:SetFrameLevel(185)
  QtP.PaintPanel(frame)
  frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  frame.title:SetJustifyH("LEFT")
  QtP.ApplyTitleFont(frame.title)
  frame.hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  QtP.ApplyMutedFont(frame.hint)
  frame.close = QtP.AttachCloseButton(frame, HideModeMenu)
  frame.rows = {}
  local i
  for i = 1, table.getn(MODES) do
    local btn = CreateFrame("Button", nil, frame)
    btn:EnableMouse(true)
    btn:RegisterForClicks("LeftButtonUp")
    QtP.PaintSurface(btn)
    btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    btn.text:SetPoint("LEFT", btn, "LEFT", 8, 0)
    btn.text:SetJustifyH("LEFT")
    QtP.ApplyBodyFont(btn.text)
    btn.modeIndex = i
    btn:SetScript("OnEnter", function()
      QtP.PaintHover(this)
    end)
    btn:SetScript("OnLeave", function()
      QtP.PaintSurface(this)
    end)
    btn:SetScript("OnClick", function()
      local source = modeSource
      local spec = MODES[this.modeIndex]
      HideModeMenu()
      if source and spec then ApplyMeterMode(source, spec) end
    end)
    frame.rows[i] = btn
  end
  if UISpecialFrames then table.insert(UISpecialFrames, "QtPMeterModes") end
  frame:SetScript("OnHide", HideModeMenu)
  modePicker = frame
  ParkPopup(frame)
  return frame
end

local function ToggleModeMenu(frame)
  if HideReportMenu then HideReportMenu() end
  if HideFightMenu then HideFightMenu() end
  if modeOpen and modeSource == frame then
    HideModeMenu()
    return
  end
  modeSource = frame
  modeOpen = true
  local picker = EnsureModePicker()
  local n = table.getn(MODES)
  local rowH = 20
  local width = 220
  local height = TITLE_H + 8 + n * rowH + 8
  LayoutCenterPanel(picker, width, height, "View", "")
  local i
  for i = 1, n do
    local btn = picker.rows[i]
    local spec = MODES[i]
    local y = TITLE_H + 4 + (i - 1) * rowH
    PlaceBox(btn, picker, 10, height - y - rowH + 2, width - 20, rowH - 3)
    local active = frame and spec.view == frame.view and spec.segment == frame.segment
    if active then
      btn.text:SetText("|cffffd24d" .. spec.label .. "|r")
    else
      btn.text:SetText(spec.label)
    end
    if btn.Show then pcall(btn.Show, btn) end
    if btn.EnableMouse then btn:EnableMouse(true) end
  end
end

function QtP:CloseDamageMeterWindow(frame)
  if not frame or not self.meterFrames then return end
  if table.getn(self.meterFrames) <= 1 then return end
  local keep = {}
  local i
  for i = 1, table.getn(self.meterFrames) do
    if self.meterFrames[i] ~= frame then
      table.insert(keep, self.meterFrames[i])
    end
  end
  HideMeterWindow(frame)
  self.meterFrames = keep
  self.meterFrame = keep[1]
  RefreshMeterCanClose()
  PersistMeters()
end

function QtP:CloseLastDamageMeterWindow()
  if not self.meterFrames then return end
  local count = table.getn(self.meterFrames)
  if count <= 1 then return end
  self:CloseDamageMeterWindow(self.meterFrames[count])
end

function QtP:MeterWindowCount()
  if not self.meterFrames then return 0 end
  return table.getn(self.meterFrames)
end

function QtP:AddDamageMeterWindow(view, segment)
  if not self.meterFrames then return end
  if table.getn(self.meterFrames) >= MAX_WINDOWS then return end
  local id = NextMeterId()
  if not id then return end
  local mode = NextUnusedMode()
  if view then mode = { view = view, segment = segment or 1 } end
  local frame = CreateMeterWindow(id, mode.view, mode.segment)
  if not frame then return end
  table.insert(self.meterFrames, frame)
  RefreshMeterCanClose()
  PersistMeters()
  if self:IsFeatureEnabled("damageMeter") then
    ShowMeterWindow(frame)
    ApplyMeterWindow(frame)
  else
    HideMeterWindow(frame)
  end
  if self.RegisterMovable then
    self:RegisterMovable(MeterMoveKey(frame.meterId), "Damage Meter " .. frame.meterId, frame)
  end
  return frame
end

CreateMeterWindow = function(id, view, segment)
  local width, height = MeterLayout()
  local frame = QtP:CreatePanel("QtPDamageMeter" .. tostring(id), UIParent, 4)
  SizeMeterFrame(frame, width, height)
  frame:SetFrameStrata("MEDIUM")
  frame:SetMovable(true)
  frame:EnableMouse(true)
  if frame.EnableMouseWheel then frame:EnableMouseWheel(1) end
  frame:SetScript("OnMouseWheel", function()
    ScrollMeter(this, arg1)
  end)
  frame.scroll = 0
  frame.meterId = id
  frame.view = view or "damage"
  frame.segment = segment
  if frame.segment ~= 0 then frame.segment = 1 end
  frame.dirty = true
  frame.bars = {}

  frame.title = CreateFrame("Button", nil, frame)
  frame.title:EnableMouse(true)
  frame.title:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  frame.titleText = frame.title:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  frame.titleText:SetPoint("TOPLEFT", frame, "TOPLEFT", HEADER_PAD, -5)
  frame.titleText:SetJustifyH("LEFT")
  frame.titleText:SetText(ModeLabel(frame.view, frame.segment))
  frame.title:SetScript("OnClick", function()
    ToggleModeMenu(frame)
  end)
  if frame.title.EnableMouseWheel then frame.title:EnableMouseWheel(1) end
  frame.title:SetScript("OnMouseWheel", function()
    ScrollMeter(this:GetParent(), arg1)
  end)
  TooltipOn(frame.title, {
    "Damage Meter",
    "Click to choose Current / Overall Damage, DPS or Heal.",
    "Mouse wheel scrolls the list.",
  })

  frame.btnReset = MakeMeterButton(frame, "R", { "Reset" }, function()
    ResetSegment(frame.segment)
    RefreshMeter(frame)
  end, "reset")
  frame.btnReport = MakeMeterButton(frame, "P", {
    "Report",
    "Share with other QtP users. Self prints only to you.",
  }, function()
    ToggleReportMenu(this, frame)
  end, "announce")
  frame.btnFight = MakeMeterButton(frame, "F", {
    "Fights",
    "Current pull and previous bosses / trash.",
  }, function()
    ToggleFightMenu(this)
  end, "plus")

  local i
  for i = 1, MAX_BARS do
    local bar = CreateFrame("StatusBar", nil, frame)
    bar:SetStatusBarTexture(QtP.media.statusbar)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    bar:EnableMouse(true)
    if bar.EnableMouseWheel then bar:EnableMouseWheel(1) end
    bar:SetScript("OnMouseWheel", function()
      ScrollMeter(this:GetParent(), arg1)
    end)
    bar.bg = bar:CreateTexture(nil, "BACKGROUND")
    bar.bg:SetAllPoints(bar)
    bar.bg:SetTexture("Interface\\Buttons\\WHITE8X8")
    bar.bg:SetVertexColor(.04, .05, .06, .7)
    bar.left = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bar.left:SetPoint("LEFT", bar, "LEFT", 4, 0)
    bar.left:SetJustifyH("LEFT")
    bar.right = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bar.right:SetPoint("RIGHT", bar, "RIGHT", -4, 0)
    bar.right:SetJustifyH("RIGHT")
    bar:SetScript("OnEnter", ShowBarTooltip)
    bar:SetScript("OnLeave", function()
      if GameTooltip then GameTooltip:Hide() end
    end)
    bar:RegisterForClicks("LeftButtonUp")
    bar:SetScript("OnMouseUp", function()
      if arg1 == "LeftButton" and this.unit and this.row then
        pcall(ShowSpellDetails, this.unit, this.row, frame)
      end
    end)
    frame.bars[i] = bar
  end

  AttachMeterWheel(frame)

  frame.elapsed = 0
  frame:SetScript("OnUpdate", function()
    this.elapsed = this.elapsed + (arg1 or 0)
    if this.elapsed >= .2 then
      this.elapsed = 0
      if this.dirty then
        this.dirty = nil
        RefreshMeter(this)
      end
    end
  end)

  LayoutMeterChrome(frame)
  PlaceMeterWindow(frame)
  return frame
end

function QtP:ShowDamageMeter()
  local i
  for i = 1, table.getn(self.meterFrames or {}) do
    ShowMeterWindow(self.meterFrames[i])
  end
end

function QtP:HideDamageMeter()
  local i
  for i = 1, table.getn(self.meterFrames or {}) do
    HideMeterWindow(self.meterFrames[i])
  end
end

function QtP:ApplyDamageMeterLayout()
  local i
  for i = 1, table.getn(self.meterFrames or {}) do
    ApplyMeterWindow(self.meterFrames[i])
  end
end

function QtP:SetupDamageMeter()
  HookCameraForMeterScroll()
  LoadMeterState()
  if self.meterFrames and table.getn(self.meterFrames) > 0 then
    if self:IsFeatureEnabled("damageMeter") then
      self:ShowDamageMeter()
      self:ApplyDamageMeterLayout()
    else
      self:HideDamageMeter()
    end
    return
  end

  self.meterFrames = {}
  local specs = nil
  if self.GetLayout then
    local layout = self:GetLayout()
    if layout and type(layout.meterWindows) == "table" and table.getn(layout.meterWindows) > 0 then
      specs = layout.meterWindows
    end
  end
  if not specs then
    specs = { { id = 1, view = "damage", segment = 1 } }
  end

  local i
  for i = 1, table.getn(specs) do
    if table.getn(self.meterFrames) >= MAX_WINDOWS then break end
    local spec = specs[i]
    local id = tonumber(spec.id) or i
    local frame = CreateMeterWindow(id, spec.view, spec.segment)
    table.insert(self.meterFrames, frame)
    if self.RegisterMovable then
      self:RegisterMovable(MeterMoveKey(id), "Damage Meter " .. id, frame)
    end
  end

  self.meterFrame = self.meterFrames[1]
  RefreshMeterCanClose()
  PersistMeters()

  HookChatMeter(DEFAULT_CHAT_FRAME)
  HookChatMeter(ChatFrame1)
  HookChatMeter(ChatFrame2)

  self:ApplyDamageMeterLayout()
  if self:IsFeatureEnabled("damageMeter") then
    self:ShowDamageMeter()
  else
    self:HideDamageMeter()
  end

  local function ShowMeterResetPrompt()
    if QtP.meterResetDialog then
      if QtP.meterResetDialog.Show then pcall(QtP.meterResetDialog.Show, QtP.meterResetDialog) end
      return
    end
    local d = CreateFrame("Frame", "QtPMeterResetDialog", UIParent)
    d:SetFrameStrata("FULLSCREEN_DIALOG")
    d:SetFrameLevel(300)
    d:SetPoint("TOPLEFT", UIParent, "CENTER", -140, 50)
    d:SetPoint("BOTTOMRIGHT", UIParent, "CENTER", 140, -40)
    QtP.PaintPanel(d)
    d:EnableMouse(true)
    d.title = d:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    d.title:SetPoint("TOPLEFT", d, "TOPLEFT", 14, -12)
    d.title:SetText("Instance")
    QtP.ApplyTitleFont(d.title)
    d.body = d:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    d.body:SetPoint("TOPLEFT", d, "TOPLEFT", 14, -34)
    d.body:SetPoint("TOPRIGHT", d, "TOPRIGHT", -14, -34)
    d.body:SetJustifyH("LEFT")
    d.body:SetText("Reset the damage meter for this instance?")
    QtP.ApplyBodyFont(d.body)
    local yes = CreateFrame("Button", nil, d)
    yes:SetPoint("BOTTOMLEFT", d, "BOTTOMLEFT", 14, 10)
    yes:SetPoint("TOPRIGHT", d, "BOTTOMLEFT", 130, 32)
    QtP.PaintHover(yes)
    yes.text = yes:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    yes.text:SetPoint("CENTER", yes, "CENTER", 0, 0)
    yes.text:SetText("Reset")
    QtP.ApplyBodyFont(yes.text)
    yes:SetScript("OnClick", function()
      ResetSegment(0)
      ResetSegment(1)
      history = {}
      viewing = nil
      PersistMeters()
      MarkMetersDirty()
      if QtP.ApplyDamageMeterLayout then QtP:ApplyDamageMeterLayout() end
      d:Hide()
    end)
    local no = CreateFrame("Button", nil, d)
    no:SetPoint("BOTTOMLEFT", d, "BOTTOMLEFT", 138, 10)
    no:SetPoint("TOPRIGHT", d, "BOTTOMLEFT", 254, 32)
    QtP.PaintSurface(no)
    no.text = no:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    no.text:SetPoint("CENTER", no, "CENTER", 0, 0)
    no.text:SetText("Keep")
    QtP.ApplyBodyFont(no.text)
    no:SetScript("OnClick", function() d:Hide() end)
    QtP.meterResetDialog = d
  end

  if not self.meterPersistWatch then
    local watch = CreateFrame("Frame", "QtPMeterPersist")
    self.meterPersistWatch = watch
    watch.wasInstance = nil
    watch:RegisterEvent("PLAYER_LOGOUT")
    watch:RegisterEvent("PLAYER_ENTERING_WORLD")
    watch:SetScript("OnEvent", function()
      if event == "PLAYER_LOGOUT" then
        PersistMeters()
        return
      end
      if event ~= "PLAYER_ENTERING_WORLD" then return end
      local inInst
      if type(IsInInstance) == "function" then
        local ok, value = pcall(IsInInstance)
        inInst = ok and (value == true or value == 1 or value == "1")
      end
      local layout = QtP.GetLayout and QtP:GetLayout()
      local ask = layout and (layout.meterAskInstance == true or layout.meterAskInstance == 1)
      if watch.wasInstance == nil then
        watch.wasInstance = inInst
        return
      end
      if inInst and not watch.wasInstance and ask then
        ShowMeterResetPrompt()
      end
      watch.wasInstance = inInst
    end)
  end
end




-- ---------------------------------------------------------------------------
-- Module registration
--
-- Deliberately not `local M = U.RegisterModule(...)`: see the top-level local
-- budget noted in the file header. The module table hangs off QtP instead.
-- ---------------------------------------------------------------------------
QtP.damageMeterModule = QtUiPlus.RegisterModule("damagemeter")

function QtP.damageMeterModule:OnEnable()
  if not QtP:IsFeatureEnabled("damagemeter") then return end
  QtP:SetupDamageMeter()
end
