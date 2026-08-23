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

-- The frame's own size is left alone. Multiple rolls stack, and the client owns
-- where each frame sits; resizing them here would be QtUiPlus deciding the
-- spacing of a layout it does not drive. Everything below anchors to the
-- frame's edges instead, so the card is correct at whatever size it arrives.

local function Quality(frame)
  local rollID = frame and frame.rollID
  if not rollID then return nil end
  local info = U.G("GetLootRollItemInfo")
  if type(info) ~= "function" then return nil end
  local ok, _, _, _, quality = pcall(info, rollID)
  if not ok then return nil end
  return tonumber(quality)
end

local function StyleIcon(name, quality)
  local icon = U.G(name .. "IconFrame")
  if not icon then return nil end
  -- Same flat treatment as a bag slot, including keeping the item texture and
  -- cropping its border away.
  U.StyleItemSlot(icon, name .. "IconFrame")
  pcall(icon.SetWidth, icon, ICON)
  pcall(icon.SetHeight, icon, ICON)
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

-- Right to left: Pass sits on the frame's right edge, so the row reads
-- Need / Greed / Pass left to right, the order retail uses.
local function StyleButtons(name, frame)
  local order = { "PassButton", "GreedButton", "NeedButton" }
  local previous
  local i
  for i = 1, table.getn(order) do
    local button = U.G(name .. order[i])
    if button then
      pcall(button.SetWidth, button, BTN)
      pcall(button.SetHeight, button, BTN)
      -- The dice / coin / pass glyphs ARE this button's stock normal texture,
      -- so the art is deliberately left alone -- it is the only thing telling
      -- one roll button from another. Only a flat plate is added behind it.
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
  end
  -- The leftmost button that resolved; the name text stops short of it.
  return previous
end

local function StyleName(name, frame, icon, leftmostButton, quality)
  local label = U.G(name .. "Name")
  if not label then return end

  local color = (quality and U.ItemQualityColor(quality)) or M.color.text
  U.SetStockFont(label, M.fontSize.normal, color)

  -- fonts.stretched_justification_ignored: one anchor plus an explicit width,
  -- never a corner-to-corner stretch.
  local width = 120
  local fw
  if frame.GetWidth then
    local ok, value = pcall(frame.GetWidth, frame)
    if ok then fw = tonumber(value) end
  end
  if fw then
    width = fw - PAD - ICON - NAME_GAP - PAD
    if leftmostButton then
      width = width - (BTN * 3 + BTN_GAP * 2 + NAME_GAP)
    end
    if width < 40 then width = 40 end
  end

  pcall(function()
    label:ClearAllPoints()
    label:SetPoint("LEFT", icon or frame, icon and "RIGHT" or "LEFT",
                   icon and NAME_GAP or PAD, 0)
    label:SetWidth(width)
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

local function Skin(name)
  local frame = U.G(name)
  if not frame then return end

  U.StripStockTextures(frame)
  U.CreateBackdrop(frame, {
    -- Opaque, unlike the usual 0.85 panel fill: this window opens over the
    -- world and over whatever the interface is already drawing, and a roll has
    -- a timer on it -- it has to be readable at a glance, not tinted by
    -- whatever happens to sit behind it.
    background = { 0.05, 0.05, 0.05, 0.96 },
    border = M.color.border,
  })
  -- Above the game panels: a roll expires on its own, so it must not end up
  -- behind a bag or the character sheet that happens to be open.
  U.RaiseGamePanel(frame, "DIALOG")

  local quality = Quality(frame)
  local icon = StyleIcon(name, quality)
  local leftmost = StyleButtons(name, frame)
  StyleName(name, frame, icon, leftmost, quality)
  StyleTimer(name, frame)
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
        if U.PostHookScript(frame, "OnShow", function() Skin(name) end) then
          frame.qtpLootRollHooked = true
        end
      end
      Skin(name)
    end
  end
  return attached
end

function LR:OnEnable()
  if Attach() then return end

  U.RegisterEvent("ADDON_LOADED", Attach)
  U.RegisterEvent("PLAYER_ENTERING_WORLD", Attach)
  U.RegisterEvent("START_LOOT_ROLL", Attach)
end
