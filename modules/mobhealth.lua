-- QtUiPlus :: modules/mobhealth.lua
--
-- Real hit points for enemy NPCs whose health the client only reports as a
-- percentage, resolved from the static 1.12 table in core/mobhealthdb.lua.
-- Ported from QtUI MobHealth.lua. No combat-derived estimate: the table is
-- authoritative or the lookup declines.
--
-- SCOPE NOTE: emberveil.org/wiki/lua/globals/Unit documents UnitHealth and
-- UnitHealthMax as returning "real hit points", not the vanilla 1.12
-- percentages, for every unit. If that holds for every NPC in practice, the
-- guard in NeedsLookup below never passes and this module correctly does
-- nothing at all -- it only engages when UnitHealthMax reports a value in the
-- 1..100 range, which is the signature of a percentage. It is carried over
-- because QtUI ships it against this same client (so percentages evidently do
-- appear for some units), and because a module that self-disables costs one
-- comparison per call when the client reports real values. Do not read its
-- presence as evidence that percentages occur.
--
-- QtP.GetMobHealth(unit) is the whole public surface; unit frames and
-- nameplates call it and place the result themselves.

local U = QtUiPlus

local M = U.RegisterModule("mobhealth")

local function True(value)
  return value == true or value == 1 or value == "1"
end

local function Enabled()
  if not QtP:IsFeatureEnabled("mobhealth") then return false end
  local layout = QtP:GetLayout()
  if not layout then return true end
  return layout.estimateMobHealth ~= false
end

-- The lookup is only worth doing for an attackable non-player unit whose max
-- health looks like a percentage rather than a hit-point total.
local function NeedsLookup(unit)
  if not unit or not Enabled() then return nil end

  local isPlayer = U.G("UnitIsPlayer")
  if type(isPlayer) == "function" then
    local ok, value = pcall(isPlayer, unit)
    if ok and True(value) then return nil end
  end

  local healthMax = U.G("UnitHealthMax")
  if type(healthMax) ~= "function" then return nil end
  local ok, max = pcall(healthMax, unit)
  max = ok and tonumber(max) or 0
  if max > 100 or max < 1 then return nil end

  local canAttack = U.G("UnitCanAttack")
  if type(canAttack) == "function" then
    local attackOk, value = pcall(canAttack, "player", unit)
    if attackOk and True(value) then return true end
  end
  return nil
end

-- Classification is stored in the table as a small integer per level bracket.
local function ClassRank(classification)
  if classification == "elite" then return 1 end
  if classification == "rareelite" then return 2 end
  if classification == "worldboss" then return 3 end
  if classification == "rare" then return 4 end
  return 0
end

-- How well a stored bracket's classification matches the unit's. 1 is exact;
-- 2 covers the two pairs the 1.12 data conflates (rare recorded as normal,
-- rareelite recorded as elite). Anything else is rejected outright rather than
-- guessed at, since a wrong bracket produces a confidently wrong number.
local function RankFit(have, want)
  if have == want then return 1 end
  if want == 4 and have == 0 then return 2 end
  if want == 2 and have == 1 then return 2 end
  return nil
end

local function InterpHp(minLevel, maxLevel, minHp, maxHp, level)
  if maxLevel <= minLevel then return minHp end
  if level <= minLevel then return minHp end
  if level >= maxLevel then return maxHp end
  return minHp + (maxHp - minHp) * (level - minLevel) / (maxLevel - minLevel)
end

-- Walks the flat 5-number records for this creature name and picks the best
-- scoring bracket. Lower score wins: an exact classification match inside the
-- unit's own level range beats a near-miss, which beats a bracket up to two
-- levels away. A skull-level unit (UnitLevel returns -1) has no usable level,
-- so the highest bracket is taken.
local function StaticMax(unit)
  local static = QtP.MobHealthStatic
  if not static then return nil end

  local unitName = U.G("UnitName")
  if type(unitName) ~= "function" then return nil end
  local ok, name = pcall(unitName, unit)
  if not ok or not name then return nil end

  local row = static[name]
  if not row then return nil end

  local unitLevel = U.G("UnitLevel")
  local level = 0
  if type(unitLevel) == "function" then
    local levelOk, value = pcall(unitLevel, unit)
    level = (levelOk and tonumber(value)) or 0
  end

  local classification = "normal"
  local unitClass = U.G("UnitClassification")
  if type(unitClass) == "function" then
    local classOk, value = pcall(unitClass, unit)
    if classOk and type(value) == "string" and value ~= "" then
      classification = value
    end
  end

  local want = ClassRank(classification)
  local total = table.getn(row)
  local best, bestScore
  local i = 1

  while i + 4 <= total do
    local minLevel, maxLevel = row[i], row[i + 1]
    local minHp, maxHp, rank = row[i + 2], row[i + 3], row[i + 4]
    local fit = RankFit(rank, want)
    if fit then
      local hp, score
      if level < 1 then
        hp = maxHp
        score = fit * 1000 - maxLevel
      elseif level >= minLevel and level <= maxLevel then
        hp = InterpHp(minLevel, maxLevel, minHp, maxHp, level)
        score = fit
      else
        local distance = minLevel - level
        if distance < 0 then distance = level - maxLevel end
        if distance <= 2 then
          hp = InterpHp(minLevel, maxLevel, minHp, maxHp, level)
          score = fit * 100 + distance
        end
      end
      if hp and (not bestScore or score < bestScore) then
        best = hp
        bestScore = score
      end
    end
    i = i + 5
  end

  -- Below this a "hit point total" is more likely a bad bracket match than a
  -- real creature, and showing it would be worse than showing the percentage.
  if best and best >= 20 then return best end
  return nil
end

-- Returns current, maximum, kind. kind is "hp" when the static table resolved
-- the unit and the numbers are hit points, or "pct" when only the client's
-- percentage is available and maximum is nil. Callers must branch on kind
-- rather than assuming a maximum is present.
function QtP.GetMobHealth(unit)
  if not NeedsLookup(unit) then return nil end

  local health = U.G("UnitHealth")
  local percent = 0
  if type(health) == "function" then
    local ok, value = pcall(health, unit)
    percent = (ok and tonumber(value)) or 0
  end
  if percent < 0 then percent = 0 end
  if percent > 100 then percent = 100 end

  local maxHp = StaticMax(unit)
  if maxHp and maxHp >= 20 then
    local current = math.floor(percent / 100 * maxHp + .5)
    if percent > 0 and current < 1 then current = 1 end
    if percent <= 0 then current = 0 end
    return current, math.floor(maxHp + .5), "hp"
  end

  return percent, nil, "pct"
end

local function Short(value)
  value = tonumber(value) or 0
  local absolute = math.abs(value)
  if absolute > 1000000 then
    return string.format("%.1fm", value / 1000000)
  end
  if absolute > 10000 then
    return string.format("%.1fk", value / 1000)
  end
  return tostring(math.floor(value + 0.5))
end

-- One-line readout for unit frames, nameplates and the tooltip bar.
-- Returns nil when the lookup does not apply (players, real hit-point units).
function QtP.FormatMobHealth(unit)
  local current, maximum, mode = QtP.GetMobHealth(unit)
  if mode == "hp" then
    return Short(current) .. " / " .. Short(maximum), mode
  end
  if mode == "pct" then
    return tostring(math.floor((current or 0) + 0.5)) .. "%", mode
  end
  return nil
end

function M:OnEnable()
  -- Data-only module: nothing to build. Registered so it appears in the module
  -- list and can be disabled like any other feature.
end
