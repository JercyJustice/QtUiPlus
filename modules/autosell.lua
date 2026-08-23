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

local U = QtUiPlus

local S = U.RegisterModule("autosell")

local GREY = 0        -- item quality: Poor
local MAX_BAG = 4     -- 0 backpack, 1-4 equipped bags

local function IsTruthy(value)
  return value == true or value == 1 or value == "1"
end

local function FormatMoney(copper)
  copper = tonumber(copper) or 0
  local gold = math.floor(copper / 10000)
  local silver = math.floor(math.mod(copper / 100, 100))
  local remainder = math.floor(math.mod(copper, 100))
  return string.format("|cffffd700%dg|r |cffc7c7cf%ds|r |cffeda55f%dc|r",
                       gold, silver, remainder)
end

local function SellGreyItems()
  if not QtP:IsFeatureEnabled("autosell") then return end
  local layout = QtP:GetLayout()
  if layout and layout.autoSell == false then return end

  local numSlots = U.G("GetContainerNumSlots")
  local slotInfo = U.G("GetContainerItemInfo")
  local itemLink = U.G("GetContainerItemLink")
  local useItem = U.G("UseContainerItem")
  if type(numSlots) ~= "function" or type(slotInfo) ~= "function"
     or type(useItem) ~= "function" then
    return
  end

  local soldItems, soldStacks, totalValue = 0, 0, 0
  local bag, slot

  for bag = 0, MAX_BAG do
    local ok, slots = pcall(numSlots, bag)
    slots = ok and tonumber(slots) or 0

    for slot = 1, slots do
      local infoOk, _, count, locked, quality = pcall(slotInfo, bag, slot)
      if infoOk and quality == GREY and not IsTruthy(locked) then
        local link
        if type(itemLink) == "function" then
          local linkOk, value = pcall(itemLink, bag, slot)
          if linkOk then link = value end
        end

        -- Only sell what a price is known for. An unknown price means the
        -- static table has no row and the client reported none either, and
        -- selling it would produce a total that does not match reality.
        local sellPrice = link and QtP.VendorSellPrice(link)
        if sellPrice and sellPrice > 0 then
          count = tonumber(count) or 1
          pcall(useItem, bag, slot)
          soldItems = soldItems + count
          soldStacks = soldStacks + 1
          totalValue = totalValue + (sellPrice * count)
        end
      end
    end
  end

  if soldStacks > 0 then
    local plural = "s"
    if soldItems == 1 then plural = "" end
    QtP:Print("Sold " .. soldItems .. " grey item" .. plural ..
              " for " .. FormatMoney(totalValue) .. ".")
  end
end

function S:OnEnable()
  U.RegisterEvent("MERCHANT_SHOW", SellGreyItems)
end
