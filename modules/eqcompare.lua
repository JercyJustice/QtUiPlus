-- QtUiPlus :: modules/eqcompare.lua
--
-- Shows what you currently have equipped beside an item tooltip, so a drop or
-- a vendor item can be judged without opening the character sheet. Ported from
-- QtUI EqCompare.lua, which follows pfUI's eqcompare.
--
-- The comparison tooltips are the client's own ShoppingTooltip1 and
-- ShoppingTooltip2 (emberveil.org/wiki/lua/widgets/GameTooltip confirms both
-- exist and are the same type as GameTooltip), filled with SetInventoryItem --
-- documented there as filling "from an equipped (or ammo) inventory slot on a
-- player unit", which is exactly this case.
--
-- Which slot to compare against is decided by matching the tooltip's own
-- inventory-type line (INVTYPE_HEAD, "Head") against the localised globals,
-- rather than by parsing the item link. That keeps the module working in any
-- client locale without carrying a translation table, since the same globals
-- are what the tooltip printed in the first place.
--
-- Rings, trinkets and one-hand weapons occupy two slots, so those show both.

local U = QtUiPlus

local E = U.RegisterModule("eqcompare")

local slotRows

-- Built once, lazily: these globals are set up by the client's locale data and
-- reading them at file scope would run before that is guaranteed to exist.
-- A token that this client does not define is skipped rather than assumed.
local function BuildSlotRows()
  if slotRows then return slotRows end
  slotRows = {}

  local function Add(token, slot, other)
    local label = U.G(token)
    if type(label) == "string" and label ~= "" then
      table.insert(slotRows, { label = label, slot = slot, other = other })
    end
  end

  Add("INVTYPE_2HWEAPON", "MainHandSlot")
  Add("INVTYPE_BODY", "ShirtSlot")
  Add("INVTYPE_CHEST", "ChestSlot")
  Add("INVTYPE_CLOAK", "BackSlot")
  Add("INVTYPE_FEET", "FeetSlot")
  Add("INVTYPE_FINGER", "Finger0Slot", "Finger1Slot")
  Add("INVTYPE_HAND", "HandsSlot")
  Add("INVTYPE_HEAD", "HeadSlot")
  Add("INVTYPE_HOLDABLE", "SecondaryHandSlot")
  Add("INVTYPE_LEGS", "LegsSlot")
  Add("INVTYPE_NECK", "NeckSlot")
  Add("INVTYPE_RANGED", "RangedSlot")
  Add("INVTYPE_RANGEDRIGHT", "RangedSlot")
  Add("INVTYPE_RELIC", "RangedSlot")
  Add("INVTYPE_ROBE", "ChestSlot")
  Add("INVTYPE_SHIELD", "SecondaryHandSlot")
  Add("INVTYPE_SHOULDER", "ShoulderSlot")
  Add("INVTYPE_TABARD", "TabardSlot")
  Add("INVTYPE_TRINKET", "Trinket0Slot", "Trinket1Slot")
  Add("INVTYPE_WAIST", "WaistSlot")
  Add("INVTYPE_WEAPON", "MainHandSlot", "SecondaryHandSlot")
  Add("INVTYPE_WEAPONMAINHAND", "MainHandSlot")
  Add("INVTYPE_WEAPONOFFHAND", "SecondaryHandSlot")
  Add("INVTYPE_WRIST", "WristSlot")
  Add("INVTYPE_WAND", "RangedSlot")
  Add("INVTYPE_GUN", "RangedSlot")
  Add("INVTYPE_CROSSBOW", "RangedSlot")
  Add("INVTYPE_THROWN", "RangedSlot")

  return slotRows
end

local function Enabled()
  if not QtP:IsFeatureEnabled("eqcompare") then return false end
  local layout = QtP:GetLayout()
  if not layout then return true end
  return layout.eqCompare ~= false
end

local function HideOne(tooltip)
  if not tooltip then return end
  if tooltip.Hide then pcall(tooltip.Hide, tooltip) end
  if tooltip.ClearLines then pcall(tooltip.ClearLines, tooltip) end
end

local function HideCompare()
  HideOne(U.G("ShoppingTooltip1"))
  HideOne(U.G("ShoppingTooltip2"))
end

-- Anchors `compareTip` to whichever side of `tooltip` has room, and fills it
-- from the equipped item. Returns nil when the slot is empty, so the caller can
-- skip the second tooltip rather than showing an empty frame beside a full one.
local function ShowEquipped(tooltip, slotName, compareTip, side)
  if not tooltip or not slotName or not compareTip then return nil end

  local slotInfo = U.G("GetInventorySlotInfo")
  if type(slotInfo) ~= "function" or type(compareTip.SetInventoryItem) ~= "function" then
    return nil
  end

  local ok, slotID = pcall(slotInfo, slotName)
  if not ok or not slotID then return nil end

  local itemLink = U.G("GetInventoryItemLink")
  if type(itemLink) == "function" then
    local linkOk, link = pcall(itemLink, "player", slotID)
    if not linkOk or not link then return nil end
  end

  pcall(compareTip.SetOwner, compareTip, tooltip, "ANCHOR_NONE")
  compareTip:ClearAllPoints()
  if side == "right" then
    compareTip:SetPoint("BOTTOMLEFT", tooltip, "BOTTOMRIGHT", 4, 0)
  else
    compareTip:SetPoint("BOTTOMRIGHT", tooltip, "BOTTOMLEFT", -4, 0)
  end
  pcall(compareTip.SetInventoryItem, compareTip, "player", slotID)
  compareTip:Show()
  return slotID
end

-- Comparisons open away from the screen edge the tooltip is nearest, so they
-- are never pushed off-screen.
local function PreferredSide()
  local cursor = 0
  local getCursor = U.G("GetCursorPosition")
  if type(getCursor) == "function" then
    local ok, x = pcall(getCursor)
    cursor = (ok and tonumber(x)) or 0
  end

  local scale = 1
  if UIParent.GetEffectiveScale then
    local ok, value = pcall(UIParent.GetEffectiveScale, UIParent)
    scale = (ok and tonumber(value)) or 1
  end
  if scale == 0 then scale = 1 end

  local screen = 1024
  if UIParent.GetWidth then
    local ok, value = pcall(UIParent.GetWidth, UIParent)
    screen = (ok and tonumber(value)) or 1024
  end

  if (cursor / scale) < (screen / 2) then return "right" end
  return "left"
end

-- Native paperdoll slots. Hovering one already shows that equipped item, so
-- ShoppingTooltip would duplicate it (and for rings/trinkets/1H weapons pop
-- a second window for the other slot).
local PAPERDOLL_SLOTS = {
  "HeadSlot", "NeckSlot", "ShoulderSlot", "BackSlot", "ChestSlot",
  "ShirtSlot", "TabardSlot", "WristSlot",
  "HandsSlot", "WaistSlot", "LegsSlot", "FeetSlot",
  "Finger0Slot", "Finger1Slot", "Trinket0Slot", "Trinket1Slot",
  "MainHandSlot", "SecondaryHandSlot", "RangedSlot", "AmmoSlot",
}

-- Wiki GameTooltip#isowned: true when `frame` is the SetOwner target.
-- GetOwner is not on the GameTooltip widget page; a previous skip that
-- called it silently failed, which is why the character sheet showed the
-- same gloves twice (GameTooltip + ShoppingTooltip1).
local function IsOwnedBy(tooltip, frame)
  if not tooltip or not frame or not tooltip.IsOwned then return false end
  local ok, owned = pcall(tooltip.IsOwned, tooltip, frame)
  return ok and owned and owned ~= false and owned ~= 0
end

local function IsPaperDollOwner(tooltip)
  if not tooltip then return false end
  local i
  for i = 1, table.getn(PAPERDOLL_SLOTS) do
    local slot = U.G("Character" .. PAPERDOLL_SLOTS[i])
    if slot and IsOwnedBy(tooltip, slot) then return true end
  end
  -- Fallback if a custom owner still carries the native name.
  if tooltip.GetOwner then
    local ok, owner = pcall(tooltip.GetOwner, tooltip)
    if ok and owner and owner.GetName then
      local nameOk, name = pcall(owner.GetName, owner)
      if nameOk and type(name) == "string" and
         string.find(name, "Character", 1, true) then
        return true
      end
    end
  end
  return false
end

-- True when the hovered tooltip already is that equipped slot: comparing it
-- to itself is the duplicate on the paperdoll.
local function SameAsEquipped(slotName)
  local slotInfo = U.G("GetInventorySlotInfo")
  local itemLink = U.G("GetInventoryItemLink")
  local itemInfo = U.G("GetItemInfo")
  if type(slotInfo) ~= "function" or type(itemLink) ~= "function" or
     type(itemInfo) ~= "function" then
    return false
  end
  local ok, slotID = pcall(slotInfo, slotName)
  if not ok or not slotID then return false end
  local linkOk, link = pcall(itemLink, "player", slotID)
  if not linkOk or type(link) ~= "string" then return false end
  local infoOk, name = pcall(itemInfo, link)
  if not infoOk or type(name) ~= "string" or name == "" then return false end
  local label = U.G("GameTooltipTextLeft1")
  if not label or not label.GetText then return false end
  local textOk, text = pcall(label.GetText, label)
  if not textOk or type(text) ~= "string" then return false end
  return text == name
end

local function OnTooltipShow()
  if not Enabled() then
    HideCompare()
    return
  end

  local tooltip = U.G("GameTooltip")
  if not tooltip or not tooltip.IsVisible or not tooltip:IsVisible() then return end
  if IsPaperDollOwner(tooltip) then
    HideCompare()
    return
  end

  local rows = BuildSlotRows()
  local lines = 0
  if tooltip.NumLines then
    local ok, value = pcall(tooltip.NumLines, tooltip)
    lines = (ok and tonumber(value)) or 0
  end

  -- Line 1 is the item name; the inventory type never appears there.
  local i
  for i = 2, lines do
    local fontString = U.G("GameTooltipTextLeft" .. i)
    local text
    if fontString and fontString.GetText then
      local ok, value = pcall(fontString.GetText, fontString)
      if ok then text = value end
    end

    if text then
      local n
      for n = 1, table.getn(rows) do
        if text == rows[n].label then
          if SameAsEquipped(rows[n].slot) then
            HideCompare()
            return
          end
          local side = PreferredSide()
          local shown = ShowEquipped(tooltip, rows[n].slot,
                                     U.G("ShoppingTooltip1"), side)

          local second = U.G("ShoppingTooltip2")
          if shown and rows[n].other and second then
            local slotInfo = U.G("GetInventorySlotInfo")
            local itemLink = U.G("GetInventoryItemLink")
            local otherID
            if type(slotInfo) == "function" then
              local ok, value = pcall(slotInfo, rows[n].other)
              if ok then otherID = value end
            end

            local hasItem = otherID ~= nil
            if hasItem and type(itemLink) == "function" then
              local linkOk, link = pcall(itemLink, "player", otherID)
              hasItem = linkOk and link ~= nil
            end

            -- Chain the second tooltip off the first on the same side, so the
            -- pair reads as one block instead of straddling the item.
            if hasItem then
              local first = U.G("ShoppingTooltip1")
              pcall(second.SetOwner, second, tooltip, "ANCHOR_NONE")
              second:ClearAllPoints()
              if side == "right" then
                second:SetPoint("BOTTOMLEFT", first, "BOTTOMRIGHT", 4, 0)
              else
                second:SetPoint("BOTTOMRIGHT", first, "BOTTOMLEFT", -4, 0)
              end
              pcall(second.SetInventoryItem, second, "player", otherID)
              second:Show()
            end
          end
          return
        end
      end
    end
  end

  -- No inventory-type line: not equippable, so nothing to compare against.
  HideCompare()
end

function E:OnEnable()
  local tooltip = U.G("GameTooltip")
  if not tooltip then
    U.Error("eqcompare: GameTooltip unavailable")
    return
  end

  -- A watcher frame parented to the tooltip, rather than a hook on
  -- GameTooltip:Show. core/stockui.lua and modules/tooltip.lua already compose
  -- the tooltip; replacing a method they may also wrap would make the order the
  -- two run in depend on load order.
  local watch = CreateFrame("Frame", "QtUiPlusEqCompare", tooltip)
  watch:SetScript("OnShow", OnTooltipShow)
  watch:SetScript("OnHide", HideCompare)
end
