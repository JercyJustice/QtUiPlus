-- QtUiPlus :: modules/profiles.lua
--
-- The Profiles settings page. The profiles themselves live in core/config.lua,
-- because a profile *is* the live config -- U.db and the QtUI layout store both
-- point into the active one -- and that ownership belongs next to the store,
-- not in a settings page. This file is only the frontend.
--
-- What a profile holds and where it lives is documented in core/config.lua.
-- The two facts that shape this page:
--
--   * Profiles are account-wide and a character stores only the name of the one
--     it uses, so selecting a profile here changes what every character
--     assigned to it sees. The page says which profile is active and never
--     offers to delete a profile another character still points at.
--   * Creating a profile cannot ask for a name. This client crashes when an
--     addon-created EditBox takes focus, so the Create button generates one
--     (U.NextProfileName) and /qtp profile create <name> is the route to a
--     custom one. The hint below says so rather than leaving it undiscoverable.
--
-- Positions are rescaled when a profile laid out at another resolution is
-- selected; that happens in core/config.lua on the way in, so nothing here has
-- to know about it.

local U = QtUiPlus
local M = U.media

local P = U.RegisterModule("profiles")

local PAGE_ROWS = 6

local function BuildSettingsPage(parent)
  local widgets, rows = {}, {}

  local header = U.CreateSectionHeader(parent, {
    text = "Profiles", width = 484, y = -4,
  })
  table.insert(widgets, header)

  local Refresh
  local active

  -- Why every profile action offers an immediate reload
  --
  -- Switching a profile repoints U.db at the new table, but modules capture
  -- their own settings table once in OnInit and keep that reference. After a
  -- switch those two disagree, and the disagreement is not merely cosmetic:
  -- settings pages that write through U.ModuleConfig resolve fresh and land in
  -- the NEW profile, while the ones writing through a module cached cfg
  -- (modules/nameplates.lua, modules/actionbar.lua and the other cachers) land
  -- in the OLD one. Changing anything between the switch and the reload would
  -- therefore split the change across two profiles.
  --
  -- Rebuilding every module on a live switch is the alternative, and it is a
  -- much larger change than the feature warrants. Making the reload the
  -- offered default closes the window instead.
  local function PromptReload(verb, name)
    U.Print(verb .. " profile |cffffff00" .. name ..
            "|r - reload to apply it everywhere")

    local function Reload()
      local fn = U.G("ReloadUI")
      if type(fn) == "function" then pcall(fn) end
    end

    if type(U.ShowConfirm) ~= "function" then
      U.Print("run |cffffff00/reload|r before changing any more settings")
      return
    end

    U.ShowConfirm({
      owner = "profile-reload",
      text = "Reload the UI now?",
      detail = "The profile is only fully applied after a reload. Settings " ..
               "changed before then can land in the previous profile.",
      acceptText = "Reload",
      cancelText = "Later",
      onAccept = Reload,
    })
  end

  active = U.CreateSettingsLabel(parent, {
    size = M.fontSize.normal, color = M.color.textAccent,
    inherits = "GameFontNormal", justify = "LEFT", width = 460,
  })
  if active then
    active:SetPoint("TOPLEFT", parent, "TOPLEFT", 4, -34)
    table.insert(widgets, active)
  end

  local create = U.CreateButton(parent, {
    name = "QtUiPlusProfilesCreate",
    text = "Create a new profile",
    width = 200,
    height = 26,
    onClick = function()
      local ok, result = U.CreateProfile(U.NextProfileName(), false)
      if ok then
        U.Print("created profile |cffffff00" .. result ..
                "|r - use Select to switch to it")
      else
        U.Print("could not create: " .. tostring(result))
      end
      if Refresh then Refresh() end
    end,
  })
  create:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -60)
  table.insert(widgets, create)

  local reset = U.CreateButton(parent, {
    name = "QtUiPlusProfilesReset",
    text = "Reset this profile",
    width = 200,
    height = 26,
    onClick = function()
      if type(U.ShowConfirm) ~= "function" then
        local ok, result = U.ResetCurrentProfile()
        if ok then PromptReload("reset", result) end
        if Refresh then Refresh() end
        return
      end
      U.ShowConfirm({
        owner = "profile-reset",
        text = "Reset " .. U.GetCurrentProfileName() .. "?",
        detail = "Every setting and frame position in this profile returns " ..
                 "to its default. Other profiles are untouched.",
        acceptText = "Reset",
        cancelText = "Cancel",
        onAccept = function()
          local ok, result = U.ResetCurrentProfile()
          if ok then
            PromptReload("reset", result)
          else
            U.Print("could not reset: " .. tostring(result))
          end
          if Refresh then Refresh() end
        end,
      })
    end,
  })
  reset:SetPoint("TOPLEFT", parent, "TOPLEFT", 220, -60)
  table.insert(widgets, reset)

  -- One row per other profile: select it, or copy it into the active one.
  local i
  for i = 1, PAGE_ROWS do
    local row = {}
    local y = -100 - (i - 1) * 30

    row.label = U.CreateSettingsLabel(parent, {
      size = M.fontSize.normal, color = M.color.text,
      inherits = "GameFontNormal", justify = "LEFT", width = 190,
    })
    if row.label then
      row.label:SetPoint("TOPLEFT", parent, "TOPLEFT", 4, y - 6)
      table.insert(widgets, row.label)
    end

    row.select = U.CreateButton(parent, {
      name = "QtUiPlusProfilesSelect" .. i,
      text = "Select",
      width = 80, height = 22,
      onClick = function()
        if not row.name then return end
        local ok, result = U.SelectProfile(row.name)
        if ok then
          PromptReload("selected", result)
        else
          U.Print("could not select: " .. tostring(result))
        end
        if Refresh then Refresh() end
      end,
    })
    row.select:SetPoint("TOPLEFT", parent, "TOPLEFT", 200, y)
    table.insert(widgets, row.select)

    row.copy = U.CreateButton(parent, {
      name = "QtUiPlusProfilesCopy" .. i,
      text = "Copy in",
      width = 80, height = 22,
      onClick = function()
        if not row.name then return end
        local ok, result = U.CopyProfile(row.name)
        if ok then
          PromptReload("copied " .. result .. " into", U.GetCurrentProfileName())
        else
          U.Print("could not copy: " .. tostring(result))
        end
        if Refresh then Refresh() end
      end,
    })
    row.copy:SetPoint("TOPLEFT", parent, "TOPLEFT", 290, y)
    table.insert(widgets, row.copy)

    row.delete = U.CreateButton(parent, {
      name = "QtUiPlusProfilesDelete" .. i,
      text = "Delete",
      width = 80, height = 22,
      onClick = function()
        if not row.name then return end
        local ok, result = U.DeleteProfile(row.name)
        if ok then
          U.Print("deleted profile |cffffff00" .. result .. "|r")
        else
          U.Print("could not delete: " .. tostring(result))
        end
        if Refresh then Refresh() end
      end,
    })
    row.delete:SetPoint("TOPLEFT", parent, "TOPLEFT", 380, y)
    table.insert(widgets, row.delete)

    rows[i] = row
  end

  local hint = U.CreateSettingsLabel(parent, {
    size = M.fontSize.small, color = M.color.textDim,
    inherits = "GameFontNormalSmall", justify = "LEFT", width = 470,
  })
  if hint then
    hint:SetPoint("TOPLEFT", parent, "TOPLEFT", 4, -100 - PAGE_ROWS * 30 - 10)
    hint:SetText("Profiles are shared across the account; each character " ..
                 "remembers which one it uses. Select switches this character " ..
                 "to a profile, Copy in overwrites the active profile with " ..
                 "another one. Use |cffffff00/qtp profile create <name>|r to " ..
                 "name a profile yourself.")
    table.insert(widgets, hint)
  end

  Refresh = function()
    if active then
      active:SetText("Active profile: " .. U.GetCurrentProfileName())
    end

    -- The active profile is excluded: its row would offer to select what is
    -- already selected and to copy it into itself.
    local names = U.GetProfileNames(true)
    local deletable, lookup, j = U.GetDeletableProfileNames(), {}, nil
    for j = 1, table.getn(deletable) do lookup[deletable[j]] = true end

    for j = 1, PAGE_ROWS do
      local row = rows[j]
      row.name = names[j]

      if row.name then
        if row.label then
          row.label:SetText(row.name)
          row.label:Show()
        end
        row.select:Show()
        row.copy:Show()
        -- Shown but disabled would need a disabled state this button set does
        -- not have; a profile another character uses simply has no Delete.
        if lookup[row.name] then row.delete:Show() else row.delete:Hide() end
      else
        if row.label then row.label:Hide() end
        row.select:Hide()
        row.copy:Hide()
        row.delete:Hide()
      end
    end
  end

  return widgets, Refresh
end

function P:OnInit()
  if type(U.RegisterSettingsTab) == "function" then
    U.RegisterSettingsTab("profiles", "Profiles", BuildSettingsPage)
  end
end
