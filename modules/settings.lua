-- QtUiPlus :: modules/settings.lua
--
-- The settings window behind /qtp and the minimap button.
--
-- Layout follows the reference design: the addon name and version across the
-- top, a category list down the left side where a group can be collapsed to
-- hide its pages, and the selected page filling the rest. The accent colour
-- (#f5ae0a, core/media.lua) marks headings, groups and the selected row.
--
-- It is still not a config framework. There is no schema, no profile machinery
-- and no data binding: a module registers a page, builds its own controls with
-- core/widgets.lua, and owns its own values. This file only decides what is on
-- screen.
--
-- knowledge.json / rendering.parent_alpha_not_propagated: nothing here relies
-- on a parent's visibility reaching its children. Every region is toggled by
-- hand, which is what the per-page widget lists are for.

local U = QtUiPlus
local M = U.media

local S = U.RegisterModule("settings")

local PANEL_WIDTH = 700
local PANEL_HEIGHT = 600
local SIDEBAR_WIDTH = 168
local ROW_HEIGHT = 18
local ROW_GAP = 1
local HEADER_HEIGHT = 46
local FOOTER_HEIGHT = 46

local panel, sidebar, content
local sidebarView, contentView
local entries = {}     -- ordered: { kind, id, label, build, parent, expanded, ... }
local rows = {}        -- sidebar row button pool
local activePage       -- entry currently shown in the content area
local focusedId        -- id of the single row (page or expanded group, at any
                        -- depth) currently carrying the accent highlight

local RenderSidebar    -- forward declarations; rows and pages call each other
local SelectPage

-- ---------------------------------------------------------------------------
-- Visibility helpers
-- ---------------------------------------------------------------------------
local function SetShown(region, show)
  if not region then return end

  -- Composite controls from core/widgets.lua are a plain table of parts rather
  -- than a frame, so they are toggled through the list they carry.
  if region.qtpParts then
    local i
    for i = 1, table.getn(region.qtpParts) do
      SetShown(region.qtpParts[i], show)
    end
    return
  end

  if show then region:Show() else region:Hide() end
  if region.label then
    if show then region.label:Show() else region.label:Hide() end
  end
end

local function SetListShown(list, show)
  if type(list) ~= "table" then return end
  local i
  for i = 1, table.getn(list) do SetShown(list[i], show) end
end

-- ---------------------------------------------------------------------------
-- Registration
-- ---------------------------------------------------------------------------
local function FindEntry(id)
  local i
  for i = 1, table.getn(entries) do
    if entries[i].id == id then return entries[i], i end
  end
  return nil
end

-- A collapsible heading in the category list. Groups hold pages; they have no
-- content of their own and clicking one expands or collapses it.
function U.RegisterSettingsGroup(id, label)
  if type(id) ~= "string" then
    U.Error("RegisterSettingsGroup requires an id")
    return nil
  end
  if FindEntry(id) then
    U.Error("settings entry already registered: " .. id)
    return nil
  end

  local entry = {
    kind = "group",
    id = id,
    label = label or id,
    expanded = false,
  }
  table.insert(entries, entry)

  if panel then RenderSidebar() end
  return entry
end

-- id       stable key
-- label    row text
-- build    build(content) -> widgets[, refresh]
--          widgets is the array of regions shown with the page; refresh, when
--          returned, runs every time the page is opened.
-- options  { parent = "<group id>", after = "<entry id>", muted = true,
--            tooltip = "..." }.
--          Muted pages remain selectable so they can explain why their normal
--          controls are unavailable; only their sidebar presentation changes.
function U.RegisterSettingsTab(id, label, build, options)
  if type(id) ~= "string" or type(build) ~= "function" then
    U.Error("RegisterSettingsTab requires an id and a build function")
    return nil
  end
  if FindEntry(id) then
    U.Error("settings entry already registered: " .. id)
    return nil
  end

  options = options or {}

  local entry = {
    kind = "page",
    id = id,
    label = label or id,
    build = build,
    parent = options.parent,
    muted = options.muted and true or false,
    tooltip = options.tooltip,
  }
  local afterIndex
  if options.after then
    local _, index = FindEntry(options.after)
    afterIndex = index
  end
  if afterIndex then
    table.insert(entries, afterIndex + 1, entry)
  else
    table.insert(entries, entry)
  end

  if panel then RenderSidebar() end
  return entry
end

-- ---------------------------------------------------------------------------
-- Category list
--
-- Rows are a reused pool: expanding a group re-labels and re-points the rows it
-- needs and hides the rest, so collapsing never leaves an orphan button behind.
-- ---------------------------------------------------------------------------
local function VisibleEntries()
  local visible, i = {}, nil

  for i = 1, table.getn(entries) do
    local entry = entries[i]
    if entry.kind == "group" then
      table.insert(visible, entry)
    elseif not entry.parent then
      table.insert(visible, entry)
    else
      local parent = FindEntry(entry.parent)
      if parent and parent.expanded then table.insert(visible, entry) end
    end
  end

  return visible
end

-- Accordion behaviour: only one group (at any depth) stays expanded at a
-- time. Collapses every group except keepId, which future nested submenus
-- get for free since it only checks entry.kind, not depth or identity.
local function CollapseOtherGroups(keepId)
  local i
  for i = 1, table.getn(entries) do
    local entry = entries[i]
    if entry.kind == "group" and entry.id ~= keepId and entry.expanded then
      entry.expanded = false
      if focusedId == entry.id then focusedId = nil end
    end
  end
end

local function StyleRow(row, entry, selected)
  local text = entry.label
  local color = M.color.text

  if entry.kind == "group" then
    -- Groups read as headings: white text plus the expand indicator on the
    -- right, which is the only thing in the list that is not a page. Like a
    -- selected page, a focused (expanded) group switches to accent text.
    color = selected and M.color.accent or M.color.text
    if row.indicator then
      row.indicator:SetText(entry.expanded and "-" or "+")
      row.indicator:Show()
    end
  else
    if entry.muted then
      color = M.color.textDim
      if row.indicator then
        row.indicator:SetText("x")
        row.indicator:Show()
      end
    else
      if row.indicator then row.indicator:Hide() end
      if selected then color = M.color.accent end
    end
  end

  if row.label then
    row.label:SetText(text)
    pcall(row.label.SetTextColor, row.label, M.Unpack(color))
  end

  row.selected = selected and true or false
  if row.selected then
    U.SetBackgroundColor(row, M.Unpack(M.color.accentFill))
  else
    U.SetBackgroundColor(row, 0, 0, 0, 0)
  end
end

local function CreateRow(index)
  local host = (sidebarView and sidebarView.child) or sidebar
  local row = U.CreateButton(host, {
    name = "QtUiPlusSettingsRow" .. index,
    text = "",
    width = SIDEBAR_WIDTH - 20,
    height = ROW_HEIGHT,
    border = false,
  })

  -- The row's own label is left-aligned and indented per level, which
  -- U.CreateButton's centred label cannot do, so it is replaced here.
  if row.label then
    row.label:ClearAllPoints()
    row.label:SetPoint("LEFT", row, "LEFT", 8, -1)
    pcall(row.label.SetWidth, row.label, SIDEBAR_WIDTH - 44)
    pcall(row.label.SetJustifyH, row.label, "LEFT")
  end

  row.indicator = U.CreateLabel(row, {
    size = M.fontSize.small,
    color = M.color.accent,
    inherits = "GameFontNormalSmall",
  })
  if row.indicator then
    row.indicator:SetPoint("RIGHT", row, "RIGHT", -8, 0)
  end

  -- A borderless row has no outline to highlight, so hover is carried by the
  -- fill. The selected row keeps its accent fill and ignores hover.
  row:SetScript("OnEnter", function()
    if not row.selected then U.SetBackgroundColor(row, 1, 1, 1, 0.07) end

    local entry = row.entry
    if not entry or type(entry.tooltip) ~= "string" or entry.tooltip == "" then
      return
    end
    local tooltip = U.G("GameTooltip")
    if not tooltip then return end
    pcall(tooltip.SetOwner, tooltip, row, "ANCHOR_RIGHT")
    pcall(tooltip.SetText, tooltip, entry.tooltip)
    pcall(tooltip.Show, tooltip)
  end)
  row:SetScript("OnLeave", function()
    if not row.selected then U.SetBackgroundColor(row, 0, 0, 0, 0) end
    local tooltip = U.G("GameTooltip")
    if tooltip then pcall(tooltip.Hide, tooltip) end
  end)

  if sidebarView and sidebarView.AttachWheel then
    sidebarView.AttachWheel(row)
  end

  rows[index] = row
  return row
end

RenderSidebar = function()
  if not sidebar then return end

  local visible = VisibleEntries()
  local i

  for i = 1, table.getn(visible) do
    local entry = visible[i]
    local row = rows[i] or CreateRow(i)

    row:ClearAllPoints()
    local host = (sidebarView and sidebarView.child) or sidebar
    row:SetPoint("TOPLEFT", host, "TOPLEFT", 6,
                 -6 - (i - 1) * (ROW_HEIGHT + ROW_GAP))

    -- Pages under a group sit one indent in, so the list reads as a tree
    -- without needing a second column of art.
    if row.label then
      row.label:ClearAllPoints()
      row.label:SetPoint("LEFT", row, "LEFT", entry.parent and 18 or 8, -1)
      pcall(row.label.SetWidth, row.label,
            SIDEBAR_WIDTH - (entry.parent and 54 or 44))
    end

    row.entry = entry
    row:SetScript("OnClick", function()
      local target = row.entry
      if not target then return end

      if target.kind == "group" then
        target.expanded = not target.expanded
        if target.expanded then CollapseOtherGroups(target.id) end
        -- Only one row is ever highlighted: expanding a group claims the
        -- highlight, collapsing it releases the highlight (rather than
        -- falling back to whatever page used to hold it), and this holds at
        -- any depth for any future nested submenu.
        focusedId = target.expanded and target.id or nil
        RenderSidebar()
      else
        SelectPage(target)
      end
    end)

    StyleRow(row, entry, focusedId ~= nil and focusedId == entry.id)

    row:Show()
    if row.label then row.label:Show() end
    if row.indicator and entry.kind == "group" then row.indicator:Show() end
  end

  -- Hide the tail of the pool left over from a wider list.
  for i = table.getn(visible) + 1, table.getn(rows) do
    local row = rows[i]
    row.entry = nil
    if row.label then row.label:Hide() end
    if row.indicator then row.indicator:Hide() end
    row:Hide()
  end

  if sidebarView and sidebarView.SetContentHeight then
    local count = table.getn(visible)
    sidebarView.SetContentHeight(12 + count * (ROW_HEIGHT + ROW_GAP))
  end
end

-- ---------------------------------------------------------------------------
-- Pages
-- ---------------------------------------------------------------------------
local function RegionBottom(region)
  if not region then return nil end
  if region.qtpParts then
    local i, lowest
    for i = 1, table.getn(region.qtpParts) do
      local bottom = RegionBottom(region.qtpParts[i])
      if bottom and (not lowest or bottom < lowest) then lowest = bottom end
    end
    return lowest
  end
  if region.IsShown then
    local ok, shown = pcall(region.IsShown, region)
    if ok and (shown == false or shown == 0 or shown == "0") then return nil end
  end
  if not region.GetBottom then return nil end
  local ok, bottom = pcall(region.GetBottom, region)
  if ok then return tonumber(bottom) end
end

local function MeasureContent(list)
  if not content then return 1 end
  local ok, top = pcall(content.GetTop, content)
  top = (ok and tonumber(top)) or 0
  local lowest = top
  local i
  for i = 1, table.getn(list or {}) do
    local bottom = RegionBottom(list[i])
    if bottom and bottom < lowest then lowest = bottom end
  end
  local height = top - lowest + 16
  local viewH = 0
  if contentView and contentView.view and contentView.view.GetHeight then
    local vok, vh = pcall(contentView.view.GetHeight, contentView.view)
    if vok then viewH = tonumber(vh) or 0 end
  end
  if height < viewH then height = viewH end
  if height < 1 then height = 1 end
  return height
end

SelectPage = function(entry)
  if not entry or entry.kind ~= "page" then return end

  -- Picking a page outside the open group (or a top-level page while any
  -- group is open) collapses that group, same as clicking another group.
  CollapseOtherGroups(entry.parent)

  local i
  for i = 1, table.getn(entries) do
    local other = entries[i]
    if other ~= entry then SetListShown(other.widgets, false) end
  end

  if not entry.widgets then
    local widgets, refresh = entry.build(content)
    entry.widgets = widgets or {}
    entry.refresh = refresh
  end

  SetListShown(entry.widgets, true)
  if type(entry.refresh) == "function" then entry.refresh() end

  if contentView then
    local function AttachList(list)
      local n
      for n = 1, table.getn(list or {}) do
        local region = list[n]
        if region and region.qtpParts then
          AttachList(region.qtpParts)
        elseif region and region.SetScript then
          contentView.AttachWheel(region)
        end
      end
    end
    AttachList(entry.widgets)
    contentView.Apply(0)
    contentView.SetContentHeight(MeasureContent(entry.widgets))
  end

  activePage = entry
  focusedId = entry.id
  RenderSidebar()
end

-- Opens a page by id, expanding its group first. Modules use this to send the
-- user straight at their own options.
function U.OpenSettingsPage(id)
  local entry = FindEntry(id)
  if not entry or entry.kind ~= "page" then return false end

  if entry.parent then
    local parent = FindEntry(entry.parent)
    if parent then parent.expanded = true end
  end

  U.OpenSettings(true)
  SelectPage(entry)
  return true
end

-- ---------------------------------------------------------------------------
-- Panel
-- ---------------------------------------------------------------------------
local function HideContents()
  if not panel then return end

  -- A colour picker (core/widgets.lua) would otherwise leave its dialog open
  -- over a page that is about to be torn down, with callbacks still pointing
  -- at the hidden control. Closing without accepting also restores whatever
  -- colour was live-previewed, so an abandoned edit does not silently stick.
  if type(U.CloseColorPicker) == "function" then U.CloseColorPicker(false) end
  if type(U.HideConfirm) == "function" then U.HideConfirm("settings-reset") end

  SetListShown(panel.chrome, false)

  local i
  for i = 1, table.getn(rows) do
    if rows[i].label then rows[i].label:Hide() end
    if rows[i].indicator then rows[i].indicator:Hide() end
    rows[i]:Hide()
  end
  for i = 1, table.getn(entries) do SetListShown(entries[i].widgets, false) end

  sidebar:Hide()
  if content then content:Hide() end
  if sidebarView then
    pcall(sidebarView.view.Hide, sidebarView.view)
    pcall(sidebarView.child.Hide, sidebarView.child)
    pcall(sidebarView.track.Hide, sidebarView.track)
    pcall(sidebarView.thumb.Hide, sidebarView.thumb)
  end
  if contentView then
    pcall(contentView.view.Hide, contentView.view)
    pcall(contentView.child.Hide, contentView.child)
    pcall(contentView.track.Hide, contentView.track)
    pcall(contentView.thumb.Hide, contentView.thumb)
  end
end

local function Hide()
  if not panel then return end

  HideContents()
  panel:Hide()
end

local function Build()
  panel = U.CreatePanel(UIParent, {
    name = "QtUiPlusSettings",
    width = PANEL_WIDTH,
    height = PANEL_HEIGHT,
  })
  panel:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  pcall(panel.SetFrameStrata, panel, "HIGH")
  U.MakeWindowDraggable("settings", panel,
                         { headerHeight = HEADER_HEIGHT, headerInset = 0 })

  panel.chrome = {}

  -- WORKING_SOURCE: UnrealPfUI and QtUiPlus's own bag window use
  -- UISpecialFrames for Escape-to-close. The panel owns child visibility
  -- explicitly, so cover direct client hides as well as the Close button.
  local special = U.G("UISpecialFrames")
  if type(special) == "table" then
    table.insert(special, "QtUiPlusSettings")
  end
  panel:SetScript("OnHide", function() HideContents() end)

  panel.title = U.CreateLabel(panel, {
    size = M.fontSize.large,
    color = { 1, 1, 1, 1 },
    inherits = "GameFontNormal",
    justify = "LEFT",
  })
  if panel.title then
    panel.title:SetPoint("TOPLEFT", panel, "TOPLEFT", 14, -14)
    panel.title:SetText("Qt")
    table.insert(panel.chrome, panel.title)
  end

  panel.titleAccent = U.CreateLabel(panel, {
    size = M.fontSize.large,
    color = M.color.accent,
    inherits = "GameFontNormal",
    justify = "LEFT",
  })
  if panel.titleAccent then
    panel.titleAccent:SetPoint("LEFT", panel.title, "RIGHT", 4, 0)
    panel.titleAccent:SetText("UiPlus")
    table.insert(panel.chrome, panel.titleAccent)
  end

  panel.version = U.CreateLabel(panel, {
    size = M.fontSize.small,
    color = M.color.textDim,
    inherits = "GameFontNormalSmall",
  })
  if panel.version then
    panel.version:SetPoint("LEFT", panel.titleAccent or panel.title, "RIGHT", 8, -1)
    panel.version:SetText("v" .. U.version)
    table.insert(panel.chrome, panel.version)
  end

  local rule = U.CreateRule(panel, { color = M.color.accentDim })
  if rule then
    rule:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -(HEADER_HEIGHT - 12))
    rule:SetWidth(PANEL_WIDTH - 24)
    table.insert(panel.chrome, rule)
  end

  sidebar = U.CreatePanel(panel, {
    name = "QtUiPlusSettingsSidebar",
    width = SIDEBAR_WIDTH,
    height = PANEL_HEIGHT - HEADER_HEIGHT - FOOTER_HEIGHT,
    background = { 0.03, 0.03, 0.03, 0.90 },
  })
  sidebar:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -HEADER_HEIGHT)

  sidebarView = U.CreateScrollView(sidebar, {
    name = "QtUiPlusSettingsSidebarScroll",
    childWidth = SIDEBAR_WIDTH - 10,
  })
  sidebarView.view:SetPoint("TOPLEFT", sidebar, "TOPLEFT", 2, -2)
  sidebarView.view:SetPoint("BOTTOMRIGHT", sidebar, "BOTTOMRIGHT", -10, 2)
  sidebarView.track:SetPoint("TOPRIGHT", sidebar, "TOPRIGHT", -2, -2)
  sidebarView.track:SetPoint("BOTTOMRIGHT", sidebar, "BOTTOMRIGHT", -2, 2)
  sidebarView.AttachWheel(sidebar)

  -- Pages parent their widgets to this child. The ScrollFrame clips and
  -- offsets it (wiki ScrollFrame SetScrollChild).
  contentView = U.CreateScrollView(panel, {
    name = "QtUiPlusSettingsContentScroll",
    childWidth = 486,
  })
  contentView.view:SetPoint("TOPLEFT", sidebar, "TOPRIGHT", 12, 0)
  contentView.view:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -20, FOOTER_HEIGHT)
  contentView.track:SetPoint("TOPLEFT", contentView.view, "TOPRIGHT", 2, 0)
  contentView.track:SetPoint("BOTTOMLEFT", contentView.view, "BOTTOMRIGHT", 2, 0)
  content = contentView.child

  panel.close = U.CreateButton(panel, {
    name = "QtUiPlusSettingsClose",
    text = "Close",
    width = 100,
    height = 24,
    onClick = function() Hide() end,
  })
  panel.close:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -12, 12)
  table.insert(panel.chrome, panel.close)

  -- Under the sidebar, not on the General page: these two are modes that
  -- close the window, so they stay visible on every tab.
  panel.anchor = U.CreateButton(panel, {
    name = "QtUiPlusSettingsAnchor",
    text = "Anchor Mode",
    width = SIDEBAR_WIDTH,
    height = 24,
    onClick = function()
      Hide()
      U.UnlockUI()
    end,
  })
  panel.anchor:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 12, 12)
  table.insert(panel.chrome, panel.anchor)

  panel.quickbind = U.CreateButton(panel, {
    name = "QtUiPlusSettingsQuickBind",
    text = "Quick Binding",
    width = 120,
    height = 24,
    onClick = function()
      Hide()
      if type(U.OpenQuickBind) == "function" then
        U.OpenQuickBind()
      else
        U.Error("quick binding is not available in this build")
      end
    end,
  })
  panel.quickbind:SetPoint("LEFT", panel.anchor, "RIGHT", 8, 0)
  table.insert(panel.chrome, panel.quickbind)

  panel:Hide()
  sidebar:Hide()
  if content then content:Hide() end
  if sidebarView then
    pcall(sidebarView.view.Hide, sidebarView.view)
    pcall(sidebarView.track.Hide, sidebarView.track)
  end
  if contentView then
    pcall(contentView.view.Hide, contentView.view)
    pcall(contentView.track.Hide, contentView.track)
  end
  SetListShown(panel.chrome, false)
end

-- Closes the window without toggling it back open. A mode that takes over the
-- screen (modules/quickbind.lua) uses this rather than U.OpenSettings, which
-- would reopen an already-closed panel.
function U.CloseSettings()
  Hide()
end

-- Single entry point: /qtp and the minimap button both call this, so they can
-- never diverge (see core/commands.lua). keepOpen skips the toggle, which is
-- what U.OpenSettingsPage needs.
function U.OpenSettings(keepOpen)
  if not panel then Build() end

  local ok, shown = pcall(panel.IsShown, panel)
  if ok and shown then
    if keepOpen then return end
    Hide()
    return
  end

  panel:Show()
  sidebar:Show()
  if sidebarView then
    pcall(sidebarView.view.Show, sidebarView.view)
    pcall(sidebarView.child.Show, sidebarView.child)
  end
  if contentView then
    pcall(contentView.view.Show, contentView.view)
    pcall(contentView.child.Show, contentView.child)
  end
  if content then content:Show() end
  SetListShown(panel.chrome, true)

  RenderSidebar()

  -- Open on the last page used, or on the first page in the list.
  if activePage then
    SelectPage(activePage)
  else
    local i
    for i = 1, table.getn(entries) do
      if entries[i].kind == "page" then
        SelectPage(entries[i])
        return
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- General page
--
-- The original panel's contents: the position reset and the small toggles
-- that do not warrant a tab of their own. Anchor Mode and Quick Binding live
-- in the window footer so they stay reachable from every page.
-- ---------------------------------------------------------------------------
-- A theme change only takes effect on the next reload: frames already built
-- own tinted textures and font colours that swapping the token table would not
-- revisit. Say so, but only while a change is actually pending.
local function ThemeHintText()
  if type(U.ThemeStyleRequiresReload) == "function" and
     U.ThemeStyleRequiresReload() then
    return "Reload the UI (/reload) to apply this theme."
  end
  return "Changes the look of QtUiPlus-owned frames."
end

local function BuildGeneralPage(parent)
  local widgets = {}

  local header = U.CreateSectionHeader(parent, {
    text = "General",
    width = PANEL_WIDTH - SIDEBAR_WIDTH - 36,
    y = -4,
  })
  table.insert(widgets, header)

  local reset = U.CreateButton(parent, {
    name = "QtUiPlusSettingsReset",
    text = "Reset frame positions",
    width = 220,
    height = 26,
    onClick = function()
      if type(U.ShowConfirm) ~= "function" then
        U.ResetPositions()
        return
      end
      U.ShowConfirm({
        owner = "settings-reset",
        text = "Reset all frame positions?",
        detail = "Every moved frame returns to its default place.",
        acceptText = "Reset",
        cancelText = "Cancel",
        onAccept = function() U.ResetPositions() end,
      })
    end,
  })
  reset:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -34)
  table.insert(widgets, reset)

  local hint = U.CreateSettingsLabel(parent, {
    size = M.fontSize.small,
    color = M.color.textDim,
    inherits = "GameFontNormalSmall",
    justify = "LEFT",
  })
  if hint then
    U.AnchorSettingsDescription(hint, reset)
    hint:SetText("Anchor Mode (footer) lets you drag frames onto the grid. " ..
                 "Hold Shift while dropping for free placement.")
    table.insert(widgets, hint)
  end

  -- The micro bar (modules/microbar.lua) has a single setting, so its toggle
  -- lives here rather than on a dedicated tab of its own.
  local microbar = U.CreateCheckbox(parent, {
    name = "QtUiPlusSettingsMicroBar",
    text = "Enable micro bar",
    value = U.ModuleConfig("microbar", { enabled = true }).enabled,
    onChange = function(value)
      U.ModuleConfig("microbar", { enabled = true }).enabled = value
      if type(U.ApplyMicroBar) == "function" then U.ApplyMicroBar() end
    end,
  })
  microbar.SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -100)
  table.insert(widgets, microbar)

  local microbarHint = U.CreateSettingsLabel(parent, {
    size = M.fontSize.small,
    color = M.color.textDim,
    inherits = "GameFontNormalSmall",
    justify = "LEFT",
  })
  if microbarHint then
    U.AnchorSettingsDescription(microbarHint, microbar.box)
    microbarHint:SetText("Pulls the native character/spellbook/talent/quest " ..
                         "log/social/map/menu/help buttons into one movable " ..
                         "row. Disabling returns them to their stock location.")
    table.insert(widgets, microbarHint)
  end

  -- The reputation bar (modules/xpbar.lua) is the only other single-setting
  -- overlay; the XP bar itself is required scope and has no toggle.
  local reputation = U.CreateCheckbox(parent, {
    name = "QtUiPlusSettingsReputationBar",
    text = "Show reputation bar",
    value = U.ModuleConfig("xpbar", { repEnabled = true }).repEnabled,
    onChange = function(value)
      U.ModuleConfig("xpbar", { repEnabled = true }).repEnabled = value
      if type(U.ApplyXPBar) == "function" then U.ApplyXPBar() end
    end,
  })
  reputation.SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -156)
  table.insert(widgets, reputation)

  -- The minimap settings button (modules/minimap.lua) is the normal way to
  -- reach this window, so hiding it does not lock the player out: the /qtp
  -- slash command still opens settings.
  local minimapButton = U.CreateCheckbox(parent, {
    name = "QtUiPlusSettingsMinimapButton",
    text = "Show minimap settings button",
    value = U.ModuleConfig("minimap", { enabled = true }).enabled,
    onChange = function(value)
      U.ModuleConfig("minimap", { enabled = true }).enabled = value
      if type(U.ApplyMinimapButton) == "function" then U.ApplyMinimapButton() end
    end,
  })
  minimapButton.SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -188)
  table.insert(widgets, minimapButton)

  local minimapBuffs = U.CreateCheckbox(parent, {
    name = "QtUiPlusSettingsMinimapBuffs",
    text = "Show minimap buffs",
    value = U.ModuleConfig("minimap", { showBuffs = true }).showBuffs ~= false,
    onChange = function(value)
      U.ModuleConfig("minimap", { showBuffs = true }).showBuffs = value and true or false
      if type(U.ApplyMinimapAuras) == "function" then U.ApplyMinimapAuras() end
    end,
  })
  minimapBuffs.SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -220)
  table.insert(widgets, minimapBuffs)

  local minimapDebuffs = U.CreateCheckbox(parent, {
    name = "QtUiPlusSettingsMinimapDebuffs",
    text = "Show minimap debuffs",
    value = U.ModuleConfig("minimap", { showDebuffs = true }).showDebuffs ~= false,
    onChange = function(value)
      U.ModuleConfig("minimap", { showDebuffs = true }).showDebuffs = value and true or false
      if type(U.ApplyMinimapAuras) == "function" then U.ApplyMinimapAuras() end
    end,
  })
  minimapDebuffs.SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -252)
  table.insert(widgets, minimapDebuffs)

  local auraHint = U.CreateSettingsLabel(parent, {
    size = M.fontSize.small,
    color = M.color.textDim,
    inherits = "GameFontNormalSmall",
    justify = "LEFT",
  })
  if auraHint then
    U.AnchorSettingsDescription(auraHint, minimapDebuffs.box)
    auraHint:SetText("The stock aura row next to the minimap. Player and " ..
                     "target auras on the unit frames are unchanged.")
    table.insert(widgets, auraHint)
  end

  -- Visual style (core/theme.lua). Right column, because the left one is full
  -- down to the snap insets and this panel does not scroll.
  --
  -- Only styles that report themselves available are offered. A style still
  -- being built stays in the list, labelled and unselectable, so the settings
  -- window says what is coming instead of hiding it.
  local themeSelect, themeHint
  if type(U.GetThemeStyles) == "function" then
    local styles, choices, i = U.GetThemeStyles(), {}, nil
    for i = 1, table.getn(styles) do
      local style = styles[i]
      local label = style.label
      if not style.available then label = label .. " (soon)" end
      table.insert(choices, { key = style.id, label = label })
    end

    themeSelect = U.CreateSelect(parent, {
      name = "QtUiPlusSettingsTheme",
      text = "Theme",
      width = 200,
      values = choices,
      value = U.GetThemeStyle(),
      onChange = function(key)
        -- U.SetThemeStyle refuses a style that is not available, so the
        -- selection is put back to what is actually stored rather than left
        -- showing a choice that did not take.
        U.SetThemeStyle(key)
        if themeSelect then themeSelect.SetValue(U.GetThemeStyle()) end
        if themeHint then themeHint:SetText(ThemeHintText()) end
      end,
    })
    themeSelect.SetPoint("TOPLEFT", parent, "TOPLEFT", 258, -110)
    table.insert(widgets, themeSelect)

    themeHint = U.CreateSettingsLabel(parent, {
      size = M.fontSize.small,
      color = M.color.textDim,
      inherits = "GameFontNormalSmall",
      justify = "LEFT",
      width = 200,
    })
    if themeHint then
      themeHint:SetPoint("TOPLEFT", parent, "TOPLEFT", 258, -136)
      themeHint:SetText(ThemeHintText())
      table.insert(widgets, themeHint)
    end
  end

  -- Grid pitch for edit mode (core/mover.lua). Lives here rather than on a
  -- page of its own: it is one slider, and it belongs with the Anchor Mode
  -- button that opens the mode it affects.
  local gridMin, gridMax, gridStep = U.GridSizeLimits()
  local gridSlider = U.CreateSlider(parent, {
    name = "QtUiPlusSettingsGridSize",
    text = "Edit Mode Grid Size",
    width = 200,
    min = gridMin, max = gridMax, step = gridStep,
    value = U.GridSize(),
    onChange = function(value) U.SetGridSize(value) end,
  })
  gridSlider.SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -310)
  table.insert(widgets, gridSlider)

  local padMin, padMax, padStep = 0, 80, 1
  if type(U.SnapPadLimits) == "function" then
    padMin, padMax, padStep = U.SnapPadLimits()
  end

  local PAD_SLIDERS = {
    { edge = "left",   text = "Snap Inset Left",   column = 0, row = 0 },
    { edge = "right",  text = "Snap Inset Right",  column = 1, row = 0 },
    { edge = "bottom", text = "Snap Inset Bottom", column = 0, row = 1 },
    { edge = "top",    text = "Snap Inset Top",    column = 1, row = 1 },
  }
  local padControls = {}
  local p
  for p = 1, table.getn(PAD_SLIDERS) do
    local spec = PAD_SLIDERS[p]
    local slider = U.CreateSlider(parent, {
      name = "QtUiPlusSettingsSnapPad" .. spec.edge,
      text = spec.text,
      width = 200,
      min = padMin, max = padMax, step = padStep,
      value = type(U.GetSnapPad) == "function" and U.GetSnapPad(spec.edge) or 0,
      onChange = function(value)
        if type(U.SetSnapPad) == "function" then U.SetSnapPad(spec.edge, value) end
      end,
    })
    slider.SetPoint("TOPLEFT", parent, "TOPLEFT",
                    spec.column * 258, -370 - spec.row * 44)
    padControls[spec.edge] = slider
    table.insert(widgets, slider)
  end

  local function Refresh()
    gridSlider.SetValue(U.GridSize())
    if themeSelect then themeSelect.SetValue(U.GetThemeStyle()) end
    if themeHint then themeHint:SetText(ThemeHintText()) end
    microbar.SetValue(U.ModuleConfig("microbar", { enabled = true }).enabled)
    reputation.SetValue(U.ModuleConfig("xpbar", { repEnabled = true }).repEnabled)
    minimapButton.SetValue(U.ModuleConfig("minimap", { enabled = true }).enabled)
    minimapBuffs.SetValue(U.ModuleConfig("minimap", { showBuffs = true }).showBuffs ~= false)
    minimapDebuffs.SetValue(U.ModuleConfig("minimap", { showDebuffs = true }).showDebuffs ~= false)
    local edge, slider
    for edge, slider in pairs(padControls) do
      if type(U.GetSnapPad) == "function" then
        slider.SetValue(U.GetSnapPad(edge))
      end
    end
  end

  return widgets, Refresh
end

function S:OnInit()
  U.RegisterSettingsTab("general", "General", BuildGeneralPage)
end

function S:OnEnable()
  -- Built lazily on first open; nothing to do here beyond making sure the
  -- module exists in the registry for /qtp check.
end
