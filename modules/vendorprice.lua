-- QtUiPlus :: modules/vendorprice.lua
--
-- Puts the vendor sell price on item tooltips, from the static table in
-- core/vendorprices.lua.
--
-- The database was ported before this module existed and had exactly one
-- consumer, modules/autosell.lua, which used it to total what it sold. Nothing
-- ever displayed a price, so bag items showed none -- the data was there and
-- unreachable. This is the display half.
--
-- WHY HOOK THE SETTERS, not OnShow: the price depends on WHICH item the
-- tooltip is showing and how many of it, and only the Set* call knows that.
-- By OnShow the tooltip is just lines of text, and recovering the item from it
-- would mean parsing its name back into a link.
--
-- Each Set* method clears the tooltip's lines before filling it (confirmed for
-- SetBagItem at emberveil.org/wiki/lua/widgets/GameTooltip), so appending after
-- the original call adds exactly one line per display rather than accumulating.
--
-- modules/tooltip.lua hooks OnShow and OnSizeChanged to restyle the frame; it
-- does not touch these methods, so the two do not collide. Show() is called
-- after adding a line so the frame grows to fit, which re-enters that restyle
-- -- `adding` guards against a loop.

local U = QtUiPlus
local M = U.media

local VP = U.RegisterModule("vendorprice")

local hooked = false
local adding = false

local function Enabled()
  local layout = QtP:GetLayout()
  return layout and layout.vendorPrices ~= false
end

-- Gold/silver/copper, omitting the denominations that would read as zero. A
-- 3-copper item showing "0g 0s 3c" is noise on a tooltip.
local function FormatMoney(copper)
  copper = math.floor(tonumber(copper) or 0)
  local gold = math.floor(copper / 10000)
  local silver = math.floor(math.mod(copper / 100, 100))
  local remainder = math.floor(math.mod(copper, 100))

  local out = ""
  if gold > 0 then out = "|cffffd700" .. gold .. "g|r " end
  if gold > 0 or silver > 0 then
    out = out .. "|cffc7c7cf" .. silver .. "s|r "
  end
  return out .. "|cffeda55f" .. remainder .. "c|r"
end

-- Appends the sell line. `count` multiplies it for a stack, which is the number
-- that actually matters when deciding what to vendor.
local function AddPriceLine(tooltip, link, count)
  if adding or not tooltip or not link then return end
  if not Enabled() then return end
  if type(tooltip.AddDoubleLine) ~= "function" then return end

  local unit = QtP.VendorSellPrice(link)
  if not unit or unit <= 0 then return end

  count = tonumber(count) or 1
  if count < 1 then count = 1 end

  adding = true

  local label = "Sell"
  if count > 1 then label = "Sell (" .. count .. ")" end
  pcall(tooltip.AddDoubleLine, tooltip, label, FormatMoney(unit * count),
        M.Unpack(M.color.textDim))
  -- The frame is already sized to the lines it had; Show() re-measures it.
  pcall(tooltip.Show, tooltip)

  adding = false
end

-- ---------------------------------------------------------------------------
-- Hooks
--
-- Post-hooks: the original runs first and its return values are preserved, so
-- callers that read hasItem/hasCooldown are unaffected.
-- ---------------------------------------------------------------------------
local function HookMethod(tooltip, name, resolve)
  local original = tooltip[name]
  if type(original) ~= "function" then return end

  tooltip[name] = function(self, a, b, c)
    local r1, r2, r3 = original(self, a, b, c)
    local ok, link, count = pcall(resolve, a, b, c)
    if ok and link then AddPriceLine(self, link, count) end
    return r1, r2, r3
  end
end

local function InstallHooks()
  if hooked then return end
  local tooltip = U.G("GameTooltip")
  if not tooltip then return end
  hooked = true

  -- Bags, the bank and the keyring. bag/slot -> link plus the stack size.
  HookMethod(tooltip, "SetBagItem", function(bag, slot)
    local link = U.G("GetContainerItemLink")
    local info = U.G("GetContainerItemInfo")
    if type(link) ~= "function" then return nil end

    local count
    if type(info) == "function" then
      local ok, _, stack = pcall(info, bag, slot)
      if ok then count = stack end
    end
    return link(bag, slot), count
  end)

  -- Equipped items. Always a single item, never a stack.
  HookMethod(tooltip, "SetInventoryItem", function(unit, slot)
    local link = U.G("GetInventoryItemLink")
    if type(link) ~= "function" then return nil end
    return link(unit, slot), 1
  end)

  -- Chat links and anything else built from a hyperlink.
  HookMethod(tooltip, "SetHyperlink", function(link)
    return link, 1
  end)

  -- Loot window rows, so the value is visible before deciding to take it.
  HookMethod(tooltip, "SetLootItem", function(slot)
    local link = U.G("GetLootSlotLink")
    local info = U.G("GetLootSlotInfo")
    if type(link) ~= "function" then return nil end

    local count
    if type(info) == "function" then
      local ok, _, _, quantity = pcall(info, slot)
      if ok then count = quantity end
    end
    return link(slot), count
  end)
end

function VP:OnEnable()
  InstallHooks()
end
