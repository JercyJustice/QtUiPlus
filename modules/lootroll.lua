-- QtUiPlus :: modules/lootroll.lua
--
-- The stock GroupLootFrame on this client is a tall window with its children
-- scattered across it. A roll opens over the corpse in the middle of the
-- screen, so the target nameplate (accent border, "Dead") draws inside it.
--
-- Compact card, opaque fill, FULLSCREEN_DIALOG: icon, name, Need/Greed/Pass,
-- timer along the bottom. Click/tooltip/RollOnLoot stay on the native buttons.
-- Placement is modules/windowmove.lua's lootroll.anchor mover.
--
-- Wiki: emberveil.org/wiki/lua/globals/Loot#getlootrolliteminfo
--       emberveil.org/wiki/lua/globals/Loot#rollonloot

local U = QtUiPlus
local M = U.media
local LR = U.RegisterModule("lootroll")

local FRAMES = { "GroupLootFrame1", "GroupLootFrame2",
                 "GroupLootFrame3", "GroupLootFrame4" }

local PAD = 6
local ICON = 32
local BTN = 24
local BTN_GAP = 4
local BAR_H = 4
local NAME_GAP = 8
local CARD_W = 300
local CARD_H = 48

local function NameOf(object)
  if not object or type(object.GetName) ~= "function" then return nil end
  local ok, value = pcall(object.GetName, object)
  if ok and type(value) == "string" then return value end
  return nil
end

local function ObjectTypeOf(object)
  if not object or type(object.GetObjectType) ~= "function" then return nil end
  local ok, value = pcall(object.GetObjectType, object)
  if ok then return value end
  return nil
end

local function RollItem(frame)
  if frame and frame.qtpSim then
    return frame.qtpSim.quality, frame.qtpSim.name
  end
  local rollID = frame and frame.rollID
  if not rollID then return nil, nil end
  local info = U.G("GetLootRollItemInfo")
  if type(info) ~= "function" then return nil, nil end
  local ok, _, itemName, _, quality = pcall(info, rollID)
  if not ok then return nil, nil end
  return tonumber(quality), itemName
end

local function NameWidth(buttonCount)
  local count = tonumber(buttonCount) or 3
  if count < 1 then count = 1 end
  local row = BTN * count + BTN_GAP * (count - 1)
  local width = CARD_W - PAD - ICON - NAME_GAP - row - NAME_GAP - PAD
  if width < 40 then width = 40 end
  return width
end

local function StyleIcon(name, quality)
  local icon = U.G(name .. "IconFrame")
  if not icon then return nil end
  U.StyleItemSlot(icon, name .. "IconFrame")
  pcall(icon.SetWidth, icon, ICON)
  pcall(icon.SetHeight, icon, ICON)

  local texture = U.G(name .. "IconFrameIconTexture") or U.G(name .. "IconFrameIcon")
  if texture then
    local edge = U.BorderSize()
    pcall(texture.SetTexCoord, texture, 0.08, 0.92, 0.08, 0.92)
    pcall(function()
      texture:ClearAllPoints()
      texture:SetPoint("TOPLEFT", icon, "TOPLEFT", edge, -edge)
      texture:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", -edge, edge)
    end)
  end
  pcall(function()
    icon:ClearAllPoints()
    icon:SetPoint("LEFT", U.G(name), "LEFT", PAD, 0)
  end)
  local color = quality and U.ItemQualityColor(quality)
  if color then
    U.SetBorderColor(icon, M.Unpack(color))
  else
    U.SetBorderColor(icon, M.Unpack(M.color.border))
  end
  icon.qtpKeep = true
  return icon
end

-- This client's Need button is $parentRollButton, not $parentNeedButton.
local BUTTON_ORDER = {
  RollButton  = 1,
  NeedButton  = 1,
  GreedButton = 2,
  PassButton  = 3,
}

local KEEP_SUFFIX = {
  IconFrame = true,
  Timer = true,
  RollButton = true,
  NeedButton = true,
  GreedButton = true,
  PassButton = true,
}

local function CollectButtons(name, frame)
  local list, seen = {}, {}
  local iconName = name .. "IconFrame"

  local function Take(button)
    if not button then return end
    local key = NameOf(button) or tostring(button)
    if key == iconName or seen[key] then return end
    seen[key] = true
    table.insert(list, button)
  end

  -- Named buttons only. Walking every Button child pulled the icon and the
  -- extra slot rows into the roll row on this client (U.G identity does not
  -- match GetChildren, so a name filter is the only reliable one).
  local known = { "RollButton", "NeedButton", "GreedButton", "PassButton" }
  local i
  for i = 1, table.getn(known) do
    Take(U.G(name .. known[i]))
  end

  if table.getn(list) == 0 and frame.GetChildren then
    local ok, children = pcall(function() return { frame:GetChildren() } end)
    if ok and type(children) == "table" then
      for i = 1, table.getn(children) do
        local child = children[i]
        local suffix = string.gsub(NameOf(child) or "", "^" .. name, "")
        if KEEP_SUFFIX[suffix] and suffix ~= "IconFrame" and suffix ~= "Timer" then
          Take(child)
        end
      end
    end
  end

  local order = {}
  for i = 1, table.getn(list) do
    local key = NameOf(list[i]) or ""
    local suffix = string.gsub(key, "^" .. name, "")
    local rank = BUTTON_ORDER[suffix] or (10 + i)
    local x
    if list[i].GetLeft then
      local okLeft, left = pcall(list[i].GetLeft, list[i])
      if okLeft then x = tonumber(left) end
    end
    order[list[i]] = rank * 100000 + (x or (i * 1000))
  end
  table.sort(list, function(a, b) return order[a] < order[b] end)
  return list
end

local function StyleButtons(name, frame)
  local list = CollectButtons(name, frame)
  local count = table.getn(list)
  local previous
  local i
  for i = count, 1, -1 do
    local button = list[i]
    pcall(button.SetWidth, button, BTN)
    pcall(button.SetHeight, button, BTN)
    local faces = { "GetNormalTexture", "GetPushedTexture",
                    "GetHighlightTexture", "GetDisabledTexture" }
    local f
    for f = 1, table.getn(faces) do
      local getter = button[faces[f]]
      if type(getter) == "function" then
        local okFace, texture = pcall(getter, button)
        if okFace and texture then
          pcall(function()
            texture:ClearAllPoints()
            texture:SetAllPoints(button)
          end)
        end
      end
    end
    U.CreateBackdrop(button, {
      background = M.color.backgroundRaised,
      border = M.color.border,
    })
    pcall(function()
      button:ClearAllPoints()
      if previous then
        button:SetPoint("RIGHT", previous, "LEFT", -BTN_GAP, 0)
      else
        button:SetPoint("RIGHT", frame, "RIGHT", -PAD, 0)
      end
    end)
    button.qtpKeep = true
    previous = button
  end
  return count
end

-- U.G(name.."Name") is not the FontString GetRegions() returns on this client
-- (same identity split as the roll buttons). HideDuplicateName then faded the
-- visible one. Scan regions first; fall back to the named global.
local function FindNameLabel(name, frame, itemName)
  local function Consider(object, preferMatch)
    if ObjectTypeOf(object) ~= "FontString" then return nil end
    if not preferMatch or type(itemName) ~= "string" then return object end
    local ok, text = pcall(object.GetText, object)
    if ok and text == itemName then return object end
    return nil
  end

  if frame and frame.GetRegions then
    local ok, regions = pcall(function() return { frame:GetRegions() } end)
    if ok and type(regions) == "table" then
      local match, fallback
      local i
      for i = 1, table.getn(regions) do
        local hit = Consider(regions[i], true)
        if hit then match = hit break end
        if not fallback then fallback = Consider(regions[i], false) end
      end
      if match then return match end
      if fallback then return fallback end
    end
  end
  return U.G(name .. "Name")
end

local function StyleName(name, frame, icon, buttonCount, quality, itemName)
  local label = FindNameLabel(name, frame, itemName)
  if not label then return nil end

  local color = (quality and U.ItemQualityColor(quality)) or M.color.text
  U.SetStockFont(label, M.fontSize.normal, color)
  if type(itemName) == "string" then
    pcall(label.SetText, label, itemName)
  end
  pcall(label.SetAlpha, label, 1)
  pcall(label.Show, label)

  pcall(function()
    label:ClearAllPoints()
    label:SetPoint("LEFT", icon or frame, icon and "RIGHT" or "LEFT",
                   icon and NAME_GAP or PAD, 0)
    label:SetWidth(NameWidth(buttonCount))
    label:SetHeight(M.fontSize.normal + 4)
  end)
  pcall(label.SetJustifyH, label, "LEFT")
  if label.SetJustifyV then pcall(label.SetJustifyV, label, "CENTER") end
  return label
end

-- Same identity split as the name: the StatusBar U.G(name.."Timer") sees is
-- not always the one still drawing. Collect every StatusBar child, style the
-- timer, mute the rest (a leftover bar is what sat under the stacked cards).
-- SetHeight(4) is ignored on this client (energytick.lua); pin a 4px strip
-- with two corners instead.
local function EachStatusBar(frame, callback)
  if not frame or not frame.GetChildren then return end
  local ok, children = pcall(function() return { frame:GetChildren() } end)
  if not ok or type(children) ~= "table" then return end
  local i
  for i = 1, table.getn(children) do
    if ObjectTypeOf(children[i]) == "StatusBar" then callback(children[i]) end
  end
end

local function StyleTimer(name, frame)
  local named = U.G(name .. "Timer")
  local timer = named
  EachStatusBar(frame, function(bar)
    local suffix = string.gsub(NameOf(bar) or "", "^" .. name, "")
    if suffix == "Timer" or not timer then timer = bar end
  end)
  if not timer then return end

  if timer.GetRegions then
    local ok, regions = pcall(function() return { timer:GetRegions() } end)
    if ok and type(regions) == "table" then
      local i
      for i = 1, table.getn(regions) do
        local region = regions[i]
        if region and region.GetTexture then
          local pathOk, path = pcall(region.GetTexture, region)
          if pathOk and type(path) == "string" and
             not string.find(string.lower(path), "white8x8", 1, true) then
            pcall(region.SetAlpha, region, 0)
          end
        end
      end
    end
  end
  pcall(timer.SetStatusBarTexture, timer, M.texture.plain)
  pcall(timer.SetStatusBarColor, timer, M.Unpack(M.color.accent))
  U.CreateBackdrop(timer, { background = M.color.healthBg, border = false })
  pcall(timer.SetBackdropBorderColor, timer, 0, 0, 0, 0)
  pcall(function()
    timer:ClearAllPoints()
    timer:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 1, 1)
    timer:SetPoint("TOPRIGHT", frame, "BOTTOMRIGHT", -1, 1 + BAR_H)
  end)
  pcall(timer.SetAlpha, timer, 1)
  pcall(timer.Show, timer)
  timer.qtpKeep = true

  EachStatusBar(frame, function(bar)
    if bar ~= timer and not bar.qtpKeep then
      pcall(bar.SetAlpha, bar, 0)
      pcall(bar.Hide, bar)
      if bar.EnableMouse then pcall(bar.EnableMouse, bar, false) end
    end
  end)
end

local function FadeMatchingLabels(owner, keep, text)
  if not owner or not owner.GetRegions or type(text) ~= "string" then return end
  local ok, regions = pcall(function() return { owner:GetRegions() } end)
  if not ok or type(regions) ~= "table" then return end
  local i
  for i = 1, table.getn(regions) do
    local region = regions[i]
    if region and region ~= keep and region.GetObjectType and region.GetText then
      if ObjectTypeOf(region) == "FontString" then
        local textOk, value = pcall(region.GetText, region)
        if textOk and value == text and region.SetAlpha then
          pcall(region.SetAlpha, region, 0)
        end
      end
    end
  end
end

local function HideDuplicateName(frame, keep, text)
  FadeMatchingLabels(frame, keep, text)
  if not frame.GetChildren then return end
  local ok, children = pcall(function() return { frame:GetChildren() } end)
  if not ok or type(children) ~= "table" then return end
  local i
  for i = 1, table.getn(children) do
    FadeMatchingLabels(children[i], keep, text)
  end
end

local function KeepChild(parentName, child)
  if child and child.qtpKeep then return true end
  local objectType = ObjectTypeOf(child)
  if objectType == "Model" or objectType == "PlayerModel" or
     objectType == "DressUpModel" then
    return false
  end

  local childName = NameOf(child)
  if not childName then return false end
  if string.find(string.lower(childName), "close", 1, true) then return false end

  local suffix = string.gsub(childName, "^" .. parentName, "")
  return KEEP_SUFFIX[suffix] and true or false
end

-- Extra children (portrait, close, empty slot rows) stay at their stock
-- offsets after the card is shortened and would still draw outside it:
-- this client does not clip children to the parent.
local function MuteExtras(name, frame)
  if not frame.GetChildren then return end
  local ok, children = pcall(function() return { frame:GetChildren() } end)
  if not ok or type(children) ~= "table" then return end
  local i
  for i = 1, table.getn(children) do
    local child = children[i]
    if child and not KeepChild(name, child) then
      pcall(child.SetAlpha, child, 0)
      if child.EnableMouse then pcall(child.EnableMouse, child, false) end
    end
  end
end

local EnsureGuard

local function FrameIndex(name)
  local index = tonumber(string.sub(name or "", -1))
  if index and index >= 1 and index <= table.getn(FRAMES) then return index end
  return 1
end

-- One point only. Opening LootFrame on this client SetAllPoints the roll
-- window (or adds BOTTOMRIGHT), so SetWidth/SetHeight alone cannot shrink it.
local function Reanchor(frame, index)
  if not frame then return end
  pcall(function()
    frame:ClearAllPoints()
    if index > 1 then
      local previous = U.G(FRAMES[index - 1])
      if previous then
        frame:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -6)
        return
      end
    end
    local host = U.G("QtUiPlusLootRollAnchor")
    if host then
      frame:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
    else
      frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 24, -160)
    end
  end)
end

local function Skin(name)
  local frame = U.G(name)
  if not frame then return end

  U.StripStockTextures(frame)
  Reanchor(frame, FrameIndex(name))
  pcall(frame.SetWidth, frame, CARD_W)
  pcall(frame.SetHeight, frame, CARD_H)
  U.CreateBackdrop(frame, {
    background = { 0.05, 0.05, 0.05, 0.96 },
    border = M.color.border,
  })
  -- DIALOG is not enough: the target nameplate still draws over it. Tooltips
  -- stay above FULLSCREEN_DIALOG.
  U.RaiseGamePanel(frame, "FULLSCREEN_DIALOG")

  local quality, itemName = RollItem(frame)
  local icon = StyleIcon(name, quality)
  local buttonCount = StyleButtons(name, frame)
  local nameLabel = StyleName(name, frame, icon, buttonCount, quality, itemName)
  StyleTimer(name, frame)
  HideDuplicateName(frame, nameLabel, itemName)
  if nameLabel then
    pcall(nameLabel.SetAlpha, nameLabel, 1)
    pcall(nameLabel.Show, nameLabel)
  end
  MuteExtras(name, frame)
  EnsureGuard()
end

local function FrameIsShown(frame)
  if not frame or not frame.IsShown then return false end
  local ok, shown = pcall(frame.IsShown, frame)
  return ok and shown and true or false
end

local function SizeDrifted(frame)
  if not frame then return false end
  local okW, width = pcall(frame.GetWidth, frame)
  local okH, height = pcall(frame.GetHeight, frame)
  width = (okW and tonumber(width)) or 0
  height = (okH and tonumber(height)) or 0
  if height > CARD_H + 2 or width > CARD_W + 2 then return true end
  if height < CARD_H - 2 or width < CARD_W - 2 then return true end
  return false
end

local function ReskinShown()
  local i
  for i = 1, table.getn(FRAMES) do
    if FrameIsShown(U.G(FRAMES[i])) then Skin(FRAMES[i]) end
  end
end

local function GuardTick()
  local any = false
  local i
  for i = 1, table.getn(FRAMES) do
    local frame = U.G(FRAMES[i])
    if FrameIsShown(frame) then
      any = true
      if SizeDrifted(frame) then Skin(FRAMES[i]) end
    end
  end
  if not any then U.UnregisterUpdate("lootroll.guard") end
end

EnsureGuard = function()
  U.RegisterUpdate("lootroll.guard", 0.1, GuardTick)
end

local lootFrameHooked = false

local function HookLootFrame()
  if lootFrameHooked then return end
  local loot = U.G("LootFrame")
  if not loot then return end
  if U.PostHookScript(loot, "OnShow", ReskinShown) then
    lootFrameHooked = true
  end
end

local function Attach()
  local attached = false
  local i
  for i = 1, table.getn(FRAMES) do
    local name = FRAMES[i]
    local frame = U.G(name)
    if frame then
      attached = true
      if not frame.qtpLootRollHooked then
        if U.PostHookScript(frame, "OnShow", function() Skin(name) end) then
          frame.qtpLootRollHooked = true
        end
      end
      if FrameIsShown(frame) then Skin(name) end
    end
  end
  HookLootFrame()
  return attached
end

-- /qtp rolltest -- show GroupLootFrame1..N with fake item art and a local
-- timer. GetLootRollItemInfo returns no name for an unknown rollID, and the
-- stock OnShow hides the frame in that case, so this fills the widgets after
-- Show and does not call RollOnLoot (wiki: unknown RollID is a no-op, but a
-- test must not send a vote). Need/Greed/Pass dismiss the sim.
local SIM_DURATION = 20
local SIM_ICON = "Interface\\Icons\\INV_Ore_Tin_01"
local SIM_NAME = "Silver Ore"
local SIM_QUALITY = 2
local simRunning = false

local function SimTick()
  if not simRunning then
    U.UnregisterUpdate("lootroll.sim")
    return
  end
  local any = false
  local i
  for i = 1, table.getn(FRAMES) do
    local frame = U.G(FRAMES[i])
    local sim = frame and frame.qtpSim
    if sim then
      sim.left = (tonumber(sim.left) or 0) - 0.05
      local bar = U.G(FRAMES[i] .. "Timer")
      if bar and bar.SetValue then pcall(bar.SetValue, bar, math.max(sim.left, 0)) end
      if sim.left <= 0 then
        frame.qtpSim = nil
        pcall(frame.Hide, frame)
      else
        any = true
      end
    end
  end
  if not any then
    simRunning = false
    U.UnregisterUpdate("lootroll.sim")
  end
end

local function HookSimDismiss(button, frame)
  if not button or button.qtpSimClick then return end
  if U.PostHookScript(button, "OnClick", function()
       if frame and frame.qtpSim then U.StopLootRollSim() end
     end) then
    button.qtpSimClick = true
  end
end

local function FillSimArt(name, frame, sim)
  local label = U.G(name .. "Name")
  if label then
    pcall(label.SetText, label, sim.name)
    pcall(label.SetAlpha, label, 1)
    pcall(label.Show, label)
  end

  pcall(SetItemButtonTexture, U.G(name .. "IconFrame"), sim.icon)
  local tex = U.G(name .. "IconFrameIconTexture") or U.G(name .. "IconFrameIcon")
  if tex then
    pcall(tex.SetTexture, tex, sim.icon)
    pcall(tex.Show, tex)
    pcall(tex.SetAlpha, tex, 1)
  end
  local icon = U.G(name .. "IconFrame")
  if icon then pcall(icon.Show, icon) end

  local bar = U.G(name .. "Timer")
  if bar then
    pcall(bar.SetMinMaxValues, bar, 0, sim.duration)
    pcall(bar.SetValue, bar, sim.left)
    pcall(bar.Show, bar)
  end

  local known = { "RollButton", "NeedButton", "GreedButton", "PassButton" }
  local i
  for i = 1, table.getn(known) do
    local button = U.G(name .. known[i])
    if button then
      pcall(button.Show, button)
      HookSimDismiss(button, frame)
    end
  end
end

function U.StopLootRollSim()
  simRunning = false
  U.UnregisterUpdate("lootroll.sim")
  local i
  for i = 1, table.getn(FRAMES) do
    local frame = U.G(FRAMES[i])
    if frame and frame.qtpSim then
      frame.qtpSim = nil
      pcall(frame.Hide, frame)
    end
  end
end

function U.SimulateLootRoll(count)
  count = tonumber(count) or 1
  if count < 1 then count = 1 end
  if count > table.getn(FRAMES) then count = table.getn(FRAMES) end

  Attach()
  U.StopLootRollSim()

  local shown = 0
  local i
  for i = 1, count do
    local name = FRAMES[i]
    local frame = U.G(name)
    if not frame then
      U.Print("rolltest: " .. name .. " is not on this client")
    else
      frame.qtpSim = {
        name = SIM_NAME,
        quality = SIM_QUALITY,
        icon = SIM_ICON,
        duration = SIM_DURATION,
        left = SIM_DURATION,
      }
      -- Native OnShow hides the frame when GetLootRollItemInfo has no name
      -- (wiki: unknown RollID returns nil, nil, 1, 1, nil). Show, then show
      -- again if that ran, then paint over the empty widgets.
      pcall(frame.Show, frame)
      local ok, isShown = pcall(frame.IsShown, frame)
      if not ok or not isShown then pcall(frame.Show, frame) end
      FillSimArt(name, frame, frame.qtpSim)
      Skin(name)
      FillSimArt(name, frame, frame.qtpSim)
      shown = shown + 1
    end
  end

  if shown == 0 then return end
  simRunning = true
  U.RegisterUpdate("lootroll.sim", 0.05, SimTick)
  U.Print("rolltest: showing " .. shown .. " simulated roll" ..
          (shown == 1 and "" or "s") .. " for " .. SIM_DURATION ..
          "s - /qtp rolltest off to close")
end

function LR:OnEnable()
  Attach()
  U.RegisterEvent("ADDON_LOADED", Attach)
  U.RegisterEvent("PLAYER_ENTERING_WORLD", Attach)
  -- START_LOOT_ROLL / LOOT_OPENED do not re-fire OnShow on an already visible
  -- card. Opening the corpse window is what stretches it back to stock size.
  U.RegisterEvent("START_LOOT_ROLL", function()
    Attach()
    ReskinShown()
  end)
  U.RegisterEvent("LOOT_OPENED", ReskinShown)
  U.RegisterEvent("LOOT_SLOT_CLEARED", ReskinShown)
end
