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

-- Instrumentation for /qtp price. Guessing at why a tooltip line does not
-- appear has already cost one wrong fix; these counters make the failure point
-- observable instead.
local diag = {
  hookedMethods = {},
  setterCalls = 0,
  lookups = 0,
  linesAdded = 0,
  lastLink = nil,
  lastPrice = nil,
  lastError = nil,
}

QtP.vendorPriceDiag = diag

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

  if type(tooltip.AddDoubleLine) ~= "function" then
    diag.lastError = "GameTooltip has no AddDoubleLine"
    return
  end

  diag.lookups = diag.lookups + 1
  diag.lastLink = link

  local unit = QtP.VendorSellPrice(link)
  diag.lastPrice = unit
  if not unit or unit <= 0 then
    diag.lastError = "no price for this item"
    return
  end

  count = tonumber(count) or 1
  if count < 1 then count = 1 end

  adding = true

  local label = "Sell"
  if count > 1 then label = "Sell (" .. count .. ")" end

  -- AddDoubleLine is documented as
  --   AddDoubleLine(leftText, rightText, lR, lG, lB, rR, rG, rB)
  -- -- six separate colour numbers, three per side. The previous version
  -- passed M.Unpack(...), which returns FOUR values (r, g, b, a): the alpha
  -- landed in lR's right-hand counterpart with no rG/rB behind it, producing a
  -- malformed call that a pcall then swallowed silently. Both sides now get
  -- three explicit numbers, and the alpha is dropped -- this call has no
  -- parameter for it.
  local lr, lg, lb = M.Unpack(M.color.textDim)
  local rr, rg, rb = M.Unpack(M.color.text)

  local ok, err = pcall(tooltip.AddDoubleLine, tooltip,
                        label, FormatMoney(unit * count),
                        lr, lg, lb, rr, rg, rb)
  if ok then
    diag.linesAdded = diag.linesAdded + 1
    diag.lastError = nil
  else
    diag.lastError = "AddDoubleLine: " .. tostring(err)
  end

  -- The frame was sized to the lines it had before this one, so it has to be
  -- re-measured or the new line is laid out beyond the visible backdrop. Show
  -- is the only re-measure this client documents.
  if type(tooltip.Show) == "function" then
    local showOk, showErr = pcall(tooltip.Show, tooltip)
    if not showOk then diag.lastError = "Show: " .. tostring(showErr) end
  end

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
    diag.setterCalls = diag.setterCalls + 1
    local ok, link, count = pcall(resolve, a, b, c)
    if ok and link then
      AddPriceLine(self, link, count)
    elseif not ok then
      diag.lastError = "resolve " .. name .. ": " .. tostring(link)
    end
    return r1, r2, r3
  end

  table.insert(diag.hookedMethods, name)
end

local function InstallHooks()
  if hooked then return end
  local tooltip = U.G("GameTooltip")
  if not tooltip then return end
  hooked = true

  -- SetBagItem is deliberately NOT hooked.
  --
  -- Replacing a method on the GameTooltip table only intercepts callers that
  -- go through Lua. The stock bag-button OnEnter on this client is not
  -- guaranteed to: a reimplemented client can fill the tooltip natively, in
  -- which case the Lua method is never consulted and the hook silently never
  -- runs -- which is exactly the symptom that was reported.
  --
  -- QtUiPlus builds its own bag and bank slot buttons (core/itemslot.lua), so
  -- the price for those is added from their OnEnter through
  -- QtP.AddVendorPriceForSlot below. That path is ours end to end and does not
  -- depend on how the client fills the tooltip. The setters below stay hooked
  -- because there is no QtUiPlus-owned button behind them.

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

-- Called from core/itemslot.lua's OnEnter post-hook, after the stock handler
-- has filled the tooltip. Resolves the item from the slot itself rather than
-- from tooltip text.
function QtP.AddVendorPriceForSlot(bag, slot)
  local tooltip = U.G("GameTooltip")
  if not tooltip then return end
  if not tooltip.IsVisible or not tooltip:IsVisible() then return end

  local getLink = U.G("GetContainerItemLink")
  local getInfo = U.G("GetContainerItemInfo")
  if type(getLink) ~= "function" then return end

  local ok, link = pcall(getLink, bag, slot)
  if not ok or not link then return end

  local count
  if type(getInfo) == "function" then
    local infoOk, _, stack = pcall(getInfo, bag, slot)
    if infoOk then count = stack end
  end

  diag.setterCalls = diag.setterCalls + 1
  AddPriceLine(tooltip, link, count)
end

function VP:OnEnable()
  InstallHooks()
end
