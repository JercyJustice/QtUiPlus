-- QtUiPlus :: modules/minimap.lua
--
-- A settings button beside the native minimap, a mover for the minimap
-- cluster, and dummy anchors so the stock minimap buff/debuff rows can be
-- placed in Anchor Mode.
--
-- The native minimap is kept as it is: no replacement, no reskin, no chrome
-- suppression. knowledge.json / minimap.render_pass_under_ordinary_frames says
-- the map surface is drawn in a special pass beneath ordinary frames, which is
-- also why the button is placed *outside* the map rather than over it -- an
-- ordinary frame on top of the map would cover it.
--
-- The mover targets MinimapCluster rather than bare Minimap: behavior.json /
-- minimap.context.frames.MinimapCluster confirms it holds the map's native
-- chrome (zone text, etc.) and defaults to TOPRIGHT UIParent TOPRIGHT 0,0 with
-- no pfUI involvement, so moving the cluster keeps that chrome attached and
-- the registration's own default matches where the client already puts it.
-- The settings button stays anchored to Minimap itself, so it keeps tracking
-- correctly without any extra work when the cluster moves.

local U = QtUiPlus
local M = U.media

local MM = U.RegisterModule("minimap")

local BUTTON_SIZE = 24

-- Anchored to the map's left edge so it never lands on the map surface or on
-- the stock chrome hanging off the right side.
local function AnchorButton(button)
  local minimap = U.G("Minimap")
  if minimap then
    button:SetPoint("TOPRIGHT", minimap, "TOPLEFT", -6, 0)
    return "Minimap"
  end

  local cluster = U.G("MinimapCluster")
  if cluster then
    button:SetPoint("TOPRIGHT", cluster, "TOPLEFT", -6, -6)
    return "MinimapCluster"
  end

  -- No minimap to sit beside: park it in the corner rather than not existing.
  button:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -8, -8)
  return "UIParent (no minimap found)"
end

-- MinimapCluster is preferred: it is the whole native unit (map plus its
-- attached chrome) and its default anchor is measured. A bare Minimap fallback
-- carries no default -- its own point is only known from a pfUI-influenced
-- snapshot, not trustworthy as this client's un-modded native anchor -- so
-- Reset simply leaves it wherever it already is in that rare case.
local function ResolveMoverTarget()
  local cluster = U.G("MinimapCluster")
  if cluster then
    return cluster, "MinimapCluster",
      { point = "TOPRIGHT", relativePoint = "TOPRIGHT", x = 0, y = 0 }
  end

  local minimap = U.G("Minimap")
  if minimap then return minimap, "Minimap", nil end

  return nil
end

local function RegisterMinimapMover()
  local target, name, default = ResolveMoverTarget()
  if not target then
    U.Debug("minimap: no MinimapCluster or Minimap to register as a mover")
    return
  end

  U.RegisterMover("minimap", target, { label = "Minimap", default = default })
  U.Debug("minimap mover registered on " .. name)
end

-- Native BuffFrame / DebuffButton row sit next to the minimap. They are not
-- QtUiPlus-owned, so dummy anchors are the mover targets and the stock frames
-- are glued to them after every aura update (the client re-points BuffFrame
-- back to MinimapCluster).
local BUFF_ANCHOR_W = 200
local BUFF_ANCHOR_H = 36
local buffAnchor
local debuffAnchor

local function Glue(frame, point, relative, relativePoint, x, y)
  if not frame or not relative then return end
  pcall(frame.ClearAllPoints, frame)
  pcall(frame.SetPoint, frame, point, relative, relativePoint, x or 0, y or 0)
end

local function GlueMinimapAuras()
  if buffAnchor then
    Glue(U.G("BuffFrame"), "TOPRIGHT", buffAnchor, "TOPRIGHT", 0, 0)
    local enchant = U.G("TemporaryEnchantFrame")
    if enchant then
      local parentOk, parent = pcall(enchant.GetParent, enchant)
      -- Already a BuffFrame child: it rides the buffs mover. Independent
      -- otherwise, so park it on the same anchor rather than leaving it
      -- stuck to the minimap.
      if not parentOk or parent ~= U.G("BuffFrame") then
        Glue(enchant, "TOPRIGHT", buffAnchor, "TOPRIGHT", 0, 0)
      end
    end
  end
  if debuffAnchor then
    local row = U.G("DebuffFrame")
    if not row then row = U.G("DebuffButton1") end
    Glue(row, "TOPRIGHT", debuffAnchor, "TOPRIGHT", 0, 0)
  end
end

local function RegisterMinimapAuraMovers()
  if buffAnchor then return end

  -- Vanilla cluster is TOPRIGHT 0,0; buffs sit to its left.
  buffAnchor = CreateFrame("Frame", "QtUiPlusMinimapBuffs", UIParent)
  buffAnchor:SetWidth(BUFF_ANCHOR_W)
  buffAnchor:SetHeight(BUFF_ANCHOR_H)
  pcall(buffAnchor.EnableMouse, buffAnchor, false)
  pcall(buffAnchor.SetFrameStrata, buffAnchor, "MEDIUM")
  U.RegisterMover("minimapBuffs", buffAnchor, {
    label = "Minimap Buffs",
    default = { point = "TOPRIGHT", relativePoint = "TOPRIGHT", x = -220, y = -12 },
  })

  debuffAnchor = CreateFrame("Frame", "QtUiPlusMinimapDebuffs", UIParent)
  debuffAnchor:SetWidth(BUFF_ANCHOR_W)
  debuffAnchor:SetHeight(BUFF_ANCHOR_H)
  pcall(debuffAnchor.EnableMouse, debuffAnchor, false)
  pcall(debuffAnchor.SetFrameStrata, debuffAnchor, "MEDIUM")
  U.RegisterMover("minimapDebuffs", debuffAnchor, {
    label = "Minimap Debuffs",
    default = { point = "TOPRIGHT", relativePoint = "TOPRIGHT", x = -220, y = -90 },
  })

  GlueMinimapAuras()

  local function QueueGlue()
    if type(U.DeferOnce) == "function" then
      U.DeferOnce("minimap.aura-glue", GlueMinimapAuras)
    else
      GlueMinimapAuras()
    end
  end
  U.RegisterEvent("PLAYER_AURAS_CHANGED", QueueGlue)
  U.RegisterEvent("UNIT_AURA", function(event, unit)
    if unit and unit ~= "player" then return end
    QueueGlue()
  end)
  U.RegisterEvent("PLAYER_ENTERING_WORLD", QueueGlue)

  local buffFrame = U.G("BuffFrame")
  if buffFrame and type(U.PostHookScript) == "function" then
    U.PostHookScript(buffFrame, "OnShow", QueueGlue)
  end
  if type(U.RegisterUpdate) == "function" then
    U.RegisterUpdate("minimap.aura-glue", 0.25, GlueMinimapAuras)
  end
end

-- Applies the current enabled state to an already-created button. Public so
-- modules/settings.lua's General page can flip the checkbox without reaching
-- into this module's internals.
local function Apply()
  local button = MM.button
  if not button then return end

  if U.ModuleConfig("minimap", { enabled = true }).enabled then
    button:Show()
    if button.label then button.label:Show() end
  else
    button:Hide()
  end
end
U.ApplyMinimapButton = Apply

function MM:OnEnable()
  if self.button then return end

  local button = U.CreateButton(UIParent, {
    name = "QtUiPlusSettingsButton",
    width = BUTTON_SIZE,
    height = BUTTON_SIZE,
    text = "",
    onClick = function()
      if type(U.OpenSettings) == "function" then U.OpenSettings() end
    end,
  })

  local border = U.BorderSize()
  local icon = button:CreateTexture(nil, "ARTWORK")
  icon:SetPoint("TOPLEFT", button, "TOPLEFT", border, -border)
  icon:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -border, border)

  -- A stock icon path. Nothing in the compact DB covers Interface\ICONS on this
  -- client, so if the call is rejected the button falls back to its own label
  -- rather than showing an empty square.
  local applied = pcall(icon.SetTexture, icon, "Interface\\ICONS\\INV_Misc_Gear_01")
  if applied then
    pcall(icon.SetTexCoord, icon, 0.08, 0.92, 0.08, 0.92)
  else
    icon:Hide()
    if button.label then button.label:SetText("UI") end
  end
  button.icon = icon

  local anchor = AnchorButton(button)

  self.button = button
  Apply()
  U.Debug("settings button anchored to " .. anchor)

  RegisterMinimapMover()
  RegisterMinimapAuraMovers()
end
