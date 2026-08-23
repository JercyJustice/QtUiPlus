-- QtUiPlus :: modules/autosell.lua
--
-- Sells every grey-quality item in the bags when a merchant window opens, and
-- reports what it made. Ported from QtUI Bags.lua (AutoSellGreyItems).
--
-- One deliberate change from the original: quality comes from
-- GetContainerItemInfo rather than GetItemInfo. emberveil.org/wiki/lua/globals/
-- Container documents GetContainerItemInfo as returning
-- `texture, count, locked, quality, readable` -- "always five values" -- so the
-- quality of the item actually in the slot is already in hand. QtUI instead
-- passed the link to GetItemInfo, which is the server item cache: for an item
-- the client has not cached yet it returns nothing, and the item is silently
-- skipped. Reading the slot removes that failure mode and one call per slot.
--
-- The sell itself is UseContainerItem(bag, slot), which is the vendor-sell
-- action while a merchant window is open (wiki, same page: "Returns: none").
-- There is no confirmation step for grey items, so nothing here has to handle
-- one.
--
-- Do not sell the whole bag in one MERCHANT_SHOW tick. UseContainerItem drives
-- the cursor; a tight loop of it on this client hard-crashes (bags.lua already
-- throttles its manual Sell Grays button for that reason). Empty slots also
-- report quality 0 and a truthy empty texture path, so a link check is
-- required. If the merchant closes mid-queue, abort: with no vendor open the
-- same call uses or equips the item instead of selling it.

local U = QtUiPlus

local S = U.RegisterModule("autosell")

local GREY = 0        -- item quality: Poor
local MAX_BAG = 4     -- 0 backpack, 1-4 equipped bags
local SELL_INTERVAL = 0.15

local pending -- { items, index, soldItems, soldStacks, totalValue }

local function IsTruthy(value)
  return value == true or value == 1 or value == "1"
end

local function MerchantIsOpen()
  local merchant = U.G("MerchantFrame")
  if not merchant or not merchant.IsShown then return false end
  local ok, shown = pcall(merchant.IsShown, merchant)
  return ok and IsTruthy(shown)
end

local function FormatMoney(copper)
  copper = tonumber(copper) or 0
  local gold = math.floor(copper / 10000)
  local silver = math.floor(math.mod(copper / 100, 100))
  local remainder = math.floor(math.mod(copper, 100))
  return string.format("|cffffd700%dg|r |cffc7c7cf%ds|r |cffeda55f%dc|r",
                       gold, silver, remainder)
end

local function StopQueue()
  pending = nil
  U.UnregisterUpdate("autosell.sell")
end

local function ProcessPending()
  if not pending then
    StopQueue()
    return
  end

  if not MerchantIsOpen() then
    StopQueue()
    return
  end

  local item = pending.items[pending.index]
  if not item then
    if pending.soldStacks > 0 then
      local plural = "s"
      if pending.soldItems == 1 then plural = "" end
      QtP:Print("Sold " .. pending.soldItems .. " grey item" .. plural ..
                " for " .. FormatMoney(pending.totalValue) .. ".")
    end
    StopQueue()
    return
  end

  pending.index = pending.index + 1

  local slotInfo = U.G("GetContainerItemInfo")
  local itemLink = U.G("GetContainerItemLink")
  local useItem = U.G("UseContainerItem")
  if type(slotInfo) ~= "function" or type(useItem) ~= "function" then
    StopQueue()
    return
  end

  local infoOk, texture, count, locked, quality = pcall(slotInfo, item.bag, item.slot)
  if not infoOk or type(texture) ~= "string" or texture == "" then return end
  if quality ~= GREY or IsTruthy(locked) then return end

  local link
  if type(itemLink) == "function" then
    local linkOk, value = pcall(itemLink, item.bag, item.slot)
    if linkOk then link = value end
  end
  if type(link) ~= "string" or link == "" then return end

  local priceOk, sellPrice = pcall(QtP.VendorSellPrice, link)
  sellPrice = (priceOk and tonumber(sellPrice)) or 0
  if sellPrice <= 0 then return end

  local clear = U.G("ClearCursor")
  if type(clear) == "function" then pcall(clear) end
  pcall(useItem, item.bag, item.slot)

  count = tonumber(count) or 1
  pending.soldItems = pending.soldItems + count
  pending.soldStacks = pending.soldStacks + 1
  pending.totalValue = pending.totalValue + (sellPrice * count)
end

local function CollectGreyItems()
  local list = {}
  local numSlots = U.G("GetContainerNumSlots")
  local slotInfo = U.G("GetContainerItemInfo")
  local itemLink = U.G("GetContainerItemLink")
  if type(numSlots) ~= "function" or type(slotInfo) ~= "function" then
    return list
  end

  local bag, slot
  for bag = 0, MAX_BAG do
    local ok, slots = pcall(numSlots, bag)
    slots = ok and tonumber(slots) or 0
    for slot = 1, slots do
      local infoOk, texture, count, locked, quality = pcall(slotInfo, bag, slot)
      if infoOk and type(texture) == "string" and texture ~= ""
         and quality == GREY and not IsTruthy(locked) then
        local link
        if type(itemLink) == "function" then
          local linkOk, value = pcall(itemLink, bag, slot)
          if linkOk then link = value end
        end
        if type(link) == "string" and link ~= "" then
          table.insert(list, { bag = bag, slot = slot })
        end
      end
    end
  end
  return list
end

local function StartSell()
  if pending then return end
  if not QtP:IsFeatureEnabled("autosell") then return end
  local layout = QtP:GetLayout()
  if layout and layout.autoSell == false then return end
  if not MerchantIsOpen() then return end

  local items = CollectGreyItems()
  if table.getn(items) < 1 then return end

  pending = {
    items = items,
    index = 1,
    soldItems = 0,
    soldStacks = 0,
    totalValue = 0,
  }
  U.RegisterUpdate("autosell.sell", SELL_INTERVAL, ProcessPending)
end

function S:OnEnable()
  U.RegisterEvent("MERCHANT_SHOW", StartSell)
  U.RegisterEvent("MERCHANT_CLOSED", StopQueue)
end
