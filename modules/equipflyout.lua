-- QtUiPlus :: modules/equipflyout.lua
--
-- Hold Alt over a paperdoll slot to list bag items that fit that slot.
-- Stock pfUI does not implement this (it only skins BetterCharacterStats
-- dropdowns); the APIs to do it here are documented:
--   IsAltKeyDown     https://emberveil.org/wiki/lua/globals/System#isaltkeydown
--   GetItemInfo      https://emberveil.org/wiki/lua/globals/Item#getiteminfo
--                    (8th return is INVTYPE_* equipLoc)
--   UseContainerItem https://emberveil.org/wiki/lua/globals/Container#usecontaineritem
--                    (equipable gear auto-equips; vendor/bank windows sell/bank
--                    instead, so those use PickupContainerItem + PickupInventoryItem)
--   GetContainerItemLink / GetContainerNumSlots on the same Container page.

local U = QtUiPlus
local M = U.media
local F = U.RegisterModule("equipflyout")

local ICON = 28
local PAD = 4
local MAX_ICONS = 20
local COLS = 5

local SLOT_TYPES = {
  HeadSlot          = { INVTYPE_HEAD = true },
  NeckSlot          = { INVTYPE_NECK = true },
  ShoulderSlot      = { INVTYPE_SHOULDER = true },
  BackSlot          = { INVTYPE_CLOAK = true },
  ChestSlot         = { INVTYPE_CHEST = true, INVTYPE_ROBE = true },
  ShirtSlot         = { INVTYPE_BODY = true },
  TabardSlot        = { INVTYPE_TABARD = true },
  WristSlot         = { INVTYPE_WRIST = true },
  HandsSlot         = { INVTYPE_HAND = true },
  WaistSlot         = { INVTYPE_WAIST = true },
  LegsSlot          = { INVTYPE_LEGS = true },
  FeetSlot          = { INVTYPE_FEET = true },
  Finger0Slot       = { INVTYPE_FINGER = true },
  Finger1Slot       = { INVTYPE_FINGER = true },
  Trinket0Slot      = { INVTYPE_TRINKET = true },
  Trinket1Slot      = { INVTYPE_TRINKET = true },
  MainHandSlot      = { INVTYPE_WEAPON = true, INVTYPE_WEAPONMAINHAND = true,
                        INVTYPE_2HWEAPON = true },
  SecondaryHandSlot = { INVTYPE_WEAPON = true, INVTYPE_WEAPONOFFHAND = true,
                        INVTYPE_SHIELD = true, INVTYPE_HOLDABLE = true },
  RangedSlot        = { INVTYPE_RANGED = true, INVTYPE_RANGEDRIGHT = true,
                        INVTYPE_RELIC = true, INVTYPE_WAND = true,
                        INVTYPE_GUN = true, INVTYPE_CROSSBOW = true,
                        INVTYPE_THROWN = true },
  AmmoSlot          = { INVTYPE_AMMO = true },
}

local flyout
local buttons = {}
local activeSlot
local activeInv
-- Which slot the cursor is on, and whether it is inside the open list. Both are
-- driven by OnEnter/OnLeave rather than polled: core/commands.lua records that
-- GetMouseFocus returns <none> for every sample of a hover watch on this
-- client, so a ticker cannot ask who has the cursor -- it can only be told.
local hoverSlot
local hoverName
local overFlyout
local hoverLeftAt
-- Slot and list sit 4 units apart, so crossing between them leaves the cursor
-- over neither for a tick or two. Hiding inside that window is what a poll
-- would do; this window is what stops it.
local HOVER_GRACE = 0.25

local function Now()
  local fn = U.G("GetTime")
  if type(fn) ~= "function" then return nil end
  local ok, value = pcall(fn)
  if not ok then return nil end
  return tonumber(value)
end

local function LeftHover()
  overFlyout = false
  hoverLeftAt = Now()
end

local function AltDown()
  local fn = U.G("IsAltKeyDown")
  if type(fn) ~= "function" then return false end
  local ok, value = pcall(fn)
  return ok and value == true
end

local function WindowOpen(name)
  local frame = U.G(name)
  if not frame or not frame.IsShown then return false end
  local ok, shown = pcall(frame.IsShown, frame)
  return ok and shown and true or false
end

local function FlyoutOpen()
  if activeSlot then return true end
  if not flyout or not flyout.IsShown then return false end
  local ok, shown = pcall(flyout.IsShown, flyout)
  return ok and shown and true or false
end

-- Only a tooltip this module put on screen may be taken down here. Wiki
-- GameTooltip#isowned: true when `frame` is the SetOwner target, and the flyout
-- buttons are the only frames this module ever makes an owner.
local function OwnsTooltip(tip)
  if not tip or not tip.IsOwned then return false end
  local i
  for i = 1, table.getn(buttons) do
    local ok, owned = pcall(tip.IsOwned, tip, buttons[i])
    if ok and owned then return true end
  end
  return false
end

-- Tick calls this every 0.08s whenever the paperdoll is shut or Alt is not
-- held, which is nearly always. It used to hide GameTooltip unconditionally on
-- each of those ticks, so every tooltip in the interface -- bags, action bars,
-- units, quests, none of them anything to do with this module -- was taken down
-- within 80ms of appearing. Nothing is touched now unless a flyout is actually
-- open, and the tooltip only when a flyout button owns it: the buttons hide
-- their own tooltip in OnLeave, so the hide here is just the case where the
-- list is pulled out from under a hovered button and that OnLeave never fires.
local function HideFlyout()
  local open = FlyoutOpen()
  activeSlot = nil
  activeInv = nil
  if not open then return end
  if flyout then pcall(flyout.Hide, flyout) end
  if U.HidePricePanel then U.HidePricePanel() end
  local tip = U.G("GameTooltip")
  if tip and OwnsTooltip(tip) then pcall(tip.Hide, tip) end
end

local function EquipLocOf(link)
  local info = U.G("GetItemInfo")
  if type(info) ~= "function" or not link then return nil end
  local ok, _, _, _, _, _, _, _, loc = pcall(info, link)
  if not ok then return nil end
  if type(loc) == "string" and loc ~= "" then return loc end
  return nil
end

local function ScanSlot(slotName)
  local accept = SLOT_TYPES[slotName]
  if not accept then return {} end
  local found = {}
  local numSlots = U.G("GetContainerNumSlots")
  local itemLink = U.G("GetContainerItemLink")
  local itemInfo = U.G("GetContainerItemInfo")
  if type(numSlots) ~= "function" or type(itemLink) ~= "function" then
    return found
  end
  local bag
  for bag = 0, 4 do
    local ok, count = pcall(numSlots, bag)
    count = (ok and tonumber(count)) or 0
    local slot
    for slot = 1, count do
      if table.getn(found) >= MAX_ICONS then return found end
      local linkOk, link = pcall(itemLink, bag, slot)
      if linkOk and type(link) == "string" then
        local loc = EquipLocOf(link)
        if loc and accept[loc] then
          local texture
          if type(itemInfo) == "function" then
            local iOk, tex = pcall(itemInfo, bag, slot)
            if iOk then texture = tex end
          end
          table.insert(found, { bag = bag, slot = slot, link = link,
                                texture = texture, loc = loc })
        end
      end
    end
  end
  return found
end

local function EquipItem(bag, slot, invSlot)
  if WindowOpen("MerchantFrame") or WindowOpen("BankFrame") then
    local pickBag = U.G("PickupContainerItem")
    local pickInv = U.G("PickupInventoryItem")
    if type(pickBag) == "function" and type(pickInv) == "function" and invSlot then
      pcall(pickBag, bag, slot)
      pcall(pickInv, invSlot)
    end
    local clear = U.G("ClearCursor")
    local has = U.G("CursorHasItem")
    if type(has) == "function" and type(clear) == "function" then
      local ok, value = pcall(has)
      if ok and value then pcall(clear) end
    end
    return
  end
  local use = U.G("UseContainerItem")
  if type(use) == "function" then pcall(use, bag, slot) end
end

local function EnsureFlyout()
  if flyout then return flyout end
  flyout = CreateFrame("Frame", "QtUiPlusEquipFlyout", UIParent)
  pcall(flyout.SetFrameStrata, flyout, "TOOLTIP")
  pcall(flyout.EnableMouse, flyout, true)
  U.CreateBackdrop(flyout, {
    background = { 0.02, 0.02, 0.02, 0.94 },
    border = M.color.border,
  })
  flyout:SetScript("OnEnter", function() overFlyout = true end)
  flyout:SetScript("OnLeave", function()
    LeftHover()
    if not AltDown() then HideFlyout() end
  end)
  local i
  for i = 1, MAX_ICONS do
    local btn = CreateFrame("Button", nil, flyout)
    btn:SetWidth(ICON)
    btn:SetHeight(ICON)
    pcall(btn.EnableMouse, btn, true)
    pcall(btn.RegisterForClicks, btn, "LeftButtonUp")
    U.CreateBackdrop(btn, { background = { 0.04, 0.04, 0.04, 0.95 } })
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", btn, "TOPLEFT", 1, -1)
    icon:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, 1)
    pcall(icon.SetTexCoord, icon, 0.08, 0.92, 0.08, 0.92)
    btn.icon = icon
    btn:SetScript("OnEnter", function()
      -- A button is inside the list, but entering it fires the frame's OnLeave,
      -- so the child has to re-assert the flag the parent just cleared.
      overFlyout = true
      local tip = U.G("GameTooltip")
      if not tip or not btn.bag then return end
      pcall(tip.SetOwner, tip, btn, "ANCHOR_RIGHT")
      if tip.SetBagItem then pcall(tip.SetBagItem, tip, btn.bag, btn.slot) end
      pcall(tip.Show, tip)
    end)
    btn:SetScript("OnLeave", function()
      local tip = U.G("GameTooltip")
      if tip then pcall(tip.Hide, tip) end
    end)
    btn:SetScript("OnClick", function()
      if btn.bag and btn.slot then
        EquipItem(btn.bag, btn.slot, activeInv)
      end
      if activeSlot then
        local name = activeSlot.qtpFlyoutSlot
        HideFlyout()
        if name and AltDown() then
          -- reopen with the remaining items
          local slot = U.G("Character" .. name)
          if slot then F.ShowForSlot(slot, name) end
        end
      else
        HideFlyout()
      end
    end)
    buttons[i] = btn
  end
  flyout:Hide()
  return flyout
end

function F.ShowForSlot(slotButton, slotName)
  local types = SLOT_TYPES[slotName]
  if not types or not slotButton then return end
  local items = ScanSlot(slotName)
  if table.getn(items) < 1 then
    HideFlyout()
    return
  end
  local frame = EnsureFlyout()
  local n = table.getn(items)
  local cols = n
  if cols > COLS then cols = COLS end
  local rows = math.floor((n + COLS - 1) / COLS)
  local width = PAD * 2 + cols * ICON + (cols - 1) * 2
  local height = PAD * 2 + rows * ICON + (rows - 1) * 2
  frame:SetWidth(width)
  frame:SetHeight(height)
  frame:ClearAllPoints()
  local growLeft = false
  if slotButton.GetLeft and UIParent.GetWidth then
    local okL, left = pcall(slotButton.GetLeft, slotButton)
    local okW, sw = pcall(UIParent.GetWidth, UIParent)
    if okL and okW and tonumber(left) and tonumber(sw) and left > sw * 0.55 then
      growLeft = true
    end
  end
  if growLeft then
    frame:SetPoint("TOPRIGHT", slotButton, "TOPLEFT", -4, 0)
  else
    frame:SetPoint("TOPLEFT", slotButton, "TOPRIGHT", 4, 0)
  end
  local inv
  if slotButton.GetID then
    local ok, id = pcall(slotButton.GetID, slotButton)
    if ok then inv = tonumber(id) end
  end
  if not inv then
    local info = U.G("GetInventorySlotInfo")
    if type(info) == "function" then
      local ok, id = pcall(info, slotName)
      if ok then inv = tonumber(id) end
    end
  end
  activeSlot = slotButton
  slotButton.qtpFlyoutSlot = slotName
  activeInv = inv
  local i
  for i = 1, MAX_ICONS do
    local btn = buttons[i]
    local spec = items[i]
    if spec then
      local col = math.mod(i - 1, COLS)
      local row = math.floor((i - 1) / COLS)
      btn:ClearAllPoints()
      btn:SetPoint("TOPLEFT", frame, "TOPLEFT",
                   PAD + col * (ICON + 2), -(PAD + row * (ICON + 2)))
      btn.bag = spec.bag
      btn.slot = spec.slot
      if spec.texture and spec.texture ~= "" then
        pcall(btn.icon.SetTexture, btn.icon, spec.texture)
      else
        pcall(btn.icon.SetTexture, btn.icon, "Interface\\Icons\\INV_Misc_QuestionMark")
      end
      btn:Show()
    else
      btn.bag = nil
      btn.slot = nil
      btn:Hide()
    end
  end
  frame:Show()
end

local function SlotUnderMouse()
  local focus = U.G("GetMouseFocus")
  if type(focus) ~= "function" then return nil, nil end
  local ok, widget = pcall(focus)
  if not ok or not widget then return nil, nil end
  if widget.qtpFlyoutSlot then return widget, widget.qtpFlyoutSlot end
  local parent = widget.GetParent and widget:GetParent()
  if parent and parent.qtpFlyoutSlot then return parent, parent.qtpFlyoutSlot end
  local name
  if widget.GetName then
    local nOk, value = pcall(widget.GetName, widget)
    if nOk then name = value end
  end
  if type(name) == "string" then
    local slotName = string.gsub(name, "^Character", "")
    slotName = string.gsub(slotName, "IconTexture$", "")
    if SLOT_TYPES[slotName] then
      return U.G("Character" .. slotName), slotName
    end
  end
  return nil, nil
end

-- Is the cursor inside the open list? The OnEnter/OnLeave flag is the answer
-- this client actually supplies; IsMouseOver and the GetMouseFocus parent walk
-- are kept below it because they cost nothing and would be the better answer on
-- a build where they work.
local function FlyoutHovered()
  if overFlyout then return true end
  if flyout and flyout.IsMouseOver then
    local mOk, over = pcall(flyout.IsMouseOver, flyout)
    if mOk and over then return true end
  end
  local focus = U.G("GetMouseFocus")
  if type(focus) == "function" and flyout then
    local fOk, widget = pcall(focus)
    if fOk and widget then
      local p = widget
      local guard = 0
      while p and guard < 8 do
        if p == flyout then return true end
        if p.GetParent then p = p:GetParent() else p = nil end
        guard = guard + 1
      end
    end
  end
  return false
end

local function Tick()
  local paper = U.G("PaperDollFrame")
  if not paper or not paper.IsShown then
    HideFlyout()
    return
  end
  local ok, shown = pcall(paper.IsShown, paper)
  if not ok or not shown then
    HideFlyout()
    return
  end
  if not AltDown() then
    HideFlyout()
    return
  end

  -- hoverSlot comes from the slot's own OnEnter, so this also opens the list
  -- when Alt goes down over a slot the cursor was already resting on.
  local slot, name = hoverSlot, hoverName
  if not slot or not name then slot, name = SlotUnderMouse() end
  if slot and name then
    if activeSlot ~= slot then F.ShowForSlot(slot, name) end
    return
  end

  if FlyoutHovered() then return end

  local now = Now()
  if hoverLeftAt and now and (now - hoverLeftAt) < HOVER_GRACE then return end

  HideFlyout()
end

function F:OnEnable()
  local names = {
    "HeadSlot", "NeckSlot", "ShoulderSlot", "BackSlot", "ChestSlot",
    "ShirtSlot", "TabardSlot", "WristSlot",
    "HandsSlot", "WaistSlot", "LegsSlot", "FeetSlot",
    "Finger0Slot", "Finger1Slot", "Trinket0Slot", "Trinket1Slot",
    "MainHandSlot", "SecondaryHandSlot", "RangedSlot", "AmmoSlot",
  }
  local i
  for i = 1, table.getn(names) do
    local slot = U.G("Character" .. names[i])
    if slot then
      slot.qtpFlyoutSlot = names[i]
      U.PostHookScript(slot, "OnEnter", function()
        hoverSlot = slot
        hoverName = names[i]
        overFlyout = false
        if AltDown() then F.ShowForSlot(slot, names[i]) end
      end)
      U.PostHookScript(slot, "OnLeave", function()
        -- Only the slot that is actually being left may clear the hover: the
        -- client can deliver the old slot's OnLeave after the new one's OnEnter.
        if hoverSlot == slot then
          hoverSlot = nil
          hoverName = nil
          LeftHover()
        end
      end)
    end
  end
  local paper = U.G("PaperDollFrame")
  if paper then
    U.PostHookScript(paper, "OnHide", HideFlyout)
  end
  U.RegisterUpdate("equipflyout.alt", 0.08, Tick)
end
