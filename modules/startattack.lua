-- QtUiPlus :: modules/startattack.lua
--
-- /startattack and /stopattack for a client that has neither.
--
-- Those two commands arrived with TBC. This client is 1.12-shaped and offers
-- only AttackTarget, which is a *toggle*: a macro that calls it to make sure
-- auto attack is running will just as happily stop the swing that already was.
-- That is the whole reason `/startattack` cannot simply be aliased to it.
--
-- So the hard part is not starting the attack, it is knowing whether one is
-- already running. Answering that wrong costs a swing either way: think you
-- are attacking when you are not and the command does nothing, think you are
-- idle when you are not and it cancels mid-swing.
--
-- How the state is read
--
--   IsAttackAction locates the Attack action on the bars once, and
--   IsCurrentAction reports whether it is the active action.
--   modules/actionbar.lua already drives its active-button border off
--   IsCurrentAction (see UpdateActive), so both calls are known to work on
--   this client rather than assumed from Vanilla.
--
--   A live "true" is always trusted. A live "false" is trusted only once this
--   session has seen the pair report true at least once -- until then, "false"
--   is indistinguishable from a client that never reports the state, and
--   acting on it would toggle a running attack off. The state is proven
--   passively as well as through this module: entering combat reads it once,
--   so ordinary play establishes it without the player having to use these
--   commands first.
--
-- What happens while the state is unreadable
--
--   A belief is kept as a fallback and confirmed one tick later, so a call the
--   client never acted on does not latch. If nothing can be established at all
--   the commands behave exactly like a bare AttackTarget macro would -- no
--   worse than what a player writes by hand today, and better the moment the
--   state becomes readable.
--
-- The Attack slot is a scan of the whole action range because the action can
-- sit on any page. It is cached and dropped again whenever the bars change.

local U = QtUiPlus

local SA = U.RegisterModule("startattack")

local MAX_ACTION_SLOT = 120

-- A toggle nothing ever confirms is assumed not to have started, so a stale
-- belief cannot outlive the swing it was standing in for.
local UNCONFIRMED_SECONDS = 3

local attackSlot
local attackSlotScanned = false
local liveStateProven = false

local believeAttacking = false
local beliefConfirmed = false
local beliefStartedAt = 0

-- ---------------------------------------------------------------------------
-- Client calls
-- ---------------------------------------------------------------------------

-- Vanilla's boolean-ish APIs return 1 or nil, but that is not guaranteed here,
-- so anything other than nil/false/0/"" counts as true.
local function Truthy(value)
  if value == nil or value == false or value == 0 or value == "" then
    return false
  end
  return true
end

-- The second return says whether the call actually happened, which is how an
-- unreadable API is told apart from one reporting false.
local function Call(name, a, b)
  local fn = U.G(name)
  if type(fn) ~= "function" then return nil, false end
  local ok, value = pcall(fn, a, b)
  if not ok then return nil, false end
  return value, true
end

local function ApiTruth(name, a, b)
  return Truthy(Call(name, a, b))
end

local function Now()
  local value, called = Call("GetTime")
  if called and type(value) == "number" then return value end
  return nil
end

-- ---------------------------------------------------------------------------
-- Reading the real toggle state
-- ---------------------------------------------------------------------------
local function AttackSlot()
  if attackSlotScanned then return attackSlot end
  attackSlotScanned = true
  attackSlot = nil

  if type(U.G("IsAttackAction")) ~= "function" then return nil end

  local slot
  for slot = 1, MAX_ACTION_SLOT do
    if ApiTruth("IsAttackAction", slot) then
      attackSlot = slot
      return attackSlot
    end
  end

  return nil
end

local function ForgetAttackSlot()
  attackSlotScanned = false
  attackSlot = nil
end

-- true / false when the client can answer, nil when it cannot.
local function LiveAttackState()
  local slot = AttackSlot()
  if not slot then return nil end

  local value, called = Call("IsCurrentAction", slot)
  if not called then return nil end

  if Truthy(value) then
    liveStateProven = true
    return true
  end

  if not liveStateProven then return nil end
  return false
end

local function IsAttacking()
  local live = LiveAttackState()
  if live ~= nil then return live end

  if not believeAttacking then return false end
  if beliefConfirmed then return true end

  -- Unconfirmed and unreadable: let it lapse rather than block every later
  -- command on a call that may never have started a swing. Out of combat only
  -- -- of the two ways to be wrong, cancelling a swing that is really running
  -- is the worse one, and the combat flag is the last cheap signal that one
  -- might be.
  local now = Now()
  if now and now > beliefStartedAt + UNCONFIRMED_SECONDS and
     not ApiTruth("UnitAffectingCombat", "player") then
    believeAttacking = false
    return false
  end

  return true
end

-- One tick after a toggle, check whether it took. This retires a belief the
-- client never acted on, and it is also how the live state gets proven during
-- ordinary play rather than only on the first fight of a session.
local function ConfirmToggle()
  U.DeferOnce("startattack.confirm", function()
    local live = LiveAttackState()
    if live == true then
      believeAttacking = true
      beliefConfirmed = true
    elseif live == false then
      believeAttacking = false
      beliefConfirmed = false
    end
  end)
end

local function Toggle()
  local _, called = Call("AttackTarget")
  if not called then return false end

  local now = Now()
  beliefStartedAt = now or 0
  ConfirmToggle()
  return true
end

local function TargetIsAttackable()
  if not ApiTruth("UnitExists", "target") then return false end
  if ApiTruth("UnitIsDead", "target") then return false end
  if ApiTruth("UnitIsGhost", "target") then return false end
  return ApiTruth("UnitCanAttack", "player", "target")
end

-- ---------------------------------------------------------------------------
-- Public entry points
--
-- Both return true when the client was actually asked to change something, so
-- a caller can tell "already in that state" from "could not act".
-- ---------------------------------------------------------------------------
function U.StartAttack()
  -- If this client ever grows the real thing, it wins: it cannot be wrong
  -- about its own state the way a reconstruction can.
  local _, called = Call("StartAttack")
  if called then return true end

  if not TargetIsAttackable() then return false end
  if IsAttacking() then return false end

  -- Written only once the toggle actually went out: a belief set ahead of a
  -- call that never happened has nothing to clear it but the timeout.
  if not Toggle() then return false end
  believeAttacking = true
  beliefConfirmed = false
  return true
end

function U.StopAttack()
  local _, called = Call("StopAttack")
  if called then return true end

  -- Only a definite "not attacking" blocks this. Unknown falls through to the
  -- toggle: failing to stop an attack the player asked to stop is the more
  -- visible error, and unlike the start case it cannot cancel a swing they
  -- wanted.
  if IsAttacking() == false then return false end

  if not Toggle() then return false end
  believeAttacking = false
  beliefConfirmed = false
  return true
end

-- Reported by /qtp check.
function U.StartAttackReport()
  return {
    slot = AttackSlot(),
    isAttackAction = type(U.G("IsAttackAction")) == "function",
    isCurrentAction = type(U.G("IsCurrentAction")) == "function",
    attackTarget = type(U.G("AttackTarget")) == "function",
    nativeStartAttack = type(U.G("StartAttack")) == "function",
    liveStateProven = liveStateProven,
    live = LiveAttackState(),
    believeAttacking = believeAttacking,
  }
end

-- ---------------------------------------------------------------------------
-- Slash commands
--
-- Registered under the real names, so a macro written for a TBC-era client --
-- or copied from a guide -- works here unchanged.
--
-- The guard covers this module registering twice and another addon having
-- taken the same handler id. It cannot see a third party that registered
-- "/startattack" under an id of its own: the client dispatches by scanning the
-- SLASH_* globals, and there is no way to enumerate them to find out. Two
-- registrations of one command are resolved by the client, not by us -- worth
-- knowing if another attack addon is installed alongside this one.
-- ---------------------------------------------------------------------------
local function RegisterSlash(command, id, fn)
  if type(SlashCmdList) ~= "table" then return false end
  if SlashCmdList[id] then return false end
  if U.G("SLASH_" .. id .. "1") then return false end

  U.SetG("SLASH_" .. id .. "1", "/" .. command)
  SlashCmdList[id] = fn
  return true
end

function SA:OnEnable()
  -- Whenever the bars change, the cached Attack slot may not be the Attack
  -- slot any more.
  local forget = function() ForgetAttackSlot() end
  U.RegisterEvent("ACTIONBAR_SLOT_CHANGED", forget)
  U.RegisterEvent("ACTIONBAR_PAGE_CHANGED", forget)
  U.RegisterEvent("LEARNED_SPELL_IN_TAB", forget)

  -- Proving the live state passively is what keeps the first use of these
  -- commands from having to guess: by the time a player types one, an earlier
  -- fight has usually already established that the pair reports true.
  U.RegisterEvent("PLAYER_ENTER_COMBAT", function() LiveAttackState() end)

  U.SetG("QtUiPlusStartAttack", U.StartAttack)
  U.SetG("QtUiPlusStopAttack", U.StopAttack)

  RegisterSlash("startattack", "QTUIPLUSSTARTATTACK", function()
    U.StartAttack()
  end)
  RegisterSlash("stopattack", "QTUIPLUSSTOPATTACK", function()
    U.StopAttack()
  end)
end
