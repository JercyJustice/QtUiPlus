-- Reusable skin and placement adapter for native UIDropDownMenuTemplate
-- controls. The popup lists are a shared native pool, so this owns both the
-- per-control presentation and the shared-list cleanup in one component.

local U = QtUiPlus
local M = U.media

U.Dropdown = U.Dropdown or {}
local D = U.Dropdown

local menuHooked = false
local textHooked = false
local selectedIdHooked = false

-- Doubled from the previous 14-unit height, as requested.
local CONTROL_HEIGHT = 28
-- The -5 riding-high nudge was tuned for the old 14-unit box; at the doubled
-- height the clamped SetHeight + explicit CENTER justify below already lands
-- the glyph on the control's true centre. USER_CONFIRMED_INGAME: still 1px
-- high at that centre, so a small residual nudge remains. U.CreateSelect takes
-- the same clamp-and-centre route but landed on a different residual
-- (U.SELECT_LABEL_OFFSET_Y), so the two are tuned apart: this one is the value
-- confirmed for the 28-unit control and its stock-template FontString.
local CONTROL_TEXT_Y = -1

-- Compact tick box for list rows. Native rows are 16 high, so this is smaller
-- than the 14-unit settings checkbox and uses a matching smaller accent mark.
local ROW_CHECK_SIZE = 10
local ROW_CHECK_MARK_INSET = 3
local ROW_TEXT_INSET = 8

local StyleList        -- defined below; rows re-run it when a tick changes.
local activeDropdown   -- last dropdown whose button we saw opened.

local function RemoveButtonArt(button)
  if not button then return end
  local getters = { "GetNormalTexture", "GetPushedTexture", "GetHighlightTexture", "GetDisabledTexture" }
  local setters = { "SetNormalTexture", "SetPushedTexture", "SetHighlightTexture", "SetDisabledTexture" }
  local i
  for i = 1, table.getn(getters) do
    local getter = button[getters[i]]
    if type(getter) == "function" then
      local ok, texture = pcall(getter, button)
      if ok and texture then U.HideRegion(texture) end
    end
  end
  for i = 1, table.getn(setters) do
    local setter = button[setters[i]]
    if type(setter) == "function" then
      if not pcall(setter, button, "") then pcall(setter, button, nil) end
    end
  end
end

local function StyleArrow(button)
  if not button then return end
  if not button.qtpDropdownArrow then
    button.qtpDropdownArrow = U.CreateLabel(button, {
      size = M.fontSize.small,
      color = M.color.accent,
      inherits = "GameFontNormalSmall",
    })
    if button.qtpDropdownArrow then
      button.qtpDropdownArrow:SetPoint("RIGHT", button, "RIGHT", -4, 0)
      button.qtpDropdownArrow:SetText("v")
    end
  end
  if button.qtpDropdownArrow then button.qtpDropdownArrow:Show() end
end

local function LayoutText(dropdown, button)
  if not dropdown then return end
  local name = dropdown.GetName and dropdown:GetName()
  local text = name and U.G(name .. "Text")
  if not text then return end
  -- The button now spans the whole control (so clicking the value opens the
  -- menu too), so text width is reserved against the arrow glyph, not the
  -- button's edge.
  local arrow = button and button.qtpDropdownArrow
  U.SetStockFont(text, M.fontSize.small, M.color.text)
  pcall(function()
    text:ClearAllPoints()
    -- LEFT/RIGHT anchors put the text region's own centre on the control's
    -- centre. That alone left the label riding high: the native fontstring
    -- keeps a taller template height than the shortened control and aligns its
    -- glyphs to the top of that region. So the region is also clamped to the
    -- control height and given explicit CENTER justification -- the same
    -- explicit-SetJustifyV treatment chat.scrollingmessage_bottom_alignment
    -- records for this client, where inherited vertical alignment is not what
    -- upstream expects.
    text:SetPoint("LEFT", dropdown, "LEFT", 5, CONTROL_TEXT_Y)
    text:SetPoint("RIGHT", arrow or dropdown, arrow and "LEFT" or "RIGHT", -4, CONTROL_TEXT_Y)
    text:SetHeight(CONTROL_HEIGHT)
    text:SetJustifyH("LEFT")
    if text.SetJustifyV then text:SetJustifyV("CENTER") end
  end)
end

-- The native control owns its own template height and puts it back from paths
-- QtUiPlus does not drive: the show/update pass already needed the reassert in
-- StyleStock, and USER_CONFIRMED_INGAME opening the menu snapped the control
-- back to the taller stock size and left it there. Replacing the frame's own
-- SetHeight makes every later Lua-side resize land on the component height
-- instead of chasing each caller separately. The original method is kept so
-- ApplyControlHeight still reaches the real setter.
local function LockControlHeight(dropdown)
  if not dropdown or dropdown.qtpDropdownHeightLock then return end
  if type(dropdown.SetHeight) ~= "function" then return end
  local native = dropdown.SetHeight
  local ok = pcall(function()
    dropdown.SetHeight = function(self, _)
      return native(self, CONTROL_HEIGHT)
    end
  end)
  if ok then dropdown.qtpDropdownHeightLock = native end
end

local function ApplyControlHeight(dropdown)
  if not dropdown then return end
  pcall(dropdown.qtpDropdownHeightLock or dropdown.SetHeight, dropdown, CONTROL_HEIGHT)
end

-- Selection handlers can continue changing the native FontString after their
-- post-hooks return. Reapply the fixed geometry one shared tick later so every
-- selected value keeps the same Y position, regardless of its text.
local function LayoutTextWhenSettled(dropdown)
  if not dropdown then return end
  local name = dropdown.GetName and dropdown:GetName()
  if not name then return end
  ApplyControlHeight(dropdown)
  LayoutText(dropdown, U.G(name .. "Button"))
  U.DeferOnce("dropdown:text-layout:" .. name, function()
    if dropdown.qtpDropdownStyled then
      ApplyControlHeight(dropdown)
      LayoutText(dropdown, U.G(name .. "Button"))
    end
  end)
end

local function IsSelected(check)
  if not check or type(check.IsShown) ~= "function" then return false end
  local ok, shown = pcall(check.IsShown, check)
  return ok and shown and true or false
end

-- Popup list rows are the client's own state carriers, not decoration, so
-- QtUiPlus only ever changes their ALPHA -- never a shown flag, never a
-- texture path, never a button face.
--
-- USER_CONFIRMED_INGAME (class trainer Filter menu): the generic strip's
-- U.HideRegion (SetTexture(nil) + SetAlpha(0) + Hide) on row regions left the
-- filter doing nothing at all, and keeping only the Check region out of the
-- strip -- the previous fix, and the open probe question in knowledge.json /
-- frames.dropdown_component_checkbox_contract -- did NOT restore it. The
-- single-select /who dropdown kept working throughout, which is what points at
-- per-row state rather than at the click path: /who reads only its own func,
-- while the trainer's entries are keepShownOnClick filters whose ticked state
-- the client stores on the row itself.
--
-- Rather than guess which region or field holds that state, nothing owned by
-- the row is mutated any more. knowledge.json /
-- rendering.native_texture_strip_requires_alpha records alpha as the part that
-- actually removes stock art on this client, so alpha alone gets the flat look
-- with no way left to destroy client state. UnrealPfUI (WORKING_SOURCE,
-- api/ui-widgets.lua SkinDropDown) does not touch list rows at all, which is
-- the same conclusion from the other direction.
local function RegionNameOf(region)
  if not region or type(region.GetName) ~= "function" then return nil end
  local ok, name = pcall(region.GetName, region)
  if ok and type(name) == "string" then return name end
  return nil
end

local function RegionNameMatches(region, needle)
  local name = RegionNameOf(region)
  if not name then return false end
  return string.find(string.lower(name), needle, 1, true) and true or false
end

local function IsColorSwatchArt(region)
  return RegionNameMatches(region, "colorswatch")
      or RegionNameMatches(region, "swatchbg")
end

local function IsExpandArrowArt(region)
  return RegionNameMatches(region, "expandarrow")
end

local function SuppressRegionArt(region)
  if not region or not region.GetObjectType then return end
  if IsColorSwatchArt(region) or IsExpandArrowArt(region) then return end
  local typeOk, objectType = pcall(region.GetObjectType, region)
  if not typeOk or objectType ~= "Texture" then return end
  pcall(function() if region.SetAlpha then region:SetAlpha(0) end end)
end

local function RestoreRegionArt(region)
  if not region then return end
  pcall(function() if region.SetAlpha then region:SetAlpha(1) end end)
end

local function ObjectIsShown(object)
  if not object or type(object.IsShown) ~= "function" then return false end
  local ok, shown = pcall(object.IsShown, object)
  return ok and shown and true or false
end

-- Channel rows and "Background" keep a ColorSwatch. Every list button has
-- that child in the template, hidden unless UIDropDownMenu_AddButton set
-- hasColorSwatch. Showing it on every row put empty pickers on Unlock /
-- submenu arrows. Native Show/Hide is the contract; this only un-fades art
-- on a swatch the client already opened, and hides it on arrow rows.
local function SyncColorSwatch(listName, index)
  local prefix = listName .. "Button" .. index
  local row = U.G(prefix)
  local swatch = U.G(prefix .. "ColorSwatch")
  if not swatch then return end

  local arrow = U.G(prefix .. "ExpandArrow")
  local isArrow = ObjectIsShown(arrow) or (row and row.hasArrow and true or false)
  local wants = false
  if row and not isArrow then
    if row.hasColorSwatch then wants = true end
    if type(row.swatchFunc) == "function" then wants = true end
    -- Vanilla AddButton writes r/g/b on the row only for a real swatch.
    if row.r ~= nil and row.g ~= nil and row.b ~= nil then wants = true end
  end

  -- The template puts a ColorSwatch on every button. Submenus never have
  -- one. Do not Show() a hidden swatch -- that painted empty pickers on
  -- Unlock / Font Size / Channels. A real colour row is already shown by
  -- UIDropDownMenu_AddButton; only un-fade its art.
  if isArrow then
    pcall(swatch.Hide, swatch)
    return
  end
  if not wants and not ObjectIsShown(swatch) then
    return
  end
  if not wants then
    -- Shown with no colour flags: leftover from forcing every swatch
    -- visible. Hide it. Channel/Background rows set swatchFunc.
    pcall(swatch.Hide, swatch)
    return
  end

  RestoreRegionArt(swatch)
  RestoreRegionArt(U.G(prefix .. "ColorSwatchSwatchBg"))
  if type(swatch.GetNormalTexture) == "function" then
    local ok, texture = pcall(swatch.GetNormalTexture, swatch)
    if ok then RestoreRegionArt(texture) end
  end
  if swatch.GetRegions then
    local ok, regions = pcall(function() return { swatch:GetRegions() } end)
    if ok and type(regions) == "table" then
      local i
      for i = 1, table.getn(regions) do RestoreRegionArt(regions[i]) end
    end
  end
end

local function SuppressRowArt(row)
  if not row then return end

  if row.GetRegions then
    local ok, regions = pcall(function() return { row:GetRegions() } end)
    if ok and type(regions) == "table" then
      local i
      for i = 1, table.getn(regions) do
        SuppressRegionArt(regions[i])
      end
    end
  end

  -- The row's button faces are separate objects from its regions, so they are
  -- faded the same way instead of going through RemoveButtonArt -- that helper
  -- reassigns the textures, which is a mutation rows must not receive.
  local getters = { "GetNormalTexture", "GetPushedTexture",
                    "GetHighlightTexture", "GetDisabledTexture" }
  local i
  for i = 1, table.getn(getters) do
    local getter = row[getters[i]]
    if type(getter) == "function" then
      local ok, texture = pcall(getter, row)
      if ok and texture then SuppressRegionArt(texture) end
    end
  end
end

-- The Check may not be enumerable as a row region on this client, so it is
-- faded explicitly as well. Alpha only, for the same reason as above.
local function SuppressCheckArt(check)
  if not check then return end
  SuppressRegionArt(check)
end

-- Owned tick box replacing the stock Check texture. It is created lazily so
-- rows in plain (single-select) menus never gain an indicator column.
local function RowCheckbox(row)
  if row.qtpDropdownCheckbox then return row.qtpDropdownCheckbox end
  local box = U.CreatePanel(row, {
    width = ROW_CHECK_SIZE,
    height = ROW_CHECK_SIZE,
    background = M.color.background,
  })
  if not box then return nil end
  pcall(function()
    box:ClearAllPoints()
    box:SetPoint("LEFT", row, "LEFT", ROW_TEXT_INSET, 0)
  end)
  pcall(box.EnableMouse, box, false)
  row.qtpDropdownCheckbox = box
  return box
end

-- checkboxes: the owning dropdown was styled as a multi-select filter, so every
-- row reserves the indicator column and shows its own ticked state. Single-select
-- dropdowns pass false and keep the plain accent-highlight row.
local function StyleListRow(name, index, checkboxes)
  local row = U.G(name .. "Button" .. index)
  local check = U.G(name .. "Button" .. index .. "Check")
  local selected = IsSelected(check)
  if row then
    row.qtpDropdownSelected = selected
    SuppressRowArt(row)
  end
  SuppressCheckArt(check)

  local text = U.G(name .. "Button" .. index .. "NormalText")
  if not text or not row then return end

  SyncColorSwatch(name, index)

  -- Multi-select menus always show the column. Other menus (chat channels)
  -- still use the native Check shown-flag as "this row is ticked", so a joined
  -- channel must get an owned mark even without qtpDropdownCheckboxes.
  local showBox = (checkboxes or selected) and true or false
  local box = showBox and RowCheckbox(row) or row.qtpDropdownCheckbox
  if box then
    if showBox then
      box:ClearAllPoints()
      box:SetPoint("LEFT", row, "LEFT", ROW_TEXT_INSET, 0)
      U.SetCheckboxIndicator(box, selected, ROW_CHECK_MARK_INSET)
      box:Show()
    else
      box:Hide()
    end
  end

  U.SetStockFont(text, M.fontSize.small, selected and M.color.accent or M.color.text)
  pcall(function()
    text:ClearAllPoints()
    if showBox and box then
      text:SetPoint("LEFT", box, "RIGHT", 6, 0)
    else
      text:SetPoint("LEFT", row, "LEFT", ROW_TEXT_INSET, 0)
    end
    text:SetPoint("RIGHT", row, "RIGHT", -ROW_TEXT_INSET, 0)
    text:SetHeight(row:GetHeight())
    text:SetJustifyH("LEFT")
    if text.SetJustifyV then text:SetJustifyV("CENTER") end
  end)
  if not row.qtpDropdownHoverAttached then
    row.qtpDropdownHoverAttached = U.PostHookScript(row, "OnEnter", function()
      U.SetStockFont(text, M.fontSize.small, M.color.accent)
    end)
    U.PostHookScript(row, "OnLeave", function()
      U.SetStockFont(text, M.fontSize.small,
        row.qtpDropdownSelected and M.color.accent or M.color.text)
    end)
    -- A tickable entry changes its own state without necessarily reopening the
    -- menu, so the owned indicator has to be refreshed after the native click.
    --
    -- USER_CONFIRMED_INGAME: restyling inline here made every tick box lag one
    -- click behind (the user had to click twice to see a tick). The native
    -- handler has not updated its Check texture yet when a post-hooked OnClick
    -- runs, so the inline pass reads the pre-click state. Deferring one shared
    -- tick lets the client settle before the state is read back.
    U.PostHookScript(row, "OnClick", function()
      U.DeferOnce("dropdown:rowtick", function()
        if StyleList then
          StyleList(1)
          StyleList(2)
        end
      end)
    end)
  end
end

-- The popup lists are one shared native pool, so the row style comes from
-- whichever dropdown opened them. The client's own open-menu global is
-- preferred (it is set before the list is built, so the first pass is already
-- correct); activeDropdown is the fallback, set from our own button hook.
-- The global's shape is not in the compact evidence, so both the frame and the
-- Vanilla-style frame-name string are accepted.
local function OwningDropdown()
  local open = U.G("UIDROPDOWNMENU_OPEN_MENU")
  if type(open) == "string" then open = U.G(open) end
  if type(open) ~= "table" then open = activeDropdown end
  return open
end

local function WantsCheckboxes()
  local dropdown = OwningDropdown()
  return dropdown and dropdown.qtpDropdownCheckboxes and true or false
end

StyleList = function(level)
  local name = "DropDownList" .. level
  local list = U.G(name)
  if not list then return nil end

  -- The native list and its child backdrop can each retain artwork. Strip both
  -- before creating our flat panel so no native edge draws over the new border.
  U.StripStockTextures(list)
  local backdropNames = { "MenuBackdrop", "Backdrop", "Border", "BorderFrame" }
  local i
  for i = 1, table.getn(backdropNames) do
    local nativeBackdrop = U.G(name .. backdropNames[i])
    if nativeBackdrop then
      U.StripStockTextures(nativeBackdrop)
      pcall(nativeBackdrop.SetBackdropBorderColor, nativeBackdrop, 0, 0, 0, 0)
      U.HideRegion(nativeBackdrop)
    end
  end
  U.CreateBackdrop(list, { background = { 0.03, 0.03, 0.03, 0.95 } })

  local max = tonumber(U.G("UIDROPDOWNMENU_MAXBUTTONS")) or 8
  local checkboxes = WantsCheckboxes()
  i = nil
  for i = 1, max do
    StyleListRow(name, i, checkboxes)
  end
  return list
end

function D.PlaceListBelow(dropdown)
  if not dropdown then return false end
  activeDropdown = dropdown
  local list = StyleList(1)
  if not list then return false end
  return pcall(function()
    list:ClearAllPoints()
    list:SetPoint("TOPLEFT", dropdown, "BOTTOMLEFT", 0, -4)
  end)
end

local function AttachPlacement(dropdown, button)
  if not button or button.qtpDropdownPlacementAttached then return end
  if type(button.GetScript) ~= "function" or type(button.SetScript) ~= "function" then return end

  -- Keep the client responsible for invoking its native click handler. Calling
  -- that handler manually omits engine-owned click state and can fault natively.
  local installed = U.PostHookScript(button, "OnClick", function()
    -- Toggling the menu runs the client's own dropdown update path, which
    -- restores the stock control height, so the control must be re-measured
    -- on open and on close. Inline plus one shared tick later, the same gap
    -- the selection path needs, so the control keeps one height whether the
    -- list is open or not.
    LayoutTextWhenSettled(dropdown)
    D.PlaceListBelow(dropdown)
  end)
  if installed then button.qtpDropdownPlacementAttached = true end
end

function D.EnsureMenuSkin()
  if menuHooked then return end
  menuHooked = true
  if not U.PostHookGlobal("ToggleDropDownMenu", function()
    StyleList(1)
    StyleList(2)
  end) then
    U.Debug("dropdown: ToggleDropDownMenu unavailable, popup menu stays native")
  end
  -- Optional: the tick-and-stay-open path refreshes entries through this
  -- global on Vanilla-shaped clients. Not present in the compact evidence, so
  -- the hook fails closed and the OnClick restyle above remains the fallback.
  if not U.PostHookGlobal("UIDropDownMenu_Refresh", function()
    StyleList(1)
    StyleList(2)
  end) then
    U.Debug("dropdown: UIDropDownMenu_Refresh unavailable, ticks refresh on click only")
  end
end

function D.EnsureTextLayout()
  -- WORKING_SOURCE: the client uses UIDropDownMenu_SetText(text, frame), not
  -- the modern frame-first signature. Its selection path can also update the
  -- label through UIDropDownMenu_SetSelectedID(frame, id, useValue).
  if not textHooked then
    local installed = U.PostHookGlobal("UIDropDownMenu_SetText", function(_, dropdown)
      if dropdown and dropdown.qtpDropdownStyled then
        LayoutTextWhenSettled(dropdown)
      end
    end)
    if installed then textHooked = true end
  end
  if not selectedIdHooked then
    local installed = U.PostHookGlobal("UIDropDownMenu_SetSelectedID", function(dropdown)
      if dropdown and dropdown.qtpDropdownStyled then
        LayoutTextWhenSettled(dropdown)
      end
    end)
    if installed then selectedIdHooked = true end
  end
end

-- options.checkboxes: the entries are independent on/off filters (the class
-- trainer's Filter menu), so each row gets an owned tick box. Leave it unset for
-- an ordinary single-select dropdown such as the Who list's zone/guild filter.
function D.StyleStock(dropdown, width, options)
  if not dropdown then return nil end
  options = options or {}
  D.EnsureMenuSkin()
  D.EnsureTextLayout()

  local name
  if dropdown.GetName then
    local ok, value = pcall(dropdown.GetName, dropdown)
    if ok then name = value end
  end
  if not name then return dropdown end
  dropdown.qtpDropdownStyled = true
  dropdown.qtpDropdownCheckboxes = options.checkboxes and true or false

  U.HideRegion(U.G(name .. "Left"))
  U.HideRegion(U.G(name .. "Middle"))
  U.HideRegion(U.G(name .. "Right"))
  U.HideRegion(U.G(name .. "Icon"))
  U.CreateBackdrop(dropdown, { background = { 0.03, 0.03, 0.03, 0.85 } })
  LockControlHeight(dropdown)
  ApplyControlHeight(dropdown)
  if width then pcall(dropdown.SetWidth, dropdown, width) end

  local button = U.G(name .. "Button")
  if button then
    -- Cover the whole control, not just the arrow's corner, so clicking the
    -- selected value opens the menu the same way clicking the arrow does.
    pcall(function()
      button:ClearAllPoints()
      button:SetAllPoints(dropdown)
    end)
    RemoveButtonArt(button)
    StyleArrow(button)
    AttachPlacement(dropdown, button)
  end

  LayoutText(dropdown, button)
  if not dropdown.qtpDropdownTextHooked then
    dropdown.qtpDropdownTextHooked = U.PostHookScript(dropdown, "OnShow", function()
      -- USER_CONFIRMED_INGAME: changing the one-time SetHeight above did not
      -- change the visible trainer control. Reassert the component geometry
      -- after the native template's show/update path has restored its size.
      ApplyControlHeight(dropdown)
      LayoutText(dropdown, U.G(name .. "Button"))
    end)
  end
  return dropdown
end

-- Compatibility alias for callers not yet migrated to the component namespace.
function U.StyleStockDropdown(dropdown, width, options)
  return D.StyleStock(dropdown, width, options)
end
