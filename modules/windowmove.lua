-- QtUiPlus :: modules/windowmove.lua
--
-- Wires U.MakeWindowDraggable (core/windowdrag.lua) onto native windows that
-- QtUiPlus does not otherwise skin, so they can be repositioned by their
-- header the same way the Quest Log and Spellbook are. Native close buttons
-- here are the unstyled ~32px stock ones, so the header strip reserves more
-- room on the right than the restyled 17px close buttons in questlog.lua /
-- spellbook.lua need.
--
-- WorldMapFrame is not registered here: it needs the fullscreen panel layout
-- undone before a header drag means anything, so modules/worldmap.lua owns
-- both that and its own U.MakeWindowDraggable call.
--
-- Also keeps game windows (paperdoll, bags, quest log, loot, ...) on DIALOG
-- above the HUD. Loot uses HIGH so it cannot sit behind an open bag.

local U = QtUiPlus
local WM = U.RegisterModule("windowmove")

local WINDOWS = {
  { id = "character", frame = "CharacterFrame" },
  { id = "friends", frame = "FriendsFrame" },
}

-- Native (and QtUiPlus-owned) panels that must open in front of unit frames
-- and action bars. World map is excluded: demoting it from FULLSCREEN breaks
-- pfQuest pins parented to WorldMapButton.
local PANEL_NAMES = {
  "CharacterFrame", "PaperDollFrame", "ReputationFrame", "SkillFrame", "HonorFrame",
  "PetPaperDollFrame", "TradeFrame", "MailFrame", "SendMailFrame", "OpenMailFrame",
  "AuctionFrame", "CraftFrame", "TradeSkillFrame", "ClassTrainerFrame",
  "MerchantFrame", "GossipFrame", "QuestFrame", "QuestLogFrame",
  "TaxiFrame", "InspectFrame", "TalentFrame", "SpellBookFrame", "FriendsFrame",
  "GuildFrame", "WhoFrame", "PetitionFrame", "TabardFrame", "PetStableFrame",
  "DressUpFrame", "ItemTextFrame", "BattlefieldFrame",
  "MacroFrame", "KeyBindingFrame", "GameMenuFrame", "OptionsFrame",
  "SoundOptionsFrame", "UIOptionsFrame", "HelpFrame", "ColorPickerFrame",
  "StaticPopup1", "StaticPopup2", "StaticPopup3", "StaticPopup4",
  "QtUiPlusBagFrame", "QtUiPlusBankFrame",
}

local LOOT_NAMES = {
  "LootFrame",
  "GroupLootFrame1", "GroupLootFrame2", "GroupLootFrame3", "GroupLootFrame4",
}

local function IsMapPanel(frame)
  if not frame or not frame.GetName then return false end
  local ok, name = pcall(frame.GetName, frame)
  if not ok or type(name) ~= "string" then return false end
  if string.find(name, "WorldMap", 1, true) then return true end
  if string.find(name, "BattlefieldMinimap", 1, true) then return true end
  return false
end

local function HookNamedPanels()
  local i
  for i = 1, table.getn(PANEL_NAMES) do
    local frame = U.G(PANEL_NAMES[i])
    if frame then U.KeepPanelInFront(frame, "DIALOG") end
  end
  for i = 1, table.getn(LOOT_NAMES) do
    local frame = U.G(LOOT_NAMES[i])
    local strata = "HIGH"
    -- Nameplates still draw over HIGH. The roll card uses FULLSCREEN_DIALOG
    -- so the target plate cannot sit inside it.
    if string.find(LOOT_NAMES[i], "GroupLootFrame", 1, true) then
      strata = "FULLSCREEN_DIALOG"
    end
    if frame then U.KeepPanelInFront(frame, strata) end
  end
end

-- ---------------------------------------------------------------------------
-- Loot roll windows
--
-- Placement only. The compact card (size, chrome, Need/Greed/Pass row) is
-- modules/lootroll.lua -- this client's stock GroupLootFrame is a tall window
-- whose GetWidth/GetHeight must not size the mover, or Anchor Mode draws a
-- handle as tall as that native frame.
--
-- Hung off an invisible mover, stacked the way the client stacks them, so the
-- "Loot Roll" handle places all four. The mover id matches the one the earlier
-- skin used, so a saved position is picked up rather than orphaned.
-- ---------------------------------------------------------------------------
local ROLL_FRAMES = {
  "GroupLootFrame1", "GroupLootFrame2", "GroupLootFrame3", "GroupLootFrame4",
}
local ROLL_GAP = 6
local ROLL_MOVER_W = 300
local ROLL_MOVER_H = 48
local rollAnchor

local function BuildRollAnchor()
  if rollAnchor then return rollAnchor end
  if type(U.RegisterMover) ~= "function" then return nil end

  local frame = CreateFrame("Frame", "QtUiPlusLootRollAnchor", UIParent)
  frame:SetWidth(ROLL_MOVER_W)
  frame:SetHeight(ROLL_MOVER_H)
  pcall(frame.EnableMouse, frame, false)

  U.RegisterMover("lootroll.anchor", frame, {
    label = "Loot Roll",
    default = {
      point = "TOPLEFT",
      relativePoint = "TOPLEFT",
      x = 24,
      y = -160,
    },
  })

  rollAnchor = frame
  return frame
end

-- Frame 1 sits on the mover and each later one under its predecessor, which is
-- how the client stacks them anyway -- and it needs no height arithmetic, so
-- the stock frame's own size is never assumed.
local function PlaceRollFrame(frame, index)
  local host = BuildRollAnchor()
  if not host or not frame then return end
  pcall(function()
    frame:ClearAllPoints()
    local previous = index > 1 and U.G(ROLL_FRAMES[index - 1]) or nil
    if previous then
      frame:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -ROLL_GAP)
    else
      frame:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
    end
  end)
end

local function HookRollFrames()
  local i
  for i = 1, table.getn(ROLL_FRAMES) do
    local frame = U.G(ROLL_FRAMES[i])
    if frame then
      if not frame.qtpRollPlaced then
        local index = i
        -- The client positions the frame as it opens it, so the placement has
        -- to run after that, not once at load.
        if U.PostHookScript(frame, "OnShow", function()
             PlaceRollFrame(frame, index)
           end) then
          frame.qtpRollPlaced = true
        end
      end
      PlaceRollFrame(frame, i)
    end
  end
end

local function RaiseLoot()
  local i
  for i = 1, table.getn(LOOT_NAMES) do
    local frame = U.G(LOOT_NAMES[i])
    local strata = "HIGH"
    if string.find(LOOT_NAMES[i], "GroupLootFrame", 1, true) then
      strata = "FULLSCREEN_DIALOG"
    end
    if frame then U.RaiseGamePanel(frame, strata) end
  end
end

function WM:OnEnable()
  local i
  for i = 1, table.getn(WINDOWS) do
    local entry = WINDOWS[i]
    local frame = U.G(entry.frame)
    if frame then
      U.MakeWindowDraggable(entry.id, frame, { headerInset = 40 })
    else
      U.Debug("windowmove: " .. entry.frame .. " unavailable")
    end
  end

  HookNamedPanels()
  HookRollFrames()

  if type(U.PostHookGlobal) == "function" then
    U.PostHookGlobal("ShowUIPanel", function(frame)
      if not frame or IsMapPanel(frame) then return end
      local name
      if frame.GetName then
        local ok, value = pcall(frame.GetName, frame)
        if ok then name = value end
      end
      local strata = "DIALOG"
      if name == "LootFrame" then
        strata = "HIGH"
      elseif name and string.find(name, "GroupLootFrame", 1, true) then
        strata = "FULLSCREEN_DIALOG"
      end
      U.KeepPanelInFront(frame, strata)
      U.RaiseGamePanel(frame, strata)
    end)
  end

  U.RegisterEvent("ADDON_LOADED", function() HookNamedPanels() HookRollFrames() end)
  U.RegisterEvent("PLAYER_ENTERING_WORLD", function()
    HookNamedPanels()
    HookRollFrames()
  end)
  U.RegisterEvent("LOOT_OPENED", RaiseLoot)
  U.RegisterEvent("LOOT_SLOT_CLEARED", RaiseLoot)
end
