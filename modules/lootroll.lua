-- QtUiPlus :: modules/lootroll.lua
--
-- The group loot roll window (GroupLootFrame1..4 -- what appears when an item
-- drops that the party rolls on). Until now nothing skinned it: it kept the
-- stock stone frame, which on this client draws with its children scattered
-- over it, and it sat on the flat interface looking like a different addon.
--
-- Rebuilt as the retail card: item icon on the left, item name beside it in its
-- quality colour, the Need/Greed/Pass buttons grouped on the right, and the
-- roll timer as a thin bar along the bottom edge.
--
--   +-------------------------------------------------+
--   |  [icon]  Item Name              [N] [G] [P]     |
--   |=================================================|
--   +-------------------------------------------------+
--
-- The native frame keeps every behaviour it has: the buttons are the client's
-- own (their OnClick still calls RollOnLoot), the timer is the client's own
-- StatusBar still driven by the client's OnUpdate, and frame.rollID is read,
-- never written. Only artwork, typography and placement change.
--
-- Loot roll API, all documented at emberveil.org/wiki/lua/globals/Loot:
--   GetLootRollItemInfo(rollID) -> icon, name, count, quality, bindOnPickUp
--   RollOnLoot / GetLootRollTimeLeft / GetLootRollItemLink
-- Only GetLootRollItemInfo is called here, for the quality colour.
--
-- The widget hierarchy is NOT covered by this client's compact evidence, so
-- every child is looked up by the FrameXML $parent naming and each one is
-- optional -- a name that does not resolve on this build simply goes unstyled
-- rather than faulting.

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

-- USER_CONFIRMED_INGAME: laying out inside the stock frame's own proportions
-- left barely 60 units for the name, so "Mage-Eye Blunderbuss" wrapped onto two
-- lines and ran under the icon. The card gets its own size instead.
--
-- Only *shrinking* the height is safe for the stack: a roll frame is positioned
-- by the client, and the next one sits below it, so a shorter card closes the
-- gap while a taller one would overlap. The width is free either way -- the
-- stack is vertical.
local CARD_W = 300
local CARD_H = 44

-- What is left for the name once the icon, the three buttons and the paddings
-- have taken their share. Derived from the constants above rather than measured
-- off the frame, so it cannot go negative on a build whose GetWidth surprises.
-- What is left for the name once the icon, the button row and the paddings have
-- taken their share. Derived from the constants and the row that was actually
-- built, so a frame that turns out to carry a different number of buttons still
-- gets a name that stops short of them.
local function NameWidth(buttonCount)
  local count = tonumber(buttonCount) or 3
  if count < 1 then count = 1 end
  local row = BTN * count + BTN_GAP * (count - 1)
  local width = CARD_W - PAD - ICON - NAME_GAP - row - NAME_GAP - PAD
  if width < 40 then width = 40 end
  return width
end

-- Gap between stacked rolls.
local STACK_GAP = 6

-- The client decides where a roll frame opens, and on this client that lands it
-- in the middle of the screen where the nameplates are -- which is why the
-- target plate kept covering the card no matter how high the strata went. The
-- cards hang off an invisible mover instead, so the window is placed in Anchor
-- Mode like every other QtUiPlus element and can be parked clear of the plates.
local anchor

local function BuildAnchor()
  if anchor then return anchor end
  local frame = CreateFrame("Frame", "QtUiPlusLootRollAnchor", UIParent)
  frame:SetWidth(CARD_W)
  frame:SetHeight(CARD_H)
  pcall(frame.EnableMouse, frame, false)
  if type(U.RegisterMover) == "function" then
    U.RegisterMover("lootroll.anchor", frame, {
      label = "Loot Roll",
      -- Deliberately off-centre. USER_CONFIRMED_INGAME the thing covering the
       -- card is the target's nameplate -- modules/nameplates.lua gives the
      -- target plate the accent border and writes U.FormatHealthText("target")
      -- across it, which is the "Dead" / "551 - 58%" bar that kept appearing
      -- inside the window. A plate floats over the unit, so it sits near the
      -- middle of the screen; a card centred there lines up with it every time.
      -- Starting left of centre keeps the two apart without the user having to
      -- move anything, and the mover is there for those who want it elsewhere.
      default = {
        point = "TOPLEFT",
        relativePoint = "TOPLEFT",
        x = 24,
        y = -160,
      },
    })
  end
  anchor = frame
  return frame
end

-- Returns quality and item name, both from the one documented call.
local function RollItem(frame)
  local rollID = frame and frame.rollID
  if not rollID then return nil, nil end
  local info = U.G("GetLootRollItemInfo")
  if type(info) ~= "function" then return nil, nil end
  local ok, _, itemName, _, quality = pcall(info, rollID)
  if not ok then return nil, nil end
  return tonumber(quality), itemName
end

local function StyleIcon(name, quality)
  local icon = U.G(name .. "IconFrame")
  if not icon then return nil end
  -- Same flat treatment as a bag slot, including keeping the item texture and
  -- cropping its border away.
  U.StyleItemSlot(icon, name .. "IconFrame")
  pcall(icon.SetWidth, icon, ICON)
  pcall(icon.SetHeight, icon, ICON)

  -- U.StyleItemSlot crops and pins $parentIconTexture, the name a bag slot
  -- uses. Read out of QtUiPlusDiagDB.rollAuto, this frame calls it
  -- $parentIconFrameIcon instead, and it was drawing 34x34 out of a 32 button
  -- with no inset, so it is placed here by whichever of the two names resolves.
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
  return icon
end

-- The roll buttons.
--
-- USER_CONFIRMED_INGAME: the coin and the red X took the styling and the dice
-- did not -- it kept its stock size and spilled over the coin beside it. Two of
-- three resolving means this client does not name all three the way FrameXML
-- does, so the row is no longer built from names alone: every Button among the
-- frame's own children that is not the item icon is a roll button.
--
-- The documented names are still tried first so a build that does match keeps
-- that order, anything else found is appended, and the row is then sorted by
-- the x the client had already given each button -- so it reads left to right
-- in the client's own order whatever the buttons turn out to be called.
-- Frame identity is not usable on this client.
--
-- Read out of QtUiPlusDiagDB.rollAuto: the item icon ended up sized 24x24 and
-- anchored into the button row, and the name was 76 wide -- which is exactly
-- NameWidth(6), so six buttons had been collected from a frame that has four.
-- Both follow from the same cause: the object U.G(name) returns does not
-- compare equal to the object GetChildren() hands back for that same frame, so
-- "child ~= icon" never excluded the icon and "seen[button]" never recognised
-- Greed and Pass as already collected. Names are compared instead, everywhere.
local function NameOf(object)
  if not object or type(object.GetName) ~= "function" then return nil end
  local ok, value = pcall(object.GetName, object)
  if ok and type(value) == "string" then return value end
  return nil
end

-- The roll buttons.
--
-- Read out of the same dump: this client's dice is $parentRollButton, not
-- $parentNeedButton, which is why two of three buttons took the styling and the
-- dice kept its stock size and spilled over the coin. Both names are listed so
-- either shape works, in retail's order; anything else found among the frame's
-- Button children is appended, so a name nobody guessed still lands in the row.
-- Left-to-right order of the roll row, keyed by the button's name suffix.
-- RollButton is this client's dice, the Need equivalent.
local BUTTON_ORDER = {
  RollButton  = 1,
  NeedButton  = 1,
  GreedButton = 2,
  PassButton  = 3,
}

local function CollectButtons(name, frame)
  local list, seen = {}, {}
  local iconName = name .. "IconFrame"
  local known = { "RollButton", "NeedButton", "GreedButton", "PassButton" }

  local function Take(button)
    if not button then return end
    local key = NameOf(button) or button
    if key == iconName or seen[key] then return end
    seen[key] = true
    table.insert(list, button)
  end

  local i
  for i = 1, table.getn(known) do
    Take(U.G(name .. known[i]))
  end

  if frame.GetChildren then
    local ok, children = pcall(function() return { frame:GetChildren() } end)
    if ok and type(children) == "table" then
      for i = 1, table.getn(children) do
        local child = children[i]
        if child and child.GetObjectType then
          local typeOk, objectType = pcall(child.GetObjectType, child)
          if typeOk and objectType == "Button" then Take(child) end
        end
      end
    end
  end

  -- Left to right by role, not by the x the client happened to give them.
  -- Sorting on position alone put Greed before Need; the row is meant to read
  -- Need, Greed, Pass. A button whose name matches none of these keeps its
  -- relative position after the known ones, ordered among themselves by x.
  --
  -- Never nil, so the comparison cannot fault on a build where GetLeft reports
  -- nothing; those keep the order they were collected in.
  local order = {}
  for i = 1, table.getn(list) do
    local rank = 4
    local suffix = NameOf(list[i])
    if suffix then
      suffix = string.gsub(suffix, "^" .. name, "")
      rank = BUTTON_ORDER[suffix] or 4
    end

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
  -- Placed right to left, so the row ends flush with the card's right edge and
  -- reads in collected order left to right.
  local i
  for i = count, 1, -1 do
    local button = list[i]
    pcall(button.SetWidth, button, BTN)
    pcall(button.SetHeight, button, BTN)
    -- The dice / coin / pass glyphs ARE these buttons' stock textures, so the
    -- art is kept -- it is the only thing telling one roll button from another.
    -- It does have to be pinned to the button, though: the stock art keeps its
    -- own larger size when the button is resized.
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
    previous = button
  end
  return count
end

local function StyleName(name, frame, icon, buttonCount, quality)
  local label = U.G(name .. "Name")
  if not label then return end

  local color = (quality and U.ItemQualityColor(quality)) or M.color.text
  U.SetStockFont(label, M.fontSize.normal, color)

  -- fonts.stretched_justification_ignored: one anchor plus an explicit width,
  -- never a corner-to-corner stretch. The height is pinned to one line as well:
  -- a FontString given a width wraps, and this card has room for one line.
  pcall(function()
    label:ClearAllPoints()
    label:SetPoint("LEFT", icon or frame, icon and "RIGHT" or "LEFT",
                   icon and NAME_GAP or PAD, 0)
    label:SetWidth(NameWidth(buttonCount))
    label:SetHeight(M.fontSize.normal + 4)
  end)
  pcall(label.SetJustifyH, label, "LEFT")
  if label.SetJustifyV then pcall(label.SetJustifyV, label, "CENTER") end
end

-- The bar is the client's own StatusBar and stays that: its value is driven by
-- the native OnUpdate. modules/tooltip.lua's StyleStatusBar is the precedent
-- for not stripping a native bar -- U.HideRegion is permanent, and the fill is
-- itself a region, so a strip here would leave a bar that can never draw again.
local function StyleTimer(name, frame)
  local bar = U.G(name .. "Timer")
  if not bar then return end

  -- The bar's own stock art. QtUiPlusDiagDB.rollAuto caught a 156x20
  -- UI-Character-Skills-BarBorder still drawing on this StatusBar, anchored
  -- above it -- stock chrome the flat card should not carry. The fill itself is
  -- a region too and must survive, so regions are judged by their texture path:
  -- the plain white QtUiPlus draws with stays, anything else goes.
  if bar.GetRegions then
    local ok, regions = pcall(function() return { bar:GetRegions() } end)
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
  pcall(bar.SetStatusBarTexture, bar, M.texture.plain)
  pcall(bar.SetStatusBarColor, bar, M.Unpack(M.color.accent))
  U.CreateBackdrop(bar, { background = M.color.healthBg, border = false })
  pcall(bar.SetBackdropBorderColor, bar, 0, 0, 0, 0)
  pcall(function()
    bar:ClearAllPoints()
    bar:SetHeight(BAR_H)
    bar:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 1, 1)
    bar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
  end)
end

-- USER_CONFIRMED_INGAME: the item name draws twice -- once in $parentName (the
-- one styled below, confirmed by its quality colour landing on it) and once in
-- white above the card. U.StripStockTextures only takes Textures, so the second
-- label survived it, and fading every other FontString on the frame did not
-- reach it either -- it is not one of the frame's own regions.
--
-- So the duplicate is matched on what it says rather than on where it lives:
-- any FontString on the frame or one level into its children whose text is the
-- item name, and which is not the label being styled, is the duplicate. Nothing
-- else on this card carries the item name, so a stack count or a timer readout
-- cannot be caught by mistake. Alpha rather than Hide, since the client
-- re-shows its own regions when the frame is reused for the next roll.
local function FadeMatchingLabels(owner, keep, text)
  if not owner or not owner.GetRegions or type(text) ~= "string" then return end
  local ok, regions = pcall(function() return { owner:GetRegions() } end)
  if not ok or type(regions) ~= "table" then return end
  local i
  for i = 1, table.getn(regions) do
    local region = regions[i]
    if region and region ~= keep and region.GetObjectType and region.GetText then
      local typeOk, objectType = pcall(region.GetObjectType, region)
      if typeOk and objectType == "FontString" then
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

-- A roll window is on screen for seconds, which makes "run this command while
-- it is up" a poor way to collect evidence about it -- one missed step and the
-- window is gone. Each roll therefore records its own snapshot into
-- QtUiPlusDiagDB.rollAuto, so the file holds the last few rolls after any
-- reload with nothing typed. U.AppendDiagnostic caps the list, so this cannot
-- grow the SavedVariables file without bound.
local function Rect(object)
  if not object or type(object.GetLeft) ~= "function" then return nil end
  local ok, left = pcall(object.GetLeft, object)
  if not ok or not tonumber(left) then return nil end
  local okR, right = pcall(object.GetRight, object)
  local okT, top = pcall(object.GetTop, object)
  local okB, bottom = pcall(object.GetBottom, object)
  if not okR or not okT or not okB then return nil end
  if not tonumber(right) or not tonumber(top) or not tonumber(bottom) then
    return nil
  end
  return { left = left, right = right, top = top, bottom = bottom }
end

local function Overlaps(a, b)
  if not a or not b then return false end
  if a.right <= b.left or a.left >= b.right then return false end
  if a.top <= b.bottom or a.bottom >= b.top then return false end
  return true
end

local function Line(object, label, rect)
  local function Try(method)
    if type(object[method]) ~= "function" then return nil end
    local ok, value = pcall(object[method], object)
    if not ok then return nil end
    return value
  end
  local line = label .. " " .. tostring(Try("GetName") or "<unnamed>") ..
               " [" .. tostring(Try("GetObjectType") or "?") .. "]" ..
               " " .. tostring(math.floor(rect.left)) .. "," ..
               tostring(math.floor(rect.bottom)) .. " " ..
               tostring(math.floor(rect.right - rect.left)) .. "x" ..
               tostring(math.floor(rect.top - rect.bottom))
  local text = Try("GetText")
  if type(text) == "string" and text ~= "" then
    line = line .. ' text="' .. text .. '"'
  end
  local parent = Try("GetParent")
  if parent then
    local okName, parentName = pcall(function() return parent:GetName() end)
    line = line .. " parent=" ..
           tostring((okName and parentName) or "<unnamed>")
  end
  return line
end

-- What is drawn on top of the card, named.
--
-- The bar with the health readout is USER_CONFIRMED_INGAME to be in the roll
-- window, and moving the card takes the bar with it, so it is not a nameplate
-- floating over a unit and not one of the unit frames -- every saved mover
-- position is on the other side of the screen. Four dumps failed to name it for
-- one reason: each re-fetched the frame through U.G and read it as hidden, so
-- the window was never captured live.
--
-- This records geometry instead of hierarchy. The card's own rect is taken from
-- the frame object Skin was handed -- never re-fetched by name, since identity
-- through U.G is exactly what cannot be trusted here -- and everything shown
-- that overlaps that rect is written down with its name, type, rect, text and
-- parent. Whatever the bar is, it overlaps the card by definition, so it cannot
-- stay anonymous.
local function RecordDump(frame)
  if type(U.AppendDiagnostic) ~= "function" then return end
  if not frame or not frame.IsShown then return end
  local shownOk, shown = pcall(frame.IsShown, frame)
  if not shownOk or not shown then return end

  local card = Rect(frame)
  if not card then return end

  local lines = {}
  table.insert(lines, "card " .. tostring(math.floor(card.left)) .. "," ..
               tostring(math.floor(card.bottom)) .. " " ..
               tostring(math.floor(card.right - card.left)) .. "x" ..
               tostring(math.floor(card.top - card.bottom)))

  local function Consider(object, label)
    if not object then return end
    if type(object.IsShown) == "function" then
      local ok, isShown = pcall(object.IsShown, object)
      if ok and not isShown then return end
    end
    local rect = Rect(object)
    if not rect or not Overlaps(rect, card) then return end
    table.insert(lines, Line(object, label, rect))
  end

  -- Depth 2 from each root, plus the card's own tree.
  local function Walk(root, label, depth)
    if not root or depth > 2 then return end
    local ok, children = pcall(function() return { root:GetChildren() } end)
    if ok and type(children) == "table" then
      local i
      for i = 1, table.getn(children) do
        Consider(children[i], label)
        Walk(children[i], label .. ">", depth + 1)
      end
    end
    local okR, regions = pcall(function() return { root:GetRegions() } end)
    if okR and type(regions) == "table" then
      local i
      for i = 1, table.getn(regions) do
        Consider(regions[i], label .. "r")
      end
    end
  end

  Walk(frame, "card", 1)
  Walk(UIParent, "ui", 1)
  Walk(U.G("WorldFrame"), "world", 1)

  pcall(function() U.AppendDiagnostic("rollOverlap", lines) end)
end

local function Skin(name, index)
  local frame = U.G(name)
  if not frame then return end

  U.StripStockTextures(frame)
  pcall(frame.SetWidth, frame, CARD_W)
  pcall(frame.SetHeight, frame, CARD_H)
  U.CreateBackdrop(frame, {
    -- Opaque, unlike the usual 0.85 panel fill: this window opens over the
    -- world and over whatever the interface is already drawing, and a roll has
    -- a timer on it -- it has to be readable at a glance, not tinted by
    -- whatever happens to sit behind it.
    background = { 0.05, 0.05, 0.05, 0.96 },
    border = M.color.border,
  })
  -- A roll expires on its own, so it must not end up behind anything. DIALOG
  -- was not enough: USER_CONFIRMED_INGAME the target nameplate still drew over
  -- the card, so whatever layer this client gives nameplates outranks the one
  -- game panels use. FULLSCREEN_DIALOG clears that and still leaves tooltips on
  -- top, which is the one thing that should be able to cover a roll.
  U.RaiseGamePanel(frame, "FULLSCREEN_DIALOG")

  -- Stacked down from the mover, one slot per frame index.
  local host = BuildAnchor()
  if host and index then
    pcall(function()
      frame:ClearAllPoints()
      frame:SetPoint("TOP", host, "TOP", 0, -(index - 1) * (CARD_H + STACK_GAP))
    end)
  end

  local quality, itemName = RollItem(frame)
  local icon = StyleIcon(name, quality)
  local buttonCount = StyleButtons(name, frame)
  StyleName(name, frame, icon, buttonCount, quality)
  StyleTimer(name, frame)
  HideDuplicateName(frame, U.G(name .. "Name"), itemName)
  RecordDump(frame)
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
        -- Every roll reuses these four frames with new content, so the skin is
        -- re-applied per show rather than once: the item, and with it the
        -- quality colour, is different each time.
        if U.PostHookScript(frame, "OnShow", function() Skin(name, i) end) then
          frame.qtpLootRollHooked = true
        end
      end
      Skin(name, i)
    end
  end
  return attached
end

function LR:OnEnable()
  BuildAnchor()
  if Attach() then return end

  U.RegisterEvent("ADDON_LOADED", Attach)
  U.RegisterEvent("PLAYER_ENTERING_WORLD", Attach)
  U.RegisterEvent("START_LOOT_ROLL", Attach)
end
