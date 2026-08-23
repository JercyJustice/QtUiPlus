-- QtUiPlus :: modules/autoloot.lua
--
-- Loots every slot of an opened corpse, container or gathering node unless
-- Shift is held. Ported from QtUI AutoLoot.lua.
--
-- API NOTE, unresolved: emberveil.org/wiki/lua/globals/Loot documents
-- LootSlot as "Confirms a pending bind-on-pickup prompt for a loot slot" and
-- states outright that it "does not pick up the item (or coin) in a slot",
-- and the Loot page documents no other pickup function. That contradicts the
-- WORKING_SOURCE evidence: QtUI ships this exact LootSlot loop against this
-- same client and it is what the user runs today. The loop is therefore kept
-- as-is -- shipping behaviour outranks a doc line that offers no alternative --
-- but nothing here should be treated as runtime-verified, and if auto-loot is
-- observed doing nothing in game, this doc note is the first place to look.
--
-- Two things are deliberately different from the QtUI original:
--
--  * The retry loop skips rows that are already empty. GetNumLootItems "does
--    not shrink when a slot is looted; emptied rows stay until the window
--    closes" (same wiki page), so QtUI's blind 1..n sweep re-called LootSlot on
--    every already-looted row on every retry. LootSlotIsItem / LootSlotIsCoin
--    report which rows still hold something.
--  * Events and the retry timer go through the QtUiPlus dispatcher rather than
--    a private frame reading `this` / `event` / `arg1`. core/init.lua records
--    that this client does not consistently populate those globals and passes
--    handler arguments directly instead.

local U = QtUiPlus

local A = U.RegisterModule("autoloot")

-- How long to keep retrying after the window opens. This client's loot bridge
-- is asynchronous: a slot can be momentarily unavailable and become lootable a
-- few frames later, so one pass at LOOT_OPENED is not enough.
local RETRY_WINDOW = 2
local RETRY_INTERVAL = 0.1

local draining = false
local remaining = 0

local function IsShiftHeld()
  local shift = U.G("IsShiftKeyDown")
  if type(shift) ~= "function" then return false end
  local ok, value = pcall(shift)
  if not ok then return false end
  return value == true or value == 1 or value == "1"
end

-- Returns true when the row still holds something worth calling LootSlot on.
-- The two predicates are optional: if the client does not expose them, fall
-- back to attempting every row, which is what QtUI does unconditionally.
local function SlotHasContent(slot)
  local isItem = U.G("LootSlotIsItem")
  local isCoin = U.G("LootSlotIsCoin")
  if type(isItem) ~= "function" and type(isCoin) ~= "function" then
    return true
  end

  if type(isItem) == "function" then
    local ok, value = pcall(isItem, slot)
    if ok and (value == true or value == 1) then return true end
  end
  if type(isCoin) == "function" then
    local ok, value = pcall(isCoin, slot)
    if ok and (value == true or value == 1) then return true end
  end
  return false
end

-- Descending, so that removing a row cannot shift a row this pass has not
-- reached yet. Each slot is pcall'd on its own: one temporarily unavailable
-- slot must not abandon the rest of the loot.
local function LootEverything()
  local count = U.G("GetNumLootItems")
  if type(count) ~= "function" then return end
  local ok, total = pcall(count)
  total = ok and tonumber(total) or 0
  if total < 1 then return end

  local lootSlot = U.G("LootSlot")
  if type(lootSlot) ~= "function" then return end

  local slot
  for slot = total, 1, -1 do
    if SlotHasContent(slot) then
      pcall(lootSlot, slot)
    end
  end
end

local function StopDraining()
  draining = false
  remaining = 0
  U.UnregisterUpdate("autoloot.drain")
end

local function Drain()
  if not draining then
    StopDraining()
    return
  end
  remaining = remaining - RETRY_INTERVAL
  if remaining <= 0 then
    StopDraining()
    return
  end
  LootEverything()
end

local function StartDraining()
  draining = true
  remaining = RETRY_WINDOW
  LootEverything()
  U.RegisterUpdate("autoloot.drain", RETRY_INTERVAL, Drain)
end

function A:OnEnable()
  U.RegisterEvent("LOOT_OPENED", function()
    if not QtP:IsFeatureEnabled("autoloot") then return end
    local layout = QtP:GetLayout()
    if layout and layout.autoLoot == false then return end

    -- Shift is sampled only at the moment the window opens. Sampling it later
    -- would let a Shift-modified spell cast suppress an unrelated loot window
    -- that opened seconds afterwards.
    if IsShiftHeld() then
      StopDraining()
      return
    end
    StartDraining()
  end)

  U.RegisterEvent("LOOT_SLOT_CLEARED", function()
    if draining then LootEverything() end
  end)

  U.RegisterEvent("LOOT_CLOSED", StopDraining)
end
