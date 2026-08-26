-- QtUiPlus :: modules/castbar.lua
--
-- The player's cast bar: the spell icon flush against the left edge, and the
-- progress bar filling the rest of the width to the right edge, carrying the
-- spell name and the remaining time drawn directly on top of the fill.
--
-- knowledge.json / castbar.player_events_partial (RUNTIME_PLUS_WORKING_SOURCE):
-- SPELLCAST_START and SPELLCAST_STOP are the two cast events observed firing on
-- this client (events.json, 6 captures each). The captured SPELLCAST_START
-- argument shape is *not* Vanilla's own (spell, rank, castTime) tuple: it
-- arrived as arg1="Fireball" (string, spell name), arg2=1500 (number,
-- milliseconds) -- no rank argument at all. This module reads exactly that
-- shape and nothing more. It does not call UnitCastingInfo or UnitChannelInfo,
-- which the same record explicitly says not to assume a tuple contract for on
-- this client (knowledge.json / castbar.target_polling_contract_unverified is
-- the sibling record covering why a target castbar built the same way pfUI
-- builds one is not attempted here).
--
-- Channelled casts (fishing among them) use SPELLCAST_CHANNEL_START with
-- UnrealPfUI's libcast.lua:219 argument order (arg1=castTimeMs, arg2=name),
-- the reverse of SPELLCAST_START. In-game fishing confirmed the name lands
-- as "Fishing" and the duration as ~30s. The bar drains (remaining → 0)
-- rather than filling; SPELLCAST_STOP is ignored while a channel is running
-- because vanilla fires it when the channel *opens*.
--
-- Two pieces of this bar rest on WORKING_SOURCE evidence, not on measured
-- runtime evidence, because query_compat.py returns no match at all for either
-- (api.json only covers the `core` and `actionbars` groups):
--
--   * The spell icon. SPELLCAST_START carries a name and a duration and no
--     texture, so the name is resolved to an icon by walking the spellbook with
--     GetNumSpellTabs / GetSpellTabInfo / GetSpellName / GetSpellTexture --
--     the same four calls UnrealPfUI's libs/libspell.lua uses on this same
--     client (GetSpellMaxRank / GetSpellIndex / GetSpellInfo). Every call goes
--     through Call() so a missing or differently-shaped API degrades to the
--     question-mark placeholder instead of erroring. See knowledge.json /
--     castbar.spell_icon_spellbook_lookup_unverified.
--   * Cast pushback. Getting hit mid-cast is reported by SPELLCAST_DELAYED in
--     Vanilla, and UnrealPfUI's libs/libcast.lua handles it as
--     `start = start + arg1/1000` -- i.e. the cast's start is pushed forward,
--     which rolls the fill backwards and grows the remaining time, exactly the
--     native behaviour. This module does the same. The event has *no* capture
--     in events.json, so whether this client emits it is unconfirmed; if it
--     never fires, the bar simply runs to its original duration as before. The
--     /qtp check readout counts the delays actually received so this can be
--     settled from a real fight. See knowledge.json /
--     castbar.pushback_delay_event_unconfirmed.
--
-- Scope this module still does not cover, and why:
--   * A target castbar. The only known implementation strategy (pfUI's) polls
--     UnitCastingInfo/UnitChannelInfo per unit, and that contract is
--     INCONCLUSIVE on this client. Left out until it is confirmed.
--
--     UnrealPfUI's libs/libcast.lua does not actually call a native
--     UnitCastingInfo/UnitChannelInfo -- on a Vanilla-shaped client neither
--     exists for non-player units, so libcast *defines* those two globals
--     itself. Its own cast data comes from two sources, neither of them a cast
--     API: player casts from the same SPELLCAST_* events this module already
--     reads, and non-player casts from regex-matching combat-log text (e.g.
--     "%s begins to cast %s.") off CHAT_MSG_SPELL_* events, looked up against
--     a static per-spell-name cast-time table (L["spells"]). query_compat.py
--     has no record at all for CHAT_MSG_SPELL or that combat-log phrasing, so
--     this fallback is exactly as unverified on this client as the native
--     tuple it would replace -- it is not a usable evidence-gap default here,
--     only a second thing that would need its own probe. A target castbar
--     mover anchor is registered below (castbar.target) so the frame can be
--     placed now; it carries no live cast data until one of these two paths
--     is confirmed.

local U = QtUiPlus
local M = U.media

local CB = U.RegisterModule("castbar")

-- Cell layout: the icon is flush against the bar cell (no gap between them),
-- and the bar cell takes the rest of the width up to the right edge -- there
-- is no separate cell for the timer, which is drawn on top of the bar instead.
-- Width and height are stored per bar and live-resized from a corner grip in
-- edit mode, the same recipe as pet / ToT unit frames.
local DEFAULT_HEIGHT = 24
local DEFAULT_WIDTH = 230
local SIZE_DEFAULTS = {
  playerWidth = DEFAULT_WIDTH, playerHeight = DEFAULT_HEIGHT,
  targetWidth = DEFAULT_WIDTH, targetHeight = DEFAULT_HEIGHT,
}
local SIZE_LIMITS = {
  width  = { min = 120, max = 500 },
  height = { min = 16,  max = 80 },
}
local GRIP_SIZE = 14

local sizeCfg

-- Shown whenever the spellbook lookup cannot produce a real icon, so the left
-- cell is never an empty hole.
local FALLBACK_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- Registered defensively: none of these has ever been observed firing
-- (events.json has no capture for any of them), so they cost nothing if this
-- client never sends one and end the cast cleanly if it does.
local STOP_EVENTS = {
  "SPELLCAST_FAILED", "SPELLCAST_INTERRUPTED",
}

local bar
local casting = false
local channeling = false
local startTime, duration
local lastTimeText
local pendingCommit

-- Anchor-only: mover target for a future target castbar. No cast events feed
-- it yet (see the header note on castbar.target_polling_contract_unverified
-- and the CHAT_MSG_SPELL evidence gap), so it only ever shows the idle
-- placeholder, and only while the UI is unlocked -- there is no live state to
-- show it for otherwise.
local targetBar

-- knowledge.json / castbar.native_frame_suppression_unverified: both
-- UnrealPfUI and PotatoUI suppress this client's stock player castbar through
-- the global CastingBarFrame. This is WORKING_SOURCE evidence rather than a
-- focused runtime result, so every operation is guarded and a missing or
-- differently shaped native frame leaves the QtUiPlus castbar functional.
local nativeCastbarSuppressed = false

-- Native CastingBarFrame is a StatusBar: parent alpha is ignored and a Lua
-- Hide() is undone the next time the client calls Show() from SPELLCAST_*.
-- UnregisterAllEvents is the measured cause of native-frame stalls
-- (compat.unregisterallevents_native_frame_stall), so this never strips
-- events. Neutralise Show, zero the fill, and let the periodic sweep keep
-- the named children down.
local NATIVE_CASTBAR_NAMES = {
  "CastingBarFrame",
  "CastingBarSpark",
  "CastingBarFlash",
  "CastingBarText",
  "CastingBarBorder",
}

local function PunchNativePart(object)
  if not object then return end
  if object.SetValue then pcall(object.SetValue, object, 0) end
  if object.SetMinMaxValues then pcall(object.SetMinMaxValues, object, 0, 1) end
  if object.SetStatusBarColor then pcall(object.SetStatusBarColor, object, 0, 0, 0, 0) end
  if object.SetStatusBarTexture then pcall(object.SetStatusBarTexture, object, "") end
  if object.SetAlpha then pcall(object.SetAlpha, object, 0) end
  if object.Hide then pcall(object.Hide, object) end
  if object.SetText then pcall(object.SetText, object, "") end
end

local function PunchNativeCastbar(deep)
  local i
  for i = 1, table.getn(NATIVE_CASTBAR_NAMES) do
    PunchNativePart(U.G(NATIVE_CASTBAR_NAMES[i]))
  end
  if not deep then return end
  local native = U.G("CastingBarFrame")
  if not native then return end
  local regions = native.GetRegions and { native:GetRegions() } or {}
  for i = 1, table.getn(regions) do PunchNativePart(regions[i]) end
  local children = native.GetChildren and { native:GetChildren() } or {}
  for i = 1, table.getn(children) do PunchNativePart(children[i]) end
end

-- Hide() from OnShow is ignored while the client is still showing the frame,
-- and StatusBar fill ignores alpha. Replace the scripts so SPELLCAST_* never
-- paints, without UnregisterAllEvents (that call stalls native frames).
local function KillNativeCastbarScripts(native)
  if not native or type(native.SetScript) ~= "function" then return end
  local function KeepHidden()
    PunchNativeCastbar(true)
  end
  pcall(native.SetScript, native, "OnEvent", KeepHidden)
  pcall(native.SetScript, native, "OnShow", KeepHidden)
  -- Hidden frames still receiving OnUpdate would walk regions every
  -- frame; just Hide. OnEvent/OnShow do the deep punch.
  pcall(native.SetScript, native, "OnUpdate", function()
    if native.Hide then pcall(native.Hide, native) end
    if native.SetAlpha then pcall(native.SetAlpha, native, 0) end
  end)
end

local function SuppressNativeCastbar()
  if type(U.SuppressNativeFrame) == "function" then
    U.SuppressNativeFrame(NATIVE_CASTBAR_NAMES)
  end

  local native = U.G("CastingBarFrame")
  if native then
    if native.Show then
      pcall(function() native.Show = function() end end)
    end
    -- Emberveil may keep a Lua OnEvent global even after the widget script
    -- is replaced. Swallow it so the stock bar cannot repaint.
    if type(U.SetG) == "function" then
      pcall(U.SetG, "CastingBarFrame_OnEvent", function() end)
      pcall(U.SetG, "CastingBarFrame_OnUpdate", function() end)
      pcall(U.SetG, "CastingBarFrame_OnShow", function() end)
    end
    KillNativeCastbarScripts(native)
    if native.showCastbar ~= nil then native.showCastbar = false end
  end

  PunchNativeCastbar(true)
  nativeCastbarSuppressed = native and true or false
end

-- Pushback bookkeeping, reported by /qtp check: how many SPELLCAST_DELAYED
-- events this client actually delivered, and how much time they added.
local delayCount = 0
local delaySeconds = 0
local lastIconSource = "none"

-- Same shape as modules/actionbar.lua's helper: a global that is missing or
-- differently shaped here returns nil rather than erroring.
local function ClampSize(kind, value)
  local limit = SIZE_LIMITS[kind]
  value = tonumber(value)
  if not limit then return value end
  if not value then return limit.min end
  value = U.Round(value)
  if value < limit.min then value = limit.min end
  if value > limit.max then value = limit.max end
  return value
end

local function SizeConfig()
  if not sizeCfg then sizeCfg = U.ModuleConfig("castbar", SIZE_DEFAULTS) end
  return sizeCfg
end

-- SetAllPoints / SetWidth textures on this client keep their last raster
-- size. After the outer box moves, stamp them again from the frame they
-- belong to so a dark leftover does not sit behind the new size.
local function RestampFill(frame)
  if not frame then return end
  if frame.qtpFill then
    frame.qtpFill:ClearAllPoints()
    frame.qtpFill:SetAllPoints(frame)
  end
  if frame.qtpBackground then
    frame.qtpBackground:ClearAllPoints()
    frame.qtpBackground:SetAllPoints(frame)
  end
end

-- The mover handle is a SetAllPoints child. That pin does not follow
-- StartSizing, so the yellow outline stays at the old size while the bar
-- itself moves. Re-pin every layout.
local function RefitCoverChildren(widget)
  if not widget or not widget.GetChildren then return end
  local children = { widget:GetChildren() }
  local i
  for i = 1, table.getn(children) do
    local child = children[i]
    if child and child ~= widget.iconCell and child ~= widget.barCell
       and child ~= widget.qtpResizeGrip then
      child:ClearAllPoints()
      child:SetAllPoints(widget)
      RestampFill(child)
    end
  end
end

-- Rebuilds icon cell, progress cell and fill from a new outer size. The icon
-- stays square (equal to height) so stretching the bar only lengthens the
-- progress cell.
--
-- Size comes from corner pins, not SetWidth/SetHeight on the children.
-- SetHeight is a no-op here once a frame has both a top and a bottom point,
-- and SetWidth on the inner status bar was leaving its dark background at
-- the previous size -- the extra box behind the yellow outline. The outer
-- widget is the only thing StartSizing owns; everything else is stretched
-- to that box. skipOuter skips SetWidth on the outer so we do not fight
-- the drag.
local function LayoutWidget(widget, width, height, skipOuter)
  if not widget then return end
  width = tonumber(width)
  height = tonumber(height)
  if not skipOuter then
    width = ClampSize("width", width)
    height = ClampSize("height", height)
    widget:SetWidth(width)
    widget:SetHeight(height)
  else
    if not width or width < 1 then width = SIZE_LIMITS.width.min end
    if not height or height < 1 then height = SIZE_LIMITS.height.min end
  end

  local showIcon = widget.showIcon ~= false and widget.iconCell
  local iconSize = showIcon and height or 0
  local barWidth = width - iconSize
  if barWidth < 1 then barWidth = 1 end
  local border = U.BorderSize()

  if widget.iconCell then
    widget.iconCell:ClearAllPoints()
    widget.iconCell:SetPoint("TOPLEFT", widget, "TOPLEFT", 0, 0)
    widget.iconCell:SetPoint("BOTTOMLEFT", widget, "BOTTOMLEFT", 0, 0)
    -- Width = height without SetWidth: the right edge sits `height` in from
    -- the outer left. Hidden icon still occupies no barCell space because
    -- barCell pins to the outer left instead.
    widget.iconCell:SetPoint("TOPRIGHT", widget, "TOPLEFT", height, 0)
    RestampFill(widget.iconCell)
    if widget.icon then
      local inset = U.BorderSize()
      widget.icon:ClearAllPoints()
      widget.icon:SetPoint("TOPLEFT", widget.iconCell, "TOPLEFT", inset, -inset)
      widget.icon:SetPoint("BOTTOMRIGHT", widget.iconCell, "BOTTOMRIGHT",
                           -inset, inset)
    end
  end
  if widget.barCell then
    widget.barCell:ClearAllPoints()
    if showIcon then
      widget.barCell:SetPoint("TOPLEFT", widget.iconCell, "TOPRIGHT", 0, 0)
    else
      widget.barCell:SetPoint("TOPLEFT", widget, "TOPLEFT", 0, 0)
    end
    widget.barCell:SetPoint("BOTTOMRIGHT", widget, "BOTTOMRIGHT", 0, 0)
    RestampFill(widget.barCell)
  end
  if widget.bar then
    local innerW = barWidth - 2 * border
    local innerH = height - 2 * border
    if innerW < 1 then innerW = 1 end
    if innerH < 1 then innerH = 1 end
    -- Stamp the fill math first, then pin. SizeStatusBar also SetWidth, which
    -- on this client either no-ops or would let the dark background outgrow
    -- the yellow outline; the two-point pin is what actually sizes it.
    if U.SizeStatusBar then
      U.SizeStatusBar(widget.bar, innerW, innerH)
    else
      widget.bar.qtpLayoutWidth = innerW
      widget.bar.qtpLayoutHeight = innerH
      local value = widget.bar.qtpValue
      widget.bar.qtpValue = nil
      pcall(widget.bar.SetValue, widget.bar, value)
    end
    widget.bar:ClearAllPoints()
    widget.bar:SetPoint("TOPLEFT", widget.barCell, "TOPLEFT", border, -border)
    widget.bar:SetPoint("BOTTOMRIGHT", widget.barCell, "BOTTOMRIGHT",
                        -border, border)
    RestampFill(widget.bar)
  end
  if widget.name then
    pcall(widget.name.SetWidth, widget.name, math.max(20, barWidth - 34))
  end

  RefitCoverChildren(widget)

  widget.qtpWidth = skipOuter and ClampSize("width", width) or width
  widget.qtpHeight = skipOuter and ClampSize("height", height) or height
end

local function ApplyStoredSize(widget, prefix)
  local cfg = SizeConfig()
  LayoutWidget(widget, cfg[prefix .. "Width"], cfg[prefix .. "Height"])
end

local function ReadWidgetSize(widget)
  local w, h
  if widget.GetWidth then
    local ok, value = pcall(widget.GetWidth, widget)
    if ok then w = tonumber(value) end
  end
  if widget.GetHeight then
    local ok, value = pcall(widget.GetHeight, widget)
    if ok then h = tonumber(value) end
  end
  -- StartSizing can stretch the on-screen box without updating GetWidth on
  -- this client. The edge readback is the size the user actually dragged.
  local okL, left = pcall(widget.GetLeft, widget)
  local okR, right = pcall(widget.GetRight, widget)
  local okT, top = pcall(widget.GetTop, widget)
  local okB, bottom = pcall(widget.GetBottom, widget)
  if okL and okR and tonumber(left) and tonumber(right) then
    local edgeW = math.abs(right - left)
    if edgeW > 1 and (not w or math.abs(edgeW - w) > 1) then w = edgeW end
  end
  if okT and okB and tonumber(top) and tonumber(bottom) then
    local edgeH = math.abs(top - bottom)
    if edgeH > 1 and (not h or math.abs(edgeH - h) > 1) then h = edgeH end
  end
  return w, h
end

local function CommitWidgetResize(widget, prefix, moverId)
  if not widget then return end
  local w, h = ReadWidgetSize(widget)
  -- StartSizing can leave extra anchors that ignore SetHeight. Applying the
  -- stored mover point (not a freshly captured one) is the working restore
  -- path on this client; the size stamp then sticks.
  LayoutWidget(widget, w, h)
  local cfg = SizeConfig()
  cfg[prefix .. "Width"] = widget.qtpWidth
  cfg[prefix .. "Height"] = widget.qtpHeight
  LayoutWidget(widget, cfg[prefix .. "Width"], cfg[prefix .. "Height"])

  if moverId and type(U.GetFramePoint) == "function" and type(U.SavePosition) == "function" then
    local point, _, relativePoint, x, y = U.GetFramePoint(widget, 1)
    if point then U.SavePosition(moverId, point, relativePoint, x, y) end
  end

  -- Recapture-then-SetPoint in this same handler is a recorded failed
  -- restore. Re-apply the stored point on the next tick so StartSizing's
  -- extra anchors are gone and the clamped size sticks.
  pendingCommit = { widget = widget, prefix = prefix, moverId = moverId }
end

local function FlushPendingCommit()
  local job = pendingCommit
  if not job then return end
  pendingCommit = nil
  if job.moverId and type(U.GetPosition) == "function"
     and type(U.ApplyFramePoint) == "function" then
    local saved = U.GetPosition(job.moverId)
    if saved then U.ApplyFramePoint(job.widget, saved) end
  end
  local cfg = SizeConfig()
  LayoutWidget(job.widget, cfg[job.prefix .. "Width"],
               cfg[job.prefix .. "Height"])
end

local function AttachResizeGrip(widget, prefix, moverId)
  if not widget or widget.qtpResizeGrip then return end

  local grip = CreateFrame("Button", nil, widget)
  grip:SetWidth(GRIP_SIZE)
  grip:SetHeight(GRIP_SIZE)
  grip:SetPoint("BOTTOMRIGHT", widget, "BOTTOMRIGHT", 2, -2)
  pcall(grip.EnableMouse, grip, true)
  grip:RegisterForDrag("LeftButton")

  local levelOk, level = pcall(widget.GetFrameLevel, widget)
  if levelOk and tonumber(level) then
    pcall(grip.SetFrameLevel, grip, tonumber(level) + 30)
  end

  local icon = grip:CreateTexture(nil, "ARTWORK")
  pcall(icon.SetTexture, icon, M.texture.chatResizeGrip)
  icon:SetAllPoints(grip)
  grip.icon = icon

  grip:SetScript("OnDragStart", function()
    if not U.IsUnlocked or not U.IsUnlocked() then return end
    pcall(widget.SetResizable, widget, true)
    pcall(widget.SetMinResize, widget,
          SIZE_LIMITS.width.min, SIZE_LIMITS.height.min)
    pcall(widget.SetMaxResize, widget,
          SIZE_LIMITS.width.max, SIZE_LIMITS.height.max)
    pcall(widget.StartSizing, widget, "BOTTOMRIGHT")
    if type(U.RegisterUpdate) == "function" then
      U.RegisterUpdate("castbar.resize", 0, function()
        local liveW, liveH = ReadWidgetSize(widget)
        LayoutWidget(widget, liveW, liveH, true)
      end)
    end
  end)
  grip:SetScript("OnDragStop", function()
    if type(U.UnregisterUpdate) == "function" then
      U.UnregisterUpdate("castbar.resize")
    end
    pcall(widget.StopMovingOrSizing, widget)
    CommitWidgetResize(widget, prefix, moverId)
  end)

  widget.qtpResizeGrip = grip
  grip:Hide()
end

local gripsShown
local function UpdateResizeGrips()
  local show = U.IsUnlocked and U.IsUnlocked()
  if show == gripsShown then return end
  gripsShown = show and true or false

  local list = { bar, targetBar }
  local i
  for i = 1, table.getn(list) do
    local widget = list[i]
    if widget and widget.qtpResizeGrip then
      if gripsShown then
        local levelOk, level = pcall(widget.GetFrameLevel, widget)
        if levelOk and tonumber(level) then
          pcall(widget.qtpResizeGrip.SetFrameLevel, widget.qtpResizeGrip,
                tonumber(level) + 30)
        end
        pcall(widget.qtpResizeGrip.Show, widget.qtpResizeGrip)
        if widget.qtpResizeGrip.icon then
          pcall(widget.qtpResizeGrip.icon.Show, widget.qtpResizeGrip.icon)
        end
      else
        pcall(widget.qtpResizeGrip.Hide, widget.qtpResizeGrip)
      end
    end
  end
end

local function Call(name, a, b)
  local fn = U.G(name)
  if type(fn) ~= "function" then return nil end
  local ok, r1, r2 = pcall(fn, a, b)
  if not ok then return nil end
  return r1, r2
end

-- ---------------------------------------------------------------------------
-- Spell name -> icon
--
-- SPELLCAST_START gives a name only, so the name is matched against the
-- spellbook once per spell and cached. `false` is cached for a miss too, so a
-- spell that is not in the book (an item or a trinket proc) is not re-scanned
-- on every cast.
-- ---------------------------------------------------------------------------
local iconCache = {}

local function ScanSpellbook(lowerName)
  local bookType = U.G("BOOKTYPE_SPELL") or "spell"

  local tabs = tonumber(Call("GetNumSpellTabs"))
  if not tabs then return nil end

  local tab
  for tab = 1, tabs do
    -- GetSpellTabInfo returns name, texture, offset, numSpells in Vanilla;
    -- only the last two are used, and Call hands back the first two returns,
    -- so the tab info is read through a direct pcall instead.
    local fn = U.G("GetSpellTabInfo")
    if type(fn) ~= "function" then return nil end

    local ok, _, _, offset, count = pcall(fn, tab)
    offset, count = tonumber(offset), tonumber(count)

    if ok and offset and count then
      local id
      for id = offset + 1, offset + count do
        local spellName = Call("GetSpellName", id, bookType)
        if type(spellName) == "string" and
           string.lower(spellName) == lowerName then
          local texture = Call("GetSpellTexture", id, bookType)
          if type(texture) == "string" and texture ~= "" then
            return texture
          end
          return nil
        end
      end
    end
  end

  return nil
end

local function SpellIcon(name)
  if type(name) ~= "string" or name == "" then return nil end

  local key = string.lower(name)
  local cached = iconCache[key]
  if cached ~= nil then
    return cached or nil
  end

  local texture = ScanSpellbook(key)
  iconCache[key] = texture or false
  return texture
end

-- A spellbook miss (Hearthstone, a quest item, any other non-spell cast) used
-- to fall back to the question-mark placeholder texture; that read as a wrong
-- icon rather than an honest "no icon available", so a miss now hides the
-- whole icon cell instead (via widget.showIcon, see SetWidgetCellsShown) --
-- not just the texture, so its flat background/border don't hang around as an
-- empty box either. FALLBACK_ICON is still used for the idle placeholder
-- (ApplyIdlePlaceholder), which is a different case -- there's no cast at all
-- to have an icon for.
local function Relayout(widget)
  if not widget then return end
  LayoutWidget(widget, widget.qtpWidth or DEFAULT_WIDTH,
               widget.qtpHeight or DEFAULT_HEIGHT)
end

local function ApplyIcon(name)
  if not bar.icon then return end

  local texture = SpellIcon(name)
  lastIconSource = texture and "spellbook" or "none"

  local show = false
  if texture and pcall(bar.icon.SetTexture, bar.icon, texture) then
    show = true
  elseif texture then
    lastIconSource = "failed"
  end

  if bar.showIcon ~= show then
    bar.showIcon = show
    Relayout(bar)
  else
    bar.showIcon = show
  end
end

-- ---------------------------------------------------------------------------
-- Bar state
-- ---------------------------------------------------------------------------

local function ApplyTimer(remaining)
  if not bar.time then return end
  local text = string.format("%.1f", remaining)
  if text == lastTimeText then return end
  lastTimeText = text
  bar.time:SetText(text)
end

-- knowledge.json / rendering.parent_alpha_not_propagated: the cells are shown
-- and hidden explicitly rather than left to the container, on the same
-- reasoning the rest of QtUiPlus uses for composite frames.
--
-- The icon cell is additionally gated by widget.showIcon: when a cast has no
-- resolved icon (see ApplyIcon), the whole cell -- its flat background and
-- border, not just the texture -- is hidden instead of leaving an empty box
-- with nothing in it.
local function SetWidgetCellsShown(widget, shown)
  local i
  for i = 1, table.getn(widget.qtpCells) do
    local cell = widget.qtpCells[i]
    local cellShown = shown
    if cell == widget.iconCell and not widget.showIcon then
      cellShown = false
    end
    if cellShown then
      if not cell:IsShown() then cell:Show() end
    else
      if cell:IsShown() then cell:Hide() end
    end
  end
end

local function SetCellsShown(shown)
  SetWidgetCellsShown(bar, shown)
end

-- The target anchor carries no live cast state (see the header note), so its
-- only visibility rule is the edit lock: shown, with its idle placeholder,
-- while the UI is unlocked, and hidden otherwise.
local function UpdateTargetVisibility()
  if not targetBar then return end
  local shown = U.IsUnlocked()
  if shown then
    if not targetBar:IsShown() then targetBar:Show() end
  else
    if targetBar:IsShown() then targetBar:Hide() end
  end
  SetWidgetCellsShown(targetBar, shown)
end

-- Kept shown and given a placeholder fill while the UI is unlocked, on the
-- same reasoning as the unit frames' empty-unit shell: a frame that only
-- exists while it has something to show could never be dragged into place.
local function ApplyIdlePlaceholder()
  U.SetStatusBarColor(bar.bar, M.Unpack(M.color.cast))
  pcall(bar.bar.SetMinMaxValues, bar.bar, 0, 1)
  pcall(bar.bar.SetValue, bar.bar, 0.4)
  if bar.name then bar.name:SetText("Cast bar") end
  if bar.icon then pcall(bar.icon.SetTexture, bar.icon, FALLBACK_ICON) end
  if bar.showIcon ~= true then
    bar.showIcon = true
    Relayout(bar)
  else
    bar.showIcon = true
  end
  -- Applied immediately rather than waiting for the next Tick's
  -- UpdateVisibility: a cast that just ended with no icon left the cell
  -- hidden, and it would otherwise stay hidden for one extra frame.
  SetCellsShown(true)
  lastTimeText = nil
  if bar.time then bar.time:SetText("0.0") end
end

local function UpdateVisibility()
  local shown = casting or U.IsUnlocked()
  if shown then
    if not bar:IsShown() then bar:Show() end
  else
    if bar:IsShown() then bar:Hide() end
  end
  SetCellsShown(shown)
end

-- Duration arrives in milliseconds for both SPELLCAST_START and
-- SPELLCAST_CHANNEL_START. Values already in seconds (a 1.5s Fireball, a
-- 30s fish) are left alone: anything above 50 is treated as ms.
local function DurationSeconds(value)
  value = tonumber(value) or 0
  if value > 50 then value = value / 1000 end
  if value <= 0 then value = 0.01 end
  return value
end

local function StartCast(name, castTimeMs, isChannel)
  casting = true
  channeling = isChannel and true or false
  startTime = GetTime()
  duration = DurationSeconds(castTimeMs)

  delayCount, delaySeconds = 0, 0

  U.SetStatusBarColor(bar.bar, M.Unpack(M.color.cast))
  pcall(bar.bar.SetMinMaxValues, bar.bar, 0, duration)
  -- Channels drain (full → empty). Ordinary casts fill (empty → full).
  if channeling then
    pcall(bar.bar.SetValue, bar.bar, duration)
  else
    pcall(bar.bar.SetValue, bar.bar, 0)
  end
  if bar.name then bar.name:SetText(tostring(name or "")) end
  ApplyIcon(name)
  lastTimeText = nil
  ApplyTimer(duration)

  PunchNativeCastbar(true)
  UpdateVisibility()
end

-- Cast pushback. UnrealPfUI's libs/libcast.lua does exactly this on
-- SPELLCAST_DELAYED (`start = start + arg1/1000`): the start moves forward, so
-- the elapsed time this module derives from it shrinks and the fill rolls
-- backwards while the remaining time grows -- the native castbar's behaviour.
-- The total duration is deliberately untouched; only the end point moves.
local function DelayCast(delayMs)
  if not casting or channeling then return end

  local delay = (tonumber(delayMs) or 0) / 1000
  if delay <= 0 then return end

  startTime = startTime + delay
  delayCount = delayCount + 1
  delaySeconds = delaySeconds + delay

  -- Redraw immediately rather than waiting up to a tick: a pushback that only
  -- showed on the next 0.1s tick would read as a stutter, not a rollback.
  local elapsed = GetTime() - startTime
  if elapsed < 0 then elapsed = 0 end
  pcall(bar.bar.SetValue, bar.bar, elapsed)
  ApplyTimer(duration - elapsed)
end

-- SPELLCAST_CHANNEL_UPDATE: arg1 is the new remaining time in ms. Shift the
-- start so the drain matches, the same way UnrealPfUI's libcast.lua does.
local function UpdateChannel(remainingMs)
  if not channeling then return end
  local remaining = DurationSeconds(remainingMs)
  startTime = GetTime() + remaining - duration
  if startTime > GetTime() then startTime = GetTime() end
  pcall(bar.bar.SetValue, bar.bar, remaining)
  ApplyTimer(remaining)
end

local function StopCast()
  if not casting then return end
  casting = false
  channeling = false
  UpdateVisibility()
end

-- Vanilla fires SPELLCAST_STOP when a channel *starts* (the cast that opens
-- the channel finished). Ending the bar on that event would snap fishing
-- back to the idle placeholder after one frame.
local function OnHardStop()
  if channeling then return end
  StopCast()
end

local function Tick()
  if U.PerfDisabled and U.PerfDisabled("castbar") then return end

  FlushPendingCommit()
  UpdateVisibility()
  UpdateTargetVisibility()
  UpdateResizeGrips()
  -- Native bar Show() is often ignored mid-event; keep punching whenever
  -- the stock frame is actually on screen, not only while we think we
  -- own a cast (item uses like a recipe can paint native without our
  -- SPELLCAST_START).
  local native = U.G("CastingBarFrame")
  if native then
    local ok, shown = pcall(native.IsShown, native)
    if (ok and shown) or casting then
      PunchNativeCastbar(true)
    end
  end

  if not casting then
    if bar:IsShown() then ApplyIdlePlaceholder() end
    return
  end

  local elapsed = GetTime() - startTime
  if elapsed >= duration then
    -- No stop event arrived before the computed duration ran out. Treat the
    -- cast as finished rather than leaving a full bar on screen indefinitely.
    StopCast()
    return
  end

  -- A pushback can move the start ahead of now for a frame; clamp rather than
  -- hand the fill a negative value.
  if elapsed < 0 then elapsed = 0 end

  local remaining = duration - elapsed
  if channeling then
    pcall(bar.bar.SetValue, bar.bar, remaining)
  else
    pcall(bar.bar.SetValue, bar.bar, elapsed)
  end
  ApplyTimer(remaining)
end

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

-- Shared cell layout for both the player bar and the target anchor: the
-- icon flush left, the progress bar filling the rest of the width, name and
-- timer drawn on top of the fill. `frameName` distinguishes the created
-- widget names so registering both bars does not collide.
local function BuildBarWidget(frameName)
  local width = DEFAULT_WIDTH
  local height = DEFAULT_HEIGHT
  local iconSize = height
  local barWidth = width - iconSize

  local widget = CreateFrame("Frame", frameName, UIParent)
  widget:SetWidth(width)
  widget:SetHeight(height)

  local border = U.BorderSize()

  -- Left cell: the spell icon.
  local iconCell = U.CreatePanel(widget, {
    name = frameName .. "Icon",
    width = iconSize,
    height = height,
  })
  iconCell:SetPoint("TOPLEFT", widget, "TOPLEFT", 0, 0)

  local icon = iconCell:CreateTexture(nil, "ARTWORK")
  icon:SetPoint("TOPLEFT", iconCell, "TOPLEFT", border, -border)
  icon:SetPoint("BOTTOMRIGHT", iconCell, "BOTTOMRIGHT", -border, border)
  -- Trimmed the way modules/actionbar.lua trims its icons, so the stock icon
  -- border does not show inside the cell.
  pcall(icon.SetTexCoord, icon, 0.08, 0.92, 0.08, 0.92)
  pcall(icon.SetTexture, icon, FALLBACK_ICON)
  widget.icon = icon
  widget.iconCell = iconCell
  widget.showIcon = true

  -- Right cell: the progress bar, flush against the icon and filling the rest
  -- of the width to the right edge, with the spell name and the timer both
  -- drawn on top of it.
  local barCell = U.CreatePanel(widget, {
    name = frameName .. "Progress",
    width = barWidth,
    height = height,
  })
  barCell:SetPoint("TOPLEFT", iconCell, "TOPRIGHT", 0, 0)

  widget.bar = U.CreateStatusBar(barCell, {
    width = barWidth - 2 * border,
    height = height - 2 * border,
    color = M.color.cast,
    background = M.color.healthBg,
  })
  widget.bar:SetPoint("TOPLEFT", barCell, "TOPLEFT", border, -border)

  -- knowledge.json / fonts.stretched_justification_ignored: anchored to the
  -- one edge it belongs to, with an explicit width so a long spell name stops
  -- before the timer instead of running under it.
  widget.name = U.CreateLabel(widget.bar, {
    size = M.fontSize.small,
    color = M.color.text,
    inherits = "GameFontNormalSmall",
    justify = "LEFT",
  })
  if widget.name then
    widget.name:SetPoint("LEFT", widget.bar, "LEFT", 3, 0)
    pcall(widget.name.SetWidth, widget.name, barWidth - 34)
  end

  -- The timer. A FontString's OVERLAY draw layer sits above the fill
  -- texture's ARTWORK layer, so parenting it directly to the bar draws it on
  -- top of the progress fill rather than in a separate cell.
  widget.time = U.CreateLabel(widget.bar, {
    size = M.fontSize.small,
    color = M.color.text,
    inherits = "GameFontNormalSmall",
  })
  if widget.time then widget.time:SetPoint("RIGHT", widget.bar, "RIGHT", -3, 0) end

  widget.qtpCells = { iconCell, barCell }

  return widget
end

local function Build()
  -- The container carries no art of its own: it is the mover target and the
  -- anchor the two cells hang off, so each cell keeps its own outline the way
  -- the reference layout shows them.
  bar = BuildBarWidget("QtUiPlusCastBar")
  ApplyStoredSize(bar, "player")
  bar:Hide()
  SetCellsShown(false)

  U.RegisterMover("castbar.player", bar, {
    label = "Cast bar",
    default = { point = "CENTER", relativePoint = "CENTER", x = 0, y = -220 },
  })
  AttachResizeGrip(bar, "player", "castbar.player")

  -- Anchor-only target castbar (see the header note): built the same way as
  -- the player bar so its placeholder matches, but nothing ever calls
  -- StartCast/StopCast on it. It is shown only while the UI is unlocked, on
  -- the same reasoning as the player bar's idle placeholder -- a frame that
  -- only exists once it has data could never be dragged into place.
  targetBar = BuildBarWidget("QtUiPlusCastBarTarget")
  ApplyStoredSize(targetBar, "target")
  U.SetStatusBarColor(targetBar.bar, M.Unpack(M.color.cast))
  pcall(targetBar.bar.SetMinMaxValues, targetBar.bar, 0, 1)
  pcall(targetBar.bar.SetValue, targetBar.bar, 0.4)
  if targetBar.name then targetBar.name:SetText("Target cast bar") end
  if targetBar.time then targetBar.time:SetText("0.0") end
  targetBar:Hide()

  U.RegisterMover("castbar.target", targetBar, {
    label = "Target cast bar",
    default = { point = "CENTER", relativePoint = "CENTER", x = 0, y = -250 },
  })
  AttachResizeGrip(targetBar, "target", "castbar.target")
end

function CB:OnInit()
  sizeCfg = U.ModuleConfig("castbar", SIZE_DEFAULTS)
end

function CB:OnEnable()
  if bar then return end
  Build()
  SuppressNativeCastbar()

  U.RegisterEvent("SPELLCAST_START", function(event, name, castTimeMs)
    StartCast(name, castTimeMs, false)
  end)

  -- Reversed argument order from SPELLCAST_START -- see the header note on
  -- the channelled-cast evidence gap (castTimeMs first, name second, per
  -- UnrealPfUI's libcast.lua:219). Types are swapped if the client hands
  -- them the other way around, so a fishing start still gets a name and a
  -- duration rather than "30000" as the label.
  U.RegisterEvent("SPELLCAST_CHANNEL_START", function(event, a, b)
    local ms, name
    if type(a) == "number" then
      ms, name = a, b
    elseif type(b) == "number" then
      name, ms = a, b
    else
      name, ms = a, b
    end
    if type(name) ~= "string" then name = tostring(name or "") end
    StartCast(name, ms, true)
  end)

  U.RegisterEvent("SPELLCAST_DELAYED", function(event, delayMs)
    DelayCast(delayMs)
  end)

  U.RegisterEvent("SPELLCAST_CHANNEL_UPDATE", function(event, remainingMs)
    UpdateChannel(remainingMs)
  end)

  U.RegisterEvent("SPELLCAST_STOP", OnHardStop)

  local i
  for i = 1, table.getn(STOP_EVENTS) do
    U.RegisterEvent(STOP_EVENTS[i], StopCast)
  end

  U.RegisterEvent("SPELLCAST_CHANNEL_STOP", StopCast)

  -- Same invalidation UnrealPfUI's libspell uses: a newly learned rank changes
  -- which spellbook index a name resolves to.
  U.RegisterEvent("LEARNED_SPELL_IN_TAB", function()
    iconCache = {}
  end)

  -- 0 runs every frame, the same convention core/widgets.lua's slider drag
  -- ticker uses for per-frame motion: at 0.1s the fill visibly stepped
  -- instead of sliding, since ApplyTimer's own text-change check already
  -- throttles the one part of Tick that doesn't need to run every frame.
  U.RegisterUpdate("castbar.tick", 0, Tick)
end

-- Measured state for /qtp check: what the client actually sent, not another
-- assumption about the SPELLCAST_START tuple. iconSource and delays are the
-- two fields that settle the WORKING_SOURCE gaps in this module's header --
-- whether the spellbook lookup resolves a real texture, and whether this
-- client emits SPELLCAST_DELAYED at all.
function U.CastbarReport()
  if not bar then return nil end

  local shownOk, shown = pcall(bar.IsShown, bar)
  return {
    casting = casting,
    channeling = channeling,
    shown = shownOk and shown or "?",
    duration = duration,
    remaining = casting and (duration - (GetTime() - startTime)) or nil,
    iconSource = lastIconSource,
    delays = delayCount,
    delaySeconds = delaySeconds,
    nativeSuppressed = nativeCastbarSuppressed,
  }
end
