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
-- Target castbar follows UnrealPfUI's modules/castbar.lua OnUpdate, not
-- UnrealUI (which never fed the target bar). Each tick:
--   1. Poll UnitCastingInfo("target"), then UnitChannelInfo("target").
--      Emberveil's player tuple is empty (pfUI: "prefer SPELLCAST_*"), but
--      the same poll is what fills pfUI's target bar when the API answers.
--   2. If the API is empty, use a combat-log cache (CHAT_MSG_SPELL_* +
--      SPELLCASTOTHERSTART / SPELLPERFORMOTHERSTART), the same path as
--      libs/libcast.lua. Durations come from spells we have already seen
--      (player SPELLCAST_START and successful API polls), so a missing
--      locale spell table does not invent a length.

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
local lastCastName
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
-- Spell name (lower) -> cast time in milliseconds. Filled from the player's
-- own SPELLCAST_* and from any UnitCastingInfo poll that returned times.
local durationCache = {}

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

local function SetWidgetIcon(widget, name, textureHint)
  if not widget or not widget.icon then return end

  local texture = textureHint
  if type(texture) ~= "string" or texture == "" then
    texture = SpellIcon(name)
  end
  if widget == bar then
    lastIconSource = texture and (textureHint and "api" or "spellbook") or "none"
  end

  local show = false
  if texture and pcall(widget.icon.SetTexture, widget.icon, texture) then
    show = true
  elseif texture and widget == bar then
    lastIconSource = "failed"
  end

  if widget.showIcon ~= show then
    widget.showIcon = show
    Relayout(widget)
  else
    widget.showIcon = show
  end
end

local function ApplyIcon(name)
  SetWidgetIcon(bar, name)
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

local function RememberDuration(name, seconds)
  if type(name) ~= "string" or name == "" then return end
  seconds = tonumber(seconds)
  if not seconds or seconds <= 0.05 then return end
  durationCache[string.lower(name)] = seconds * 1000
end

-- ---------------------------------------------------------------------------
-- Target cast
--
-- pfUI modules/castbar.lua: poll UnitCastingInfo then UnitChannelInfo, then
-- libcast.db[UnitName]. Combat-log rows only start a bar when we already
-- know a duration for that spell name (player casts and API polls fill the
-- cache), matching libcast's "unknown spell => ignore" rule without shipping
-- pfUI's locale spell table.
-- ---------------------------------------------------------------------------
local combatCasts = {}
local targetSource = "none"
local CAST_PATTERNS, INTERRUPT_PATTERNS

local function CompileChatPattern(globalName, fallback)
  local raw = U.G(globalName)
  if type(raw) ~= "string" or raw == "" then raw = fallback end
  if type(raw) ~= "string" then return nil end
  raw = string.gsub(raw, "%%s", "(.+)")
  raw = string.gsub(raw, "%%d", "(%%d+)")
  if string.sub(raw, -1) == "." then
    raw = string.sub(raw, 1, -2) .. "%."
  end
  return "^" .. raw .. "$"
end

local function EnsureCastPatterns()
  if CAST_PATTERNS then return end
  CAST_PATTERNS = {
    CompileChatPattern("SPELLCASTOTHERSTART", "%s begins to cast %s."),
    CompileChatPattern("SPELLPERFORMOTHERSTART", "%s begins to perform %s."),
    "^(.+) begins to cast (.+)%.$",
    "^(.+) begins to perform (.+)%.$",
    "^(.+) beginnt, (.+) zu wirken%.$",
    "^(.+) beginnt, (.+) auszuführen%.$",
  }
  INTERRUPT_PATTERNS = {
    CompileChatPattern("SPELLINTERRUPTSELFOTHER", "You interrupt %s's %s."),
    CompileChatPattern("SPELLINTERRUPTOTHEROTHER", "%s interrupts %s's %s."),
    "^You interrupt (.+)'s (.+)%.$",
    "^(.+) interrupts (.+)'s (.+)%.$",
    "^Ihr unterbrecht (.+)s (.+)%.$",
  }
end

local function MatchTwo(msg, patterns)
  local i
  for i = 1, table.getn(patterns) do
    local pat = patterns[i]
    if pat then
      local _, _, a, b = string.find(msg, pat)
      if a and b then return a, b end
    end
  end
  return nil
end

local function MatchInterrupt(msg)
  local i
  for i = 1, table.getn(INTERRUPT_PATTERNS) do
    local pat = INTERRUPT_PATTERNS[i]
    if pat then
      local _, _, a, b, c = string.find(msg, pat)
      -- self-interrupt: (mob, spell); other: (source, mob, spell)
      if c then return b end
      if a and b then return a end
    end
  end
  return nil
end

local function CombatCastFor(unitName)
  if type(unitName) ~= "string" or unitName == "" then return nil end
  local row = combatCasts[string.lower(unitName)]
  if not row then return nil end
  if GetTime() >= row.start + row.duration then
    combatCasts[string.lower(unitName)] = nil
    return nil
  end
  return row
end

local function NoteCombatCast(mob, spell)
  if type(mob) ~= "string" or type(spell) ~= "string" then return end
  local ms = durationCache[string.lower(spell)]
  if not ms then return end
  combatCasts[string.lower(mob)] = {
    name = spell,
    start = GetTime(),
    duration = ms / 1000,
    channel = false,
    texture = SpellIcon(spell),
  }
end

local function ClearCombatCast(mob)
  if type(mob) ~= "string" then return end
  combatCasts[string.lower(mob)] = nil
end

local function OnCombatLog(event, msg)
  if type(msg) ~= "string" or msg == "" then return end
  EnsureCastPatterns()
  local mob, spell = MatchTwo(msg, CAST_PATTERNS)
  if mob and spell then
    NoteCombatCast(mob, spell)
    return
  end
  local interrupted = MatchInterrupt(msg)
  if interrupted then ClearCombatCast(interrupted) end
end

local function ParseCastApi(a, b, c, d, e, f)
  if type(a) ~= "string" or a == "" then return nil end
  local startSec = tonumber(e) or tonumber(c)
  local endSec = tonumber(f) or tonumber(d)
  if not startSec or not endSec or endSec <= startSec then return nil end
  local now = GetTime()
  if endSec > now * 10 then
    startSec = startSec / 1000
    endSec = endSec / 1000
  end
  if endSec <= startSec or now > endSec + 0.15 then return nil end
  local texture
  if type(d) == "string" and string.find(d, "\\") then
    texture = d
  elseif type(c) == "string" and string.find(c, "\\") then
    texture = c
  end
  return {
    name = a,
    start = startSec,
    stop = endSec,
    texture = texture,
  }
end

local function CallCastApi(fnName, unit)
  local fn = U.G(fnName)
  if type(fn) ~= "function" or type(unit) ~= "string" or unit == "" then
    return nil
  end
  local ok, a, b, c, d, e, f = pcall(fn, unit)
  if not ok then return nil end
  return ParseCastApi(a, b, c, d, e, f)
end

local function QueryUnitCast(unit)
  if type(unit) ~= "string" or unit == "" then return nil, false end
  if not Call("UnitExists", unit) then return nil, false end

  if Call("UnitIsUnit", unit, "player") and casting and startTime and duration then
    return {
      name = lastCastName or "",
      start = startTime,
      stop = startTime + duration,
      channel = channeling and true or false,
    }, channeling and true or false
  end

  local queries = { unit }
  local name = Call("UnitName", unit)
  if type(name) == "string" and name ~= "" and name ~= unit then
    table.insert(queries, name)
  end
  local existsFn = U.G("UnitExists")
  if type(existsFn) == "function" then
    local ok, _, guid = pcall(existsFn, unit)
    if ok and type(guid) == "string" and guid ~= "" then
      table.insert(queries, guid)
    end
  end

  local i
  for i = 1, table.getn(queries) do
    local q = queries[i]
    local info = CallCastApi("UnitCastingInfo", q)
    if info then
      info.channel = false
      return info, false
    end
    info = CallCastApi("UnitChannelInfo", q)
    if info then
      info.channel = true
      return info, true
    end
  end

  local row = CombatCastFor(name)
  if row then
    return {
      name = row.name,
      start = row.start,
      stop = row.start + row.duration,
      texture = row.texture,
      channel = row.channel and true or false,
    }, row.channel and true or false
  end
  return nil, false
end

local function ApplyWidgetTimer(widget, remaining)
  if not widget or not widget.time then return end
  local text = string.format("%.1f", remaining)
  if widget.qtpLastTimeText == text then return end
  widget.qtpLastTimeText = text
  widget.time:SetText(text)
end

local function PaintTargetIdle()
  if not targetBar then return end
  U.SetStatusBarColor(targetBar.bar, M.Unpack(M.color.cast))
  pcall(targetBar.bar.SetMinMaxValues, targetBar.bar, 0, 1)
  pcall(targetBar.bar.SetValue, targetBar.bar, 0.4)
  if targetBar.name then targetBar.name:SetText("Target cast bar") end
  if targetBar.icon then
    pcall(targetBar.icon.SetTexture, targetBar.icon, FALLBACK_ICON)
  end
  if targetBar.showIcon ~= true then
    targetBar.showIcon = true
    Relayout(targetBar)
  else
    targetBar.showIcon = true
  end
  targetBar.qtpLastTimeText = nil
  if targetBar.time then targetBar.time:SetText("0.0") end
  targetSource = "idle"
end

local function PaintTargetCast(info)
  if not targetBar or not info then return end
  local duration = info.stop - info.start
  if duration <= 0 then duration = 0.01 end
  local elapsed = GetTime() - info.start
  if elapsed < 0 then elapsed = 0 end
  if elapsed > duration then elapsed = duration end
  local remaining = duration - elapsed

  RememberDuration(info.name, duration)
  U.SetStatusBarColor(targetBar.bar, M.Unpack(M.color.cast))
  pcall(targetBar.bar.SetMinMaxValues, targetBar.bar, 0, duration)
  if info.channel then
    pcall(targetBar.bar.SetValue, targetBar.bar, remaining)
  else
    pcall(targetBar.bar.SetValue, targetBar.bar, elapsed)
  end
  if targetBar.name then targetBar.name:SetText(tostring(info.name or "")) end
  SetWidgetIcon(targetBar, info.name, info.texture)
  ApplyWidgetTimer(targetBar, remaining)
end

local function TickTarget()
  if not targetBar then return end

  local info = QueryUnitCast("target")
  if info then
    targetSource = info.channel and "channel" or "cast"
    PaintTargetCast(info)
    if not targetBar:IsShown() then targetBar:Show() end
    SetWidgetCellsShown(targetBar, true)
    return
  end

  targetSource = "none"
  if U.IsUnlocked and U.IsUnlocked() then
    PaintTargetIdle()
    if not targetBar:IsShown() then targetBar:Show() end
    SetWidgetCellsShown(targetBar, true)
  else
    if targetBar:IsShown() then targetBar:Hide() end
    SetWidgetCellsShown(targetBar, false)
  end
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
  lastCastName = tostring(name or "")
  RememberDuration(lastCastName, duration)

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
  TickTarget()
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

  -- Target bar: same cells as the player bar. Live data comes from
  -- TickTarget (UnitCastingInfo poll, then combat-log cache).
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

-- ---------------------------------------------------------------------------
-- The client's own casting bar
--
-- Under a native-chrome theme (core/theme.lua) the client's castbar is the
-- castbar: this module creates nothing, hides nothing and neuters none of the
-- CastingBarFrame_On* globals. All it adds is a mover, so the bar can be
-- placed like everything else.
--
-- Same shape as modules/petbar.lua, for the same reason: a QtUiPlus-owned
-- anchor frame carries the handle, follows the native bar until the player
-- actually drops it, and only then owns the anchor. An untouched interface
-- keeps the client's own position.
--
-- Anchors are read through U.GetFramePoint, which hands values back in the
-- shape SetPoint wants, so a capture goes straight back through SetPoint.
-- ---------------------------------------------------------------------------

local NATIVE_NAME = "CastingBarFrame"

-- Used until the native frame reports its own size, and as the footprint if it
-- never does. The floor height is a grab target, not a claim about the bar.
local NATIVE_FALLBACK_WIDTH = 195
local NATIVE_FALLBACK_HEIGHT = 13
local HANDLE_MIN_HEIGHT = 20

-- Anchor offsets below this are treated as unchanged rather than drift.
local DRIFT_EPSILON = 0.5

local nativeFrame
local nativeMoverAnchor
local capturedNativeAnchor
local nativeDriving = false

-- Counts SetPoint calls on the native frame that did not go through. A bar
-- sitting in the wrong place with a non-zero count here is a refused anchor,
-- not a client that re-anchored its own frame.
local driveFailures = 0

local function CaptureNativeAnchor()
  if not nativeFrame then return nil end

  local point, relative, relativePoint, x, y = U.GetFramePoint(nativeFrame, 1)
  if type(point) ~= "string" then
    U.Debug("castbar: no readable native anchor to capture")
    return nil
  end

  if not relative then
    local ok, parent = pcall(nativeFrame.GetParent, nativeFrame)
    if ok then relative = parent end
  end
  if not relative then relative = UIParent end

  return {
    point = point,
    relative = relative,
    relativePoint = relativePoint or point,
    x = x,
    y = y,
  }
end

local function RestoreNativeAnchor()
  if not nativeFrame or not capturedNativeAnchor then return false end

  local ok = pcall(function()
    nativeFrame:ClearAllPoints()
    nativeFrame:SetPoint(capturedNativeAnchor.point,
                         capturedNativeAnchor.relative,
                         capturedNativeAnchor.relativePoint,
                         capturedNativeAnchor.x, capturedNativeAnchor.y)
  end)

  if ok then
    nativeDriving = false
    U.Debug("castbar: native castbar anchor restored")
  end
  return ok
end

local function NativeStoredPosition()
  local ok, position = pcall(U.GetPosition, "castbar.player")
  if not ok or type(position) ~= "table" then return nil end
  if type(position.point) ~= "string" then return nil end
  return position
end

-- Written only when it actually changes: this runs on a shared tick and the
-- handle is SetAllPoints to this frame, so a size write is a handle relayout
-- for nothing.
local function MirrorNativeSize()
  if not nativeMoverAnchor or not nativeFrame then return end

  local okW, w = pcall(nativeFrame.GetWidth, nativeFrame)
  local okH, h = pcall(nativeFrame.GetHeight, nativeFrame)
  w = okW and tonumber(w) or nil
  h = okH and tonumber(h) or nil

  local width = (w and w > 0 and w) or NATIVE_FALLBACK_WIDTH
  local height = (h and h > 0 and h) or NATIVE_FALLBACK_HEIGHT
  if height < HANDLE_MIN_HEIGHT then height = HANDLE_MIN_HEIGHT end

  if nativeMoverAnchor.qtpWidth ~= width then
    nativeMoverAnchor:SetWidth(width)
    nativeMoverAnchor.qtpWidth = width
  end
  if nativeMoverAnchor.qtpHeight ~= height then
    nativeMoverAnchor:SetHeight(height)
    nativeMoverAnchor.qtpHeight = height
  end
end

local function AnchorDrifted(position)
  local point, relative, relativePoint, x, y =
    U.GetFramePoint(nativeMoverAnchor, 1)
  if type(point) ~= "string" then return true end
  if relative and relative ~= UIParent then return true end
  if point ~= position.point then return true end
  if relativePoint ~= (position.relativePoint or position.point) then return true end
  if math.abs(x - (tonumber(position.x) or 0)) > DRIFT_EPSILON then return true end
  if math.abs(y - (tonumber(position.y) or 0)) > DRIFT_EPSILON then return true end
  return false
end

-- Has the client re-anchored its own bar out from under us?
--
-- The point count is checked first, and deliberately. A frame keeps every
-- anchor set on it and is positioned by all of them at once, but GetPoint(1)
-- reports only the first -- so a second point added after DriveNative's
-- ClearAllPoints moves the bar while leaving point 1 still reading as ours.
-- Testing point 1 alone cannot see that, and reports no drift for a bar that
-- has visibly moved.
local function NativeDrifted()
  local okCount, count = pcall(nativeFrame.GetNumPoints, nativeFrame)
  if okCount and tonumber(count) and tonumber(count) ~= 1 then return true end

  local point, relative, relativePoint, x, y = U.GetFramePoint(nativeFrame, 1)
  if type(point) ~= "string" then return true end
  if relative ~= nativeMoverAnchor then return true end
  if point ~= "CENTER" or relativePoint ~= "CENTER" then return true end
  if math.abs(x) > DRIFT_EPSILON or math.abs(y) > DRIFT_EPSILON then return true end
  return false
end

-- Centre-on-centre needs neither frame to know how wide the other is, which is
-- what lets the handle carry a floor height without shifting the bar.
-- nativeDriving is set from the pcall result, not unconditionally: claiming the
-- drive succeeded when the SetPoint was refused would leave ApplyNativeAnchor
-- believing it owned an anchor it had never written.
local function DriveNative()
  local ok = pcall(function()
    nativeFrame:ClearAllPoints()
    nativeFrame:SetPoint("CENTER", nativeMoverAnchor, "CENTER", 0, 0)
  end)

  if ok then
    nativeDriving = true
  else
    driveFailures = driveFailures + 1
    if driveFailures == 1 then
      U.Debug("castbar: re-anchoring " .. NATIVE_NAME .. " was refused")
    end
  end
end

local function FollowNative()
  pcall(function()
    nativeMoverAnchor:ClearAllPoints()
    nativeMoverAnchor:SetPoint("CENTER", nativeFrame, "CENTER", 0, 0)
  end)
end

local function ApplyNativeAnchor()
  if U.PerfDisabled and U.PerfDisabled("castbar") then return end
  if not nativeMoverAnchor or not nativeFrame then return end

  MirrorNativeSize()

  local position = NativeStoredPosition()
  local unlocked = U.IsUnlocked()

  if not position then
    -- Never placed, or /qtp reset: hand the bar back to the client once, then
    -- keep the handle shadowing it. Not mid-drag -- re-anchoring the handle to
    -- the native bar then would snap it out of the player's hand.
    if nativeDriving then RestoreNativeAnchor() end
    if not unlocked then FollowNative() end
    return
  end

  -- The mover owns the anchor between StartMoving and StopMovingOrSizing, so
  -- the stored position is only re-applied while locked. The native bar is
  -- anchored *to* the anchor, so it tracks the handle live during a drag with
  -- no second write.
  if not unlocked and AnchorDrifted(position) then
    U.ApplyFramePoint(nativeMoverAnchor, position)
  end

  if NativeDrifted() then DriveNative() end
end

local function SetupNativeMover()
  nativeFrame = U.G(NATIVE_NAME)
  if not nativeFrame then
    U.Debug("castbar: " .. NATIVE_NAME .. " not found; no castbar mover")
    return
  end

  -- Before RegisterMover, which is what may apply a stored position.
  capturedNativeAnchor = CaptureNativeAnchor()

  -- Carries a mover handle and nothing else: no backdrop, no mouse, no strata
  -- of its own. It must never sit in front of the bar it is placing.
  nativeMoverAnchor = CreateFrame("Frame", "QtUiPlusCastBarAnchor", UIParent)
  nativeMoverAnchor:SetWidth(NATIVE_FALLBACK_WIDTH)
  nativeMoverAnchor:SetHeight(HANDLE_MIN_HEIGHT)
  MirrorNativeSize()
  FollowNative()
  -- Stays shown even though the bar it places does not: the native castbar
  -- only exists mid-cast, and a handle that only appeared mid-cast could not
  -- be dragged.
  nativeMoverAnchor:Show()

  -- Same id as the modern bar's mover, so a position placed under one theme is
  -- the position used under the other. No `default`: the client's own anchor
  -- need not be UIParent-relative and cannot be written as one, which is the
  -- case core/mover.lua documents U.OnPositionReset for.
  U.RegisterMover("castbar.player", nativeMoverAnchor, {
    label = "Cast bar",
  })
  U.OnPositionReset(function() return RestoreNativeAnchor() end)

  ApplyNativeAnchor()

  -- Accelerators, so a cast that starts right after the client re-anchors its
  -- bar is not drawn in the old place for up to one tick. The tick below is
  -- the guarantee; these only make it prompt.
  local refresh = function() ApplyNativeAnchor() end
  U.RegisterEvent("PLAYER_ENTERING_WORLD", refresh)
  U.RegisterEvent("SPELLCAST_START", refresh)
  U.RegisterEvent("SPELLCAST_CHANNEL_START", refresh)

  -- One anchor read twice a second against a frame that rarely moves. The
  -- modern bar's per-frame tick is not registered in this mode at all.
  U.RegisterUpdate("castbar.anchor", 0.5, ApplyNativeAnchor)
end

function CB:OnInit()
  sizeCfg = U.ModuleConfig("castbar", SIZE_DEFAULTS)
end

function CB:OnEnable()
  if bar then return end

  -- Before Build() and before SuppressNativeCastbar(): under a native-chrome
  -- theme the client's own castbar is the castbar, so this module creates
  -- nothing, hides nothing and neuters no CastingBarFrame global. It only
  -- registers the mover, and none of the cast events below -- the client is
  -- driving its own bar.
  if U.ThemeStyleUsesNativeChrome() then
    U.Debug("castbar: native chrome theme; leaving CastingBarFrame alone")
    SetupNativeMover()
    return
  end

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

  U.RegisterEvent("PLAYER_TARGET_CHANGED", function()
    TickTarget()
  end)

  local combatEvents = {
    "CHAT_MSG_SPELL_CREATURE_VS_CREATURE_BUFF",
    "CHAT_MSG_SPELL_CREATURE_VS_CREATURE_DAMAGE",
    "CHAT_MSG_SPELL_HOSTILEPLAYER_BUFF",
    "CHAT_MSG_SPELL_HOSTILEPLAYER_DAMAGE",
    "CHAT_MSG_SPELL_FRIENDLYPLAYER_BUFF",
    "CHAT_MSG_SPELL_FRIENDLYPLAYER_DAMAGE",
    "CHAT_MSG_SPELL_PERIODIC_CREATURE_BUFFS",
    "CHAT_MSG_SPELL_PARTY_BUFF",
    "CHAT_MSG_SPELL_SELF_DAMAGE",
    "CHAT_MSG_MONSTER_EMOTE",
    "CHAT_MSG_MONSTER_SAY",
  }
  local n
  for n = 1, table.getn(combatEvents) do
    U.RegisterEvent(combatEvents[n], OnCombatLog)
  end

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
  local tOk, tShown = false, nil
  if targetBar then tOk, tShown = pcall(targetBar.IsShown, targetBar) end
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
    targetShown = tOk and tShown or "?",
    targetSource = targetSource,
  }
end
