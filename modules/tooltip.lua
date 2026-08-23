-- QtUiPlus :: modules/tooltip.lua
--
-- Flat pfUI-modern GameTooltip. The stock beveled frame is replaced with the
-- addon's flat panel look (WHITE8X8 fill, one thin dark outline), and the
-- native status bar is pulled flush against the body with a centered health
-- readout drawn on it.
--
-- For a hovered player the text is rebuilt as:
--   Raykou                          -- white
--   <Guild> [Rank]                  -- guild green + dim grey rank
--   60 Night Elf Ranger             -- class colour
--   [====== 5.4K / 5.4K ======]     -- bar tinted with the class colour
--
-- The flat frame styling is applied to GameTooltip itself, so item and action
-- tooltips inherit the same flat look. Only the *text* rebuild is gated on a
-- player mouseover; item and action tooltip contents are never touched.
--
-- behavior.json / tooltip.native_read/regions/hide/backdrop/statusbar/child.v1
-- (all SUPPORTED, BEHAVIOR_VERIFIED) confirm the calls used here: GameTooltip
-- accepts SetBackdrop while populated, its texture regions hide without fault,
-- GameTooltipStatusBar is a real StatusBar with its own SetStatusBarTexture /
-- SetStatusBarColor, and a plain Frame parented to it accepts a fontstring.
--
-- Two details the probe settled that shape this module:
--   * GameTooltipStatusBar's GetValue/GetMinMaxValues always report a fixed
--     0-100 range regardless of the unit's real pool, so the health text is
--     built from UnitHealth/UnitHealthMax, never from the bar's own value.
--   * The bar is natively anchored below the body at (2, 1) with a 2px side
--     inset, which is the gap being removed here. Re-anchoring it is the one
--     call the probe did not cover; it matches UnrealPfUI's working tooltip
--     module (WORKING_SOURCE), not measured runtime evidence.

local U = QtUiPlus
local M = U.media
local TT = U.RegisterModule("tooltip")

-- Target palette, kept together so a colour can be corrected in one place.
local COLOR = {
  name   = { 1.00, 1.00, 1.00 },
  guild  = { 0.30, 1.00, 0.50 },
  rank   = { 0.70, 0.70, 0.70 },
  health = { 1.00, 1.00, 1.00 },
}

local BAR_HEIGHT = 12

local apiCache = {}

local function Api(name)
  local cached = apiCache[name]
  if cached ~= nil then return cached or nil end

  local fn = U.G(name)
  apiCache[name] = type(fn) == "function" and fn or false
  return apiCache[name] or nil
end

local function Call(name, ...)
  local fn = Api(name)
  if not fn then return nil end

  local ok, a, b, c = pcall(fn, ...)
  if not ok then return nil end
  return a, b, c
end

local function IsTruthy(value)
  return value ~= nil and value ~= false and value ~= 0 and value ~= ""
end

-- Inline colour escape, for the one line that carries two colours at once.
local function Hex(color)
  return string.format("|cff%02x%02x%02x",
    math.floor(color[1] * 255), math.floor(color[2] * 255), math.floor(color[3] * 255))
end

-- Matches the target's "5.4K / 5.4K" reading rather than a raw number.
local function Abbreviate(value)
  value = tonumber(value) or 0
  if value >= 1000000 then
    return string.format("%.1fM", value / 1000000)
  elseif value >= 1000 then
    return string.format("%.1fK", value / 1000)
  end
  return tostring(value)
end

local function LineText(index)
  local label = U.G("GameTooltipTextLeft" .. index)
  if not label or not label.GetText then return nil, nil end
  local ok, text = pcall(label.GetText, label)
  if not ok or type(text) ~= "string" then return label, nil end
  return label, text
end

-- ---------------------------------------------------------------------------
-- Flat frame styling
--
-- The stock edge art comes back after the tooltip is populated, so this is
-- re-applied every time the tooltip is shown or repopulated, not once at
-- enable -- a recorded failed approach was styling only during addon enable,
-- which left the stock border visible as soon as content arrived. See "Style
-- triggers" at the foot of this file for why that reapply is event-driven
-- rather than driven off the update ticker.
--
-- SetBackdrop with a table carrying no edgeFile does NOT drop the stock edge on
-- this client: the fill changes to the requested flat colour while the tan
-- UI-Tooltip-Border art keeps drawing. Confirmed in game -- the body went flat
-- dark and the ornate border survived, on both GameTooltip and its status bar.
-- The edge is therefore removed by driving its colour to zero alpha, which
-- tooltip.native_backdrop.v1 verified as a working call, rather than by trying
-- to clear the backdrop out from under a native frame.
-- ---------------------------------------------------------------------------
local healthLabel

local function ClearNativeEdge(frame)
  if not frame or not frame.SetBackdropBorderColor then return end
  pcall(frame.SetBackdropBorderColor, frame, 0, 0, 0, 0)
end

local function StyleStatusBar()
  local bar = U.G("GameTooltipStatusBar")
  if not bar then return nil end

  -- Flush against the body: no side inset, no vertical offset. The native
  -- anchors are TOPLEFT/TOPRIGHT -> GameTooltip BOTTOMLEFT/BOTTOMRIGHT at
  -- (2, 1) and (-2, 1), which is exactly the margin being removed.
  local tooltip = U.G("GameTooltip")
  if tooltip then
    pcall(bar.ClearAllPoints, bar)
    pcall(bar.SetPoint, bar, "TOPLEFT", tooltip, "BOTTOMLEFT", 0, 0)
    pcall(bar.SetPoint, bar, "TOPRIGHT", tooltip, "BOTTOMRIGHT", 0, 0)
  end
  pcall(bar.SetHeight, bar, BAR_HEIGHT)
  pcall(bar.SetStatusBarTexture, bar, M.texture.plain)

  -- Flat fill behind the bar so a partially depleted pool reads as dark rather
  -- than transparent, plus the same thin outline the body carries. The bar
  -- carries its own stock edge, and two adjacent tan edges are most of what
  -- read as a gap between the body and the bar.
  U.CreateBackdrop(bar, { background = M.color.healthBg, border = M.color.border })
  ClearNativeEdge(bar)

  if not healthLabel and bar.CreateFontString then
    local holderOk, holder = pcall(CreateFrame, "Frame", nil, bar)
    if holderOk and holder then
      pcall(holder.SetAllPoints, holder, bar)
      local levelOk, level = pcall(bar.GetFrameLevel, bar)
      pcall(holder.SetFrameLevel, holder,
            (levelOk and type(level) == "number" and level or 0) + 1)

      healthLabel = U.CreateLabel(holder, {
        size = M.fontSize.small,
        color = COLOR.health,
        inherits = "GameFontNormalSmall",
      })
      if healthLabel then
        pcall(healthLabel.SetPoint, healthLabel, "CENTER", holder, "CENTER", 0, 0)
      end
    end
  end

  return bar
end

-- Flat fill + hide stock corner textures. Shared by GameTooltip and the
-- shopping compare frames (wiki: ShoppingTooltip1/2 are the same type).
local function StyleTooltipFrame(tooltip, name)
  if not tooltip then return end
  U.CreateBackdrop(tooltip, {
    background = M.color.background,
    border = M.color.border,
  })
  ClearNativeEdge(tooltip)
  if type(name) ~= "string" then return end
  local i
  for i = 1, 3 do
    U.HideRegion(U.G(name .. "Texture" .. i))
  end
end

local function StyleFrame()
  local tooltip = U.G("GameTooltip")
  if not tooltip then return end

  -- Fill only, no edgeFile: the stock bevel lives on the backdrop's edge, and
  -- rendering.backdrop_edge_fractional_not_rasterized means QtUiPlus draws its
  -- own outline from plain textures instead (core/style.lua).
  StyleTooltipFrame(tooltip, "GameTooltip")
  StyleStatusBar()
end

-- ---------------------------------------------------------------------------
-- Player text rebuild
-- ---------------------------------------------------------------------------

-- Vanilla puts the guild on line 2 and pushes the level/race/class line down to
-- 3 for a guilded player, so neither index is fixed. Locate both by content
-- instead of assuming a position this client was never measured to use.
local function RewriteLines(guildName, rankName, localizedRace, localizedClass, r, g, b)
  local numLines = 4
  local countOk, count = pcall(function() return U.G("GameTooltip"):NumLines() end)
  if countOk and type(count) == "number" and count > 0 then numLines = count end

  local i
  for i = 2, numLines do
    local label, text = LineText(i)
    if label and text and text ~= "" then
      if guildName and guildName ~= "" and
         string.find(text, guildName, 1, true) then
        local line = Hex(COLOR.guild) .. "<" .. guildName .. ">|r"
        if type(rankName) == "string" and rankName ~= "" then
          line = line .. " " .. Hex(COLOR.rank) .. "[" .. rankName .. "]|r"
        end
        pcall(label.SetText, label, line)

      elseif (localizedRace and localizedRace ~= "" and
              string.find(text, localizedRace, 1, true)) or
             string.find(text, "(Player)", 1, true) or
             string.find(text, "Level", 1, true) then
        local level = Call("UnitLevel", "mouseover")
        local levelText = (type(level) == "number" and level > 0)
          and tostring(level) or "??"

        local parts = { levelText }
        if localizedRace and localizedRace ~= "" then
          table.insert(parts, localizedRace)
        end
        table.insert(parts, localizedClass)

        pcall(label.SetText, label, table.concat(parts, " "))
        pcall(label.SetTextColor, label, r, g, b)
      end
    end
  end
end

-- Placement is left entirely to the client. A mover was attempted and reverted:
-- repositioning GameTooltip needs ClearAllPoints/SetPoint on a native frame,
-- which no probe on this client covers -- it rests only on UnrealPfUI doing the
-- same thing. The tooltip keeps its native anchor (measured at BOTTOMRIGHT of
-- UIParent, -103, -97 by tooltip.native_read.v1) until that call is verified.

local styledFor

-- `force` restyles regardless of the cached subject. The show/resize hooks
-- below pass it so a freshly populated tooltip is flattened in the same frame
-- it appears, instead of waiting for the next poll.
local function RefreshTooltip(force)
  -- /qtp perf tooltip. Every styling path in this module funnels through here,
  -- including the OnShow/OnSizeChanged hooks, so one guard silences the whole
  -- subsystem -- and specifically silences the Restyle -> StyleFrame ->
  -- OnSizeChanged -> Restyle path, which has no re-entrancy guard of its own.
  if U.PerfDisabled and U.PerfDisabled("tooltip") then return end

  local tooltip = U.G("GameTooltip")
  if not tooltip or not tooltip.IsShown then return end

  local shownOk, shown = pcall(tooltip.IsShown, tooltip)
  if not shownOk or not shown then
    styledFor = nil
    return
  end

  local nameLabel, tooltipName = LineText(1)

  -- Re-flatten when the tooltip appears and whenever its subject changes, but
  -- not on every tick: the stock art comes back with new content, and moving
  -- between two units can repopulate without the frame ever hiding. An
  -- unreadable first line falls back to a constant so a tooltip with no name
  -- cannot re-trigger the styling pass on every tick.
  local subject = tooltipName or "?"
  if force or styledFor ~= subject then
    StyleFrame()
    styledFor = subject
  else
    -- The native edge art comes back on its own whenever the tooltip
    -- repopulates, even without its subject changing (e.g. a hovered unit's
    -- tooltip refreshing in place). Re-suppressing it every tick is cheap
    -- and idempotent; skipping it here is what caused the native border to
    -- flash back in between subject changes.
    ClearNativeEdge(tooltip)
    ClearNativeEdge(U.G("GameTooltipStatusBar"))
  end

  local tipCfg = U.ModuleConfig("tooltip", { classColor = true })
  -- Same health-text format as the unit frames (Unit Frames → Health text).
  if healthLabel and IsTruthy(Call("UnitExists", "mouseover")) then
    local text
    if type(U.FormatHealthText) == "function" then
      text = U.FormatHealthText("mouseover")
    end
    if not text then
      if type(QtP) == "table" and type(QtP.FormatMobHealth) == "function" then
        text = QtP.FormatMobHealth("mouseover")
      end
    end
    if not text then
      local hp = Call("UnitHealth", "mouseover")
      local hpMax = Call("UnitHealthMax", "mouseover")
      if type(hp) == "number" and type(hpMax) == "number" and hpMax > 0 then
        text = Abbreviate(hp) .. " / " .. Abbreviate(hpMax)
      end
    end
    if text then pcall(healthLabel.SetText, healthLabel, text) end
  end

  if tipCfg.classColor == false then return end

  if not IsTruthy(Call("UnitIsPlayer", "mouseover")) then return end

  local unitName = Call("UnitName", "mouseover")
  if type(unitName) ~= "string" then return end

  -- Confirm this visible tooltip belongs to the current mouseover before
  -- rewriting any text, so item and action tooltips are never rewritten.
  if not nameLabel or type(tooltipName) ~= "string" then return end
  if tooltipName ~= unitName and
     not string.find(tooltipName, unitName, 1, true) then
    return
  end

  local localizedClass, classToken = Call("UnitClass", "mouseover")
  if type(localizedClass) ~= "string" or type(classToken) ~= "string" then return end

  local r, g, b = M.ClassColor(classToken)
  r = r or 1; g = g or 1; b = b or 1

  pcall(nameLabel.SetTextColor, nameLabel, COLOR.name[1], COLOR.name[2], COLOR.name[3])

  local guildName, rankName = Call("GetGuildInfo", "mouseover")
  local localizedRace = Call("UnitRace", "mouseover")
  RewriteLines(guildName, rankName, localizedRace, localizedClass, r, g, b)

  local bar = U.G("GameTooltipStatusBar")
  if bar and bar.SetStatusBarColor then
    pcall(bar.SetStatusBarColor, bar, r, g, b)
  end
end

-- ---------------------------------------------------------------------------
-- Style triggers
--
-- Polling alone cannot remove the flash. The native frame draws its stock
-- backdrop the moment the tooltip is shown or repopulated, so a 0.10s ticker
-- leaves the tan border on screen for up to a full tick before suppressing it.
-- That is exactly the blink seen when hovering character-sheet items, where
-- SetOwner/SetInventoryItem/Show populate and reveal the frame in one go.
--
-- The styling is therefore driven from the tooltip's own show and resize:
--
--   * A Frame parented to GameTooltip with SetAllPoints. A child's OnShow
--     fires with its parent, so this catches the tooltip appearing. UnrealPfUI
--     drives its whole tooltip module from this same child-frame OnShow on
--     this client (WORKING_SOURCE, modules/tooltip.lua), not runtime-verified
--     here.
--   * The same child's OnSizeChanged, which fires when the tooltip grows to
--     fit new content. This is what catches an already-visible tooltip being
--     repopulated in place -- moving between two item slots never hides the
--     frame, so OnShow alone would miss it. No probe covers OnSizeChanged on
--     a SetAllPoints child of a native frame.
--   * GameTooltip's own OnShow through U.PostHookScript, which appends to the
--     native handler rather than replacing it, as a second same-frame trigger
--     in case the child frame's scripts do not fire.
--
-- The ticker stays as the backstop and as the driver for the live health
-- readout, but it is no longer what makes the tooltip flat.
-- ---------------------------------------------------------------------------

local hookFrame

local function Restyle()
  RefreshTooltip(true)
end

local function InstallTriggers()
  local tooltip = U.G("GameTooltip")
  if not tooltip then return false end

  local installed = false

  if not hookFrame then
    local ok, frame = pcall(CreateFrame, "Frame", nil, tooltip)
    if ok and frame then
      pcall(frame.SetAllPoints, frame, tooltip)
      if pcall(frame.SetScript, frame, "OnShow", Restyle) then
        installed = true
      end
      pcall(frame.SetScript, frame, "OnSizeChanged", Restyle)
      hookFrame = frame
    end
  end

  if U.PostHookScript(tooltip, "OnShow", Restyle) then
    installed = true
  end

  return installed
end

-- ---------------------------------------------------------------------------
-- Tooltip anchor
--
-- Two kinds of tooltip:
--
--   * World / unit tooltips that go through GameTooltip_SetDefaultAnchor with
--     UIParent or WorldFrame sit on the dummy mover (the "Tooltip" handle in
--     Anchor Mode).
--   * Item tooltips (quest log rewards, bags, paperdoll, loot, vendor, mail,
--     auction, trade, craft) follow the cursor. Wiki SetOwner ANCHOR_CURSOR:
--     "Clears points and follows the cursor (plus offsets)."
--     https://emberveil.org/wiki/lua/widgets/GameTooltip#setowner
--
-- SetOwner always clears lines, so cursor ownership is applied in
-- SetDefaultAnchor (before the fill) and again at the start of each item
-- Set* method, never after the tooltip is populated. Action-bar, aura, and
-- unit-frame tooltips keep the SetOwner their own modules already chose
-- (ANCHOR_RIGHT etc.); those setters are not in the item list below.
--
-- PlaceAtAnchor uses ClearAllPoints/SetPoint, which cancels engine cursor
-- tracking. OnShow must not re-pin a tooltip whose GetAnchorType is
-- ANCHOR_CURSOR (wiki GetAnchorType).
-- ---------------------------------------------------------------------------
local ANCHOR_W, ANCHOR_H = 180, 72
local tooltipAnchor

-- Item fills that should follow the mouse. Compare setters
-- (SetMerchantCompareItem / SetAuctionCompareItem) stay on ShoppingTooltip
-- and are not listed. Spellbook / action / talent / aura fills stay on the
-- button that owned them.
local CURSOR_SETTERS = {
  "SetAuctionItem",
  "SetAuctionSellItem",
  "SetBagItem",
  "SetBuybackItem",
  "SetCraftItem",
  "SetHyperlink",
  "SetInboxItem",
  "SetInventoryItem",
  "SetLootItem",
  "SetLootRollItem",
  "SetMerchantItem",
  "SetQuestItem",
  "SetQuestLogItem",
  "SetQuestLogRewardSpell",
  "SetQuestRewardSpell",
  "SetSendMailItem",
  "SetTradePlayerItem",
  "SetTradeSkillItem",
  "SetTradeTargetItem",
}

local function PlaceAtAnchor(tooltip)
  if not tooltip or not tooltipAnchor then return end
  pcall(function()
    tooltip:ClearAllPoints()
    tooltip:SetPoint("BOTTOMRIGHT", tooltipAnchor, "BOTTOMRIGHT", 0, 0)
  end)
end

local function AnchorType(tooltip)
  if not tooltip or not tooltip.GetAnchorType then return nil end
  local ok, value = pcall(tooltip.GetAnchorType, tooltip)
  if ok and type(value) == "string" then return value end
  return nil
end

local function TooltipOwner(tooltip)
  if not tooltip or not tooltip.GetOwner then return nil end
  local ok, owner = pcall(tooltip.GetOwner, tooltip)
  if ok then return owner end
  return nil
end

local function IsCornerTooltip(tooltip)
  local owner = TooltipOwner(tooltip)
  if not owner then return true end
  return owner == UIParent or owner == U.G("WorldFrame")
end

-- Wiki: SetOwner clears lines and stores the anchor. Safe only before a fill.
-- Do not fall back to UIParent: that would steal a button owner (paperdoll
-- Character*Slot) and then eqcompare cannot see IsOwned(slot).
local function FollowCursor(tooltip, owner)
  if not tooltip or not tooltip.SetOwner then return end
  local kind = AnchorType(tooltip)
  if kind == "ANCHOR_CURSOR" or kind == "ANCHOR_PRESERVE" then return end
  owner = owner or TooltipOwner(tooltip)
  if not owner then return end
  pcall(tooltip.SetOwner, tooltip, owner, "ANCHOR_CURSOR")
end

local function HookCursorSetters(tooltip)
  if not tooltip then return end
  local i
  for i = 1, table.getn(CURSOR_SETTERS) do
    local name = CURSOR_SETTERS[i]
    local original = tooltip[name]
    if original ~= nil then
      tooltip[name] = function(self, a, b, c, d)
        FollowCursor(self)
        local ok, r1, r2, r3 = pcall(original, self, a, b, c, d)
        if ok then return r1, r2, r3 end
      end
    end
  end
end

local function BuildTooltipAnchor()
  if tooltipAnchor then return tooltipAnchor end

  local frame = CreateFrame("Frame", "QtUiPlusTooltipAnchor", UIParent)
  frame:SetWidth(ANCHOR_W)
  frame:SetHeight(ANCHOR_H)
  -- Invisible while locked: no mouse, no art. The mover handle is the only
  -- thing that paints it in edit mode.
  pcall(frame.EnableMouse, frame, false)

  if type(U.RegisterMover) == "function" then
    U.RegisterMover("tooltip.anchor", frame, {
      label = "Tooltip",
      default = {
        point = "BOTTOMRIGHT",
        relativePoint = "BOTTOMRIGHT",
        x = -16,
        y = 16,
      },
    })
  end

  tooltipAnchor = frame
  return frame
end

function TT.OnEnable()
  -- Style once up front so the very first tooltip is already flat rather than
  -- relying on a trigger that has not fired yet.
  StyleFrame()

  if not InstallTriggers() then
    U.Debug("tooltip: no show hook installed, styling is poll-driven only")
  end

  BuildTooltipAnchor()

  local tooltip = U.G("GameTooltip")
  HookCursorSetters(tooltip)

  -- Vanilla world-unit tooltips go through this global with UIParent or
  -- WorldFrame. Item buttons pass themselves as parent; those follow the
  -- cursor instead of the dummy. Wiki SetOwner / GetAnchorType as above.
  if type(U.PostHookGlobal) == "function" then
    U.PostHookGlobal("GameTooltip_SetDefaultAnchor", function(tip, parent)
      if not tip then return end
      if parent and parent ~= UIParent and parent ~= U.G("WorldFrame") then
        FollowCursor(tip, parent)
        return
      end
      PlaceAtAnchor(tip)
    end)
  end

  if tooltip then
    U.PostHookScript(tooltip, "OnShow", function()
      local kind = AnchorType(tooltip)
      if kind == "ANCHOR_CURSOR" or kind == "ANCHOR_PRESERVE" then return end
      if IsCornerTooltip(tooltip) then PlaceAtAnchor(tooltip) end
    end)
  end

  -- Compare / item-ref frames are the same GameTooltip type (wiki) but keep
  -- the stock bevel unless flattened here. Legitimate eqcompare windows then
  -- match the item tooltip instead of looking like a second native tooltip.
  local extra = { "ShoppingTooltip1", "ShoppingTooltip2", "ItemRefTooltip" }
  local e
  for e = 1, table.getn(extra) do
    local name = extra[e]
    local frame = U.G(name)
    if frame then
      U.PostHookScript(frame, "OnShow", function()
        StyleTooltipFrame(frame, name)
      end)
    end
  end

  U.RegisterUpdate("tooltip.player-style", 0.10, function()
    RefreshTooltip(false)
  end)
end
