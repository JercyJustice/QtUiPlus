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

-- Same string QtUI Bags.lua prints on hover (always g/s/c).
local function FormatMoney(copper)
  copper = math.floor(tonumber(copper) or 0)
  local gold = math.floor(copper / 10000)
  local silver = math.floor(math.mod(copper / 100, 100))
  local remainder = math.floor(math.mod(copper, 100))
  return string.format("|cffffd700%dg|r  |cffc7c7cf%ds|r  |cffeda55f%dc|r",
                       gold, silver, remainder)
end

-- True when this tooltip already has our Sell value row, so OnEnter plus a
-- SetBagItem hook cannot stack the same lines twice.
local function HasSellLine(tooltip)
  if not tooltip then return false end
  local ok, n = pcall(function() return tooltip:NumLines() end)
  n = (ok and tonumber(n)) or 0
  if n < 1 then return false end
  local i
  for i = n, math.max(1, n - 3), -1 do
    local label = U.G("GameTooltipTextLeft" .. i)
    if label and type(label.GetText) == "function" then
      local textOk, text = pcall(label.GetText, label)
      if textOk and type(text) == "string" and string.find(text, "Sell value") then
        return true
      end
    end
  end
  return false
end

local function TryAddLine(tooltip, text, r, g, b)
  -- Do not require type(...) == "function": widget methods on this client
  -- are retrieved through a metatable and may not type as a Lua function.
  return pcall(function()
    tooltip:AddLine(text, r, g, b)
  end)
end

-- QtUI's working hover path on this client: blank spacer, "Sell value", and
-- "Stack value" when count > 1, all via AddLine (wiki GameTooltip#addline).
-- AddDoubleLine is only the fallback if AddLine is missing.
local function AddPriceLine(tooltip, link, count)
  if adding or not tooltip or not link then return end
  if not Enabled() then return end
  if HasSellLine(tooltip) then return end

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

  TryAddLine(tooltip, " ")
  local ok, err = TryAddLine(tooltip, "Sell value: " .. FormatMoney(unit), 1, 1, 1)
  if ok and count > 1 then
    TryAddLine(tooltip, "Stack value: " .. FormatMoney(unit * count), 0.75, 0.85, 1)
  end
  if not ok then
    local lr, lg, lb = M.Unpack(M.color.textDim)
    local rr, rg, rb = M.Unpack(M.color.text)
    local label = (count > 1) and ("Sell (" .. count .. ")") or "Sell"
    ok, err = pcall(function()
      tooltip:AddDoubleLine(label, FormatMoney(unit * count), lr, lg, lb, rr, rg, rb)
    end)
  end

  if ok then
    diag.linesAdded = diag.linesAdded + 1
    diag.lastError = nil
  else
    diag.lastError = tostring(err)
  end

  -- AddLine/AddDoubleLine layout a visible tooltip; a hidden one is measured
  -- when it is next shown (wiki). Do not Hide() first -- that is a no-op for
  -- layout when the frame is already shown, and it dismisses a working tooltip.
  local showOk, showErr = pcall(function() tooltip:Show() end)
  if not showOk then diag.lastError = "Show: " .. tostring(showErr) end

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
    local origOk, r1, r2, r3 = pcall(original, self, a, b, c)
    diag.setterCalls = diag.setterCalls + 1
    local ok, link, count = pcall(resolve, a, b, c)
    if ok and link then
      AddPriceLine(self, link, count)
    elseif not ok then
      diag.lastError = "resolve " .. name .. ": " .. tostring(link)
    end
    if origOk then return r1, r2, r3 end
  end

  table.insert(diag.hookedMethods, name)
end

local function InstallHooks()
  if hooked then return end
  local tooltip = U.G("GameTooltip")
  if not tooltip then return end
  hooked = true

  -- Bag / bank / keyring slots. Documented at
  -- wiki/lua/widgets/GameTooltip#setbagitem: clears lines, fills from bag/slot,
  -- then shows. Lua callers (XML OnEnter compiled on first GetScript, and
  -- QtP.AddVendorPriceForSlot below) go through this table method. A native
  -- C++ fill that never consults Lua is handled by the slot OnEnter path,
  -- which calls SetBagItem itself after SetOwner.
  HookMethod(tooltip, "SetBagItem", function(bag, slot)
    local link = U.G("GetContainerItemLink")
    local info = U.G("GetContainerItemInfo")
    if type(link) ~= "function" then return nil end

    local count
    if type(info) == "function" then
      -- GetContainerItemInfo: texture, count, locked, quality, readable
      -- (wiki/lua/globals/Container#getcontaineriteminfo). pcall prefixes ok.
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

-- Bag/bank hover. Mirrors QtUI Bags.lua OnEnter, which is the path that
-- actually showed prices on this client: SetOwner(ANCHOR_LEFT), SetBagItem,
-- then Sell value / Stack value AddLine, then Show.
-- wiki: SetOwner https://emberveil.org/wiki/lua/widgets/GameTooltip#setowner
--       SetBagItem https://emberveil.org/wiki/lua/widgets/GameTooltip#setbagitem
--       AddLine    https://emberveil.org/wiki/lua/widgets/GameTooltip#addline
local lastHover

function QtP.ShowItemSlotTooltip(bag, slot, button)
  -- Item stats stay on GameTooltip. The sell price is QtUiPlusPricePanel
  -- (core/widgets.lua): this addon already refused to inject money into
  -- GameTooltip because the line pool is not reliable here.
  if not button then return end

  local link = GetContainerItemLink(bag, slot)
  if not link then
    if U.HidePricePanel then U.HidePricePanel() end
    return
  end

  local _, count = GetContainerItemInfo(bag, slot)
  count = tonumber(count) or 1
  if count < 1 then count = 1 end
  lastHover = { bag = bag, slot = slot, link = link, count = count, button = button }

  if GameTooltip then
    pcall(function()
      GameTooltip:SetOwner(button, "ANCHOR_LEFT")
      GameTooltip:SetBagItem(bag, slot)
      GameTooltip:Show()
    end)
  end

  diag.setterCalls = diag.setterCalls + 1
  diag.lastLink = link

  if not Enabled() then
    if U.HidePricePanel then U.HidePricePanel() end
    return
  end

  local sellPrice = QtP.VendorSellPrice(link)
  diag.lastPrice = sellPrice
  diag.lookups = diag.lookups + 1
  if not sellPrice or sellPrice <= 0 then
    diag.lastError = "no price for this item"
    if U.HidePricePanel then U.HidePricePanel() end
    return
  end

  local total = sellPrice * count
  local caption = (count > 1) and ("Sell (" .. count .. "):") or "Sell:"
  local anchor = button
  if GameTooltip and GameTooltip.IsShown then
    local ok, shown = pcall(GameTooltip.IsShown, GameTooltip)
    if ok and shown then anchor = GameTooltip end
  end

  if type(U.ShowPricePanel) == "function" then
    U.ShowPricePanel(anchor, total, caption)
    diag.linesAdded = diag.linesAdded + 1
    diag.lastError = nil
  else
    diag.lastError = "ShowPricePanel missing"
  end
end

function QtP.ClearItemSlotTooltip()
  lastHover = nil
  if U.HidePricePanel then U.HidePricePanel() end
end

-- Quest log / quest-giver reward hover.
-- wiki: GetQuestLogItemLink / GetQuestItemLink (Item),
--       GetQuestLogChoiceInfo / GetQuestLogRewardInfo / GetQuestItemInfo (Quest),
--       GameTooltip:SetQuestLogItem / SetQuestItem.
-- Same owned price panel as bag slots; GameTooltip only carries the item text.
function QtP.ShowQuestItemPrice(source, itemType, index, button)
  if not Enabled() then
    if U.HidePricePanel then U.HidePricePanel() end
    return
  end

  itemType = string.lower(tostring(itemType or ""))
  index = tonumber(index)
  if itemType == "" or not index or index < 1 then return end

  local link, count
  if source == "giver" then
    if type(GetQuestItemLink) == "function" then
      local ok, value = pcall(GetQuestItemLink, itemType, index)
      if ok then link = value end
    end
    if type(GetQuestItemInfo) == "function" then
      local ok, _, _, numItems = pcall(GetQuestItemInfo, itemType, index)
      if ok then count = tonumber(numItems) end
    end
  else
    if type(GetQuestLogItemLink) == "function" then
      local ok, value = pcall(GetQuestLogItemLink, itemType, index)
      if ok then link = value end
    end
    local info = (itemType == "choice") and GetQuestLogChoiceInfo or GetQuestLogRewardInfo
    if type(info) == "function" then
      local ok, _, _, numItems = pcall(info, index)
      if ok then count = tonumber(numItems) end
    end
  end

  count = tonumber(count) or 1
  if count < 1 then count = 1 end

  diag.setterCalls = diag.setterCalls + 1
  diag.lastLink = link
  if not link then
    diag.lastError = "no quest item link"
    if U.HidePricePanel then U.HidePricePanel() end
    return
  end

  if button and GameTooltip then
    local shown
    if GameTooltip.IsShown then
      local ok, value = pcall(GameTooltip.IsShown, GameTooltip)
      shown = ok and value
    end
    if not shown then
      pcall(function()
        GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
        if source == "giver" then
          GameTooltip:SetQuestItem(itemType, index)
        else
          GameTooltip:SetQuestLogItem(itemType, index)
        end
        GameTooltip:Show()
      end)
    end
  end

  local sellPrice = QtP.VendorSellPrice(link)
  diag.lastPrice = sellPrice
  diag.lookups = diag.lookups + 1
  if not sellPrice or sellPrice <= 0 then
    diag.lastError = "no price for this item"
    if U.HidePricePanel then U.HidePricePanel() end
    return
  end

  local caption = (count > 1) and ("Sell (" .. count .. "):") or "Sell:"
  local anchor = button
  if GameTooltip and GameTooltip.IsShown then
    local ok, shown = pcall(GameTooltip.IsShown, GameTooltip)
    if ok and shown then anchor = GameTooltip end
  end

  if type(U.ShowPricePanel) == "function" then
    U.ShowPricePanel(anchor, sellPrice * count, caption)
    diag.linesAdded = diag.linesAdded + 1
    diag.lastError = nil
  end
end

function QtP.AttachQuestItemPrice(button, source)
  if not button or button.qtpQuestPrice then return end
  button.qtpQuestPrice = source or "log"

  U.PostHookScript(button, "OnEnter", function(self)
    local owner = self or this or button
    local itemType = owner and (owner.type or owner.kind)
    local index = owner and owner.index
    if not index and owner and owner.GetID then
      local ok, value = pcall(owner.GetID, owner)
      if ok then index = value end
    end
    if (not itemType or itemType == "") and index then
      if button.qtpQuestPrice == "giver" then
        itemType = "reward"
        if type(GetQuestItemLink) == "function" then
          local ok, link = pcall(GetQuestItemLink, "reward", index)
          if not (ok and link) then
            ok, link = pcall(GetQuestItemLink, "choice", index)
            if ok and link then itemType = "choice" end
            if not (ok and link) then
              ok, link = pcall(GetQuestItemLink, "required", index)
              if ok and link then itemType = "required" end
            end
          end
        end
      else
        itemType = "reward"
        if type(GetQuestLogItemLink) == "function" then
          local ok, link = pcall(GetQuestLogItemLink, "reward", index)
          if not (ok and link) then
            ok, link = pcall(GetQuestLogItemLink, "choice", index)
            if ok and link then itemType = "choice" end
          end
        end
      end
    end
    QtP.ShowQuestItemPrice(button.qtpQuestPrice, itemType, index, owner)
  end)
  U.PostHookScript(button, "OnLeave", function()
    if U.HidePricePanel then U.HidePricePanel() end
  end)
end

local function AttachAllQuestItems()
  local maxItems = tonumber(U.G("MAX_NUM_ITEMS")) or 10
  local i
  for i = 1, maxItems do
    local item = U.G("QuestLogItem" .. i)
    if item then QtP.AttachQuestItemPrice(item, "log") end
  end

  local prefixes = { "QuestProgressItem", "QuestDetailItem", "QuestRewardItem" }
  local p, n
  for p = 1, table.getn(prefixes) do
    for n = 1, 10 do
      local item = U.G(prefixes[p] .. n)
      if item then QtP.AttachQuestItemPrice(item, "giver") end
    end
  end
end

-- Kept for /qtp price and any leftover callers; same as ShowItemSlotTooltip
-- without requiring the button (appends only if the tooltip is already filled).
function QtP.AddVendorPriceForSlot(bag, slot, button)
  if button then
    QtP.ShowItemSlotTooltip(bag, slot, button)
    return
  end

  local tooltip = U.G("GameTooltip")
  if not tooltip then return end

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
  AttachAllQuestItems()

  -- Hide the owned price panel when GameTooltip hides, so a missed OnLeave
  -- cannot leave Sell: stuck on screen.
  local tooltip = U.G("GameTooltip")
  if not tooltip then return end
  local ok, watcher = pcall(CreateFrame, "Frame", nil, tooltip)
  if not ok or not watcher then return end
  pcall(watcher.SetScript, watcher, "OnHide", function()
    if U.HidePricePanel then U.HidePricePanel() end
  end)
end
