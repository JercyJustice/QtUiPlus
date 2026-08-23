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
    if frame then U.KeepPanelInFront(frame, "HIGH") end
  end
end

local function RaiseLoot()
  local i
  for i = 1, table.getn(LOOT_NAMES) do
    local frame = U.G(LOOT_NAMES[i])
    if frame then U.RaiseGamePanel(frame, "HIGH") end
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

  if type(U.PostHookGlobal) == "function" then
    U.PostHookGlobal("ShowUIPanel", function(frame)
      if not frame or IsMapPanel(frame) then return end
      local name
      if frame.GetName then
        local ok, value = pcall(frame.GetName, frame)
        if ok then name = value end
      end
      local strata = "DIALOG"
      if name == "LootFrame" or (name and string.find(name, "GroupLootFrame", 1, true)) then
        strata = "HIGH"
      end
      U.KeepPanelInFront(frame, strata)
      U.RaiseGamePanel(frame, strata)
    end)
  end

  U.RegisterEvent("ADDON_LOADED", function() HookNamedPanels() end)
  U.RegisterEvent("PLAYER_ENTERING_WORLD", function() HookNamedPanels() end)
  U.RegisterEvent("LOOT_OPENED", RaiseLoot)
  U.RegisterEvent("LOOT_SLOT_CLEARED", RaiseLoot)
end
