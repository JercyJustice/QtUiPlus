-- QtUiPlus :: modules/smartshift.lua
--
-- One-press druid form changes. Ported from SmartShapeshift by
-- robertwallin86 (github.com/robertwallin86/SmartShapeshift), which solves a
-- problem this client really has and which modules/stancebar.lua did not
-- address: leaving one form and entering another are two separate actions
-- here, and issuing both in the same frame fails with "You are in shapeshift
-- form" or leaves the model and the action bar disagreeing about which form
-- is active.
--
-- So a press that asks for a form the player is not in cancels the current
-- form, then waits for caster form to be *stable* before casting the target.
-- The stable interval is the whole trick: this client can report caster form a
-- frame before the transition it is reporting has actually finished.
--
-- Behaviour, matching the original:
--
--   * press while in another form -> that form is cancelled, the target is
--     entered once caster form has held for STABLE_SECONDS
--   * press while already in the target form -> nothing, so a keybind or a
--     macro is spam-safe and never toggles the form off by accident
--   * Ctrl+press while in the target form -> leaves it deliberately
--   * a form chosen by hand mid-transition supersedes the queued request
--   * a transition that never completes is abandoned after TIMEOUT_SECONDS
--     rather than firing late, when the player has moved on
--
-- Two deliberate differences from the original
--
--   * Druids only. The original is a druid addon by intent, and the algorithm
--     is only correct where leaving a form is its own step. A warrior is
--     always in a stance and casting the active one is documented as a no-op
--     (documentation.json / global:Spell:CastShapeshiftForm records that the
--     non-toggleable warrior stances do nothing when re-cast), so running this
--     for a warrior would cancel nothing, never reach caster form, and end
--     every stance change in the timeout message. Rogue Stealth and priest
--     Shadowform are single forms with no form-to-form transition to smooth.
--   * Timing comes from GetTime, not arg1. The original accumulates the OnUpdate
--     handler's arg1 as the frame delta. knowledge.json /
--     scripts.onupdate_elapsed_only_via_arg1: this client passes no arguments
--     to an OnUpdate handler at all, and arg1 is the shared event-argument
--     global that every OnEvent dispatch overwrites -- so inside QtUiPlus's
--     shared driver it is whatever the last event left behind, not a delta.
--     core/init.lua reads GetTime for exactly this reason and so does this
--     module: it stamps the transition and compares stamps.

local U = QtUiPlus

local SS = U.RegisterModule("smartshift")

-- How long caster form has to hold before the target form is cast. The
-- original measured 0.10s on this client; kept as-is.
local STABLE_SECONDS = 0.10

-- A transition that has not completed by then is abandoned. Firing it later
-- would shift the player at a moment they are no longer asking for.
local TIMEOUT_SECONDS = 2

local DEFAULTS = {
  enabled = false,   -- opt-in: it changes what a form button press does
}

local cfg
local pending
local isDruid = false
local classKnown = false

-- ---------------------------------------------------------------------------
-- Client calls
--
-- Same resolve-by-name-and-pcall shape as modules/stancebar.lua: a missing call
-- costs the feature, not the module.
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

local function Call(name, a)
  local fn = ResolveApiFn(name)
  if not fn then return nil end
  local ok, result = pcall(fn, a)
  if not ok then return nil end
  return result
end

local function Now()
  local fn = ResolveApiFn("GetTime")
  if not fn then return nil end
  local ok, value = pcall(fn)
  if not ok then return nil end
  return tonumber(value)
end

local function FormCount()
  return tonumber(Call("GetNumShapeshiftForms")) or 0
end

-- GetShapeshiftFormInfo returns four values; Call forwards one result only, so
-- this gets its own wrapper (the same split modules/stancebar.lua makes).
local function FormInfo(index)
  local fn = ResolveApiFn("GetShapeshiftFormInfo")
  if not fn then return nil end
  local ok, texture, name, active, castable = pcall(fn, index)
  if not ok then return nil end
  return texture, name, active, castable
end

local function ActiveForm()
  local i
  for i = 1, FormCount() do
    local _, _, active = FormInfo(i)
    if active then return i end
  end
  return nil
end

local function IsCastable(index)
  local _, _, _, castable = FormInfo(index)
  return castable and true or false
end

local function CastForm(index)
  local fn = ResolveApiFn("CastShapeshiftForm")
  if not fn then return false end
  return pcall(fn, index) and true or false
end

-- ---------------------------------------------------------------------------
-- Gate
-- ---------------------------------------------------------------------------

-- Resolved once and cached: UnitClass cannot change within a session, and this
-- is consulted on every press.
local function IsDruid()
  if classKnown then return isDruid end

  local fn = ResolveApiFn("UnitClass")
  if not fn then return false end
  local ok, _, token = pcall(fn, "player")
  if not ok then return false end

  classKnown = true
  isDruid = (token == "DRUID")
  return isDruid
end

local function Enabled()
  if not cfg or not cfg.enabled then return false end
  if not IsDruid() then return false end
  -- Nothing to smooth for a class that has fewer than two forms to move
  -- between, and a druid before level 10 is exactly that case.
  return FormCount() >= 2
end

-- ---------------------------------------------------------------------------
-- The transition
-- ---------------------------------------------------------------------------
local function ClearPending()
  pending = nil
  U.UnregisterUpdate("smartshift.transition")
end

local function Tick()
  if not pending then
    ClearPending()
    return
  end

  local now = Now()
  if not now then
    -- No clock, no stable interval to measure. Rather than shift blind, hand
    -- the press back: the form the press cancelled is already gone, so the
    -- player ends up in caster form and can press again.
    ClearPending()
    return
  end

  local active = ActiveForm()

  if active == pending.target then
    ClearPending()
    return
  end

  if active then
    -- Still in a form. If it is not the one this transition set out to leave,
    -- the player picked a third form by hand and that wins.
    pending.casterSince = nil
    if active ~= pending.source then
      ClearPending()
      return
    end
  elseif not pending.casterSince then
    pending.casterSince = now
  end

  if not pending.castRequested and pending.casterSince and
     (now - pending.casterSince) >= STABLE_SECONDS and
     IsCastable(pending.target) then
    pending.castRequested = true
    CastForm(pending.target)
    return
  end

  if (now - pending.startedAt) >= TIMEOUT_SECONDS then
    ClearPending()
    U.Print("form change cancelled: the target form did not become available")
  end
end

-- ---------------------------------------------------------------------------
-- Public entry point
--
-- Returns true when this module took responsibility for the press, so the
-- caller can fall back to a plain CastShapeshiftForm when it did not.
-- ---------------------------------------------------------------------------
function U.SmartShift(index)
  index = tonumber(index)
  if not index or index < 1 then return false end
  if not Enabled() then return false end
  if index > FormCount() then return false end

  local active = ActiveForm()

  -- Ctrl is the deliberate way out of a form, since a plain press no longer
  -- toggles.
  local ctrl = Call("IsControlKeyDown")
  if ctrl then
    ClearPending()
    if active == index then CastForm(index) end
    return true
  end

  -- Already there: do nothing at all. This is what makes a keybind or a macro
  -- safe to hold down.
  if active == index then
    ClearPending()
    return true
  end

  -- A repeat press for the transition already running is not a new request.
  if pending and pending.target == index then return true end

  ClearPending()

  local now = Now()
  if not now then
    -- Without a clock the staged transition cannot be timed, so fall back to
    -- the client behaviour rather than starting something that cannot finish.
    return false
  end

  -- Written out rather than folded into `active and nil or now`: that idiom
  -- yields `now` for both branches, because `active and nil` is already nil.
  -- The stable interval would then start before the form was even cancelled.
  local casterSince = nil
  if not active then casterSince = now end

  pending = {
    target = index,
    source = active,
    startedAt = now,
    casterSince = casterSince,
    castRequested = not active,
  }

  -- From caster form there is nothing to leave, so the target is cast now and
  -- the tick below only has to notice that it landed.
  if active then CastForm(active) else CastForm(index) end

  U.RegisterUpdate("smartshift.transition", 0, Tick)
  return true
end

-- ---------------------------------------------------------------------------
-- Settings surface, used by the Stance Bar page and /qtp check
-- ---------------------------------------------------------------------------
function U.GetSmartShiftSetting()
  if not cfg then return DEFAULTS.enabled end
  return cfg.enabled and true or false
end

function U.SetSmartShiftSetting(value)
  if not cfg then return end
  cfg.enabled = value and true or false
  if not cfg.enabled then ClearPending() end
end

-- Whether the option can do anything for this character, so the settings page
-- can say so instead of offering a switch that silently does nothing.
function U.SmartShiftAvailable()
  return IsDruid()
end

function SS:OnInit()
  cfg = U.ModuleConfig("smartshift", DEFAULTS)
end

function SS:OnEnable()
  if not cfg then cfg = U.ModuleConfig("smartshift", DEFAULTS) end

  -- Macro compatibility with the original addon, but never at its expense: if
  -- SmartShapeshift itself is installed it owns this global, and a /run
  -- SmartShift(3) macro keeps calling the addon the player installed for it.
  -- Ours is always reachable under its own name.
  U.SetG("QtUiPlusSmartShift", U.SmartShift)
  if U.G("SmartShift") == nil then
    U.SetG("SmartShift", U.SmartShift)
  end
end
