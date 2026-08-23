-- QtUiPlus :: core/mover.lua
--
-- The shared mover system. Modules register the frames they want the user to
-- be able to place; unlocking shows a drag handle over each one.
--
-- Deliberately small. This is not pfUI's mover/config framework: there are no
-- grids, snapping, nudge keys, per-frame scale editing or profile machinery.
-- Only intended QtUiPlus elements are ever registered. modules/minimap.lua is
-- the one exception that registers a native frame (MinimapCluster) rather than
-- an QtUiPlus-owned one: the map itself is still never reskinned or replaced,
-- it is just given a drag handle like everything else here.

local U = QtUiPlus
local M = U.media

local movers = {}       -- id -> entry
local moverOrder = {}
local unlocked = false

-- Edit-mode grid. Sized in UIParent units, which is the only space layout may
-- be driven from (frames.json context: GetScreenWidth and UIParent:GetWidth are
-- not the same unit space on this client).
-- Shipped grid pitch, and the default for the setting below. QtUI called this
-- "snap range"; here it is the spacing of the grid a dropped frame lands on,
-- which is the same knob in a grid-based mover.
local GRID_SIZE = 20
local GRID_LIMITS = { min = 2, max = 40, step = 1 }

-- Read through a function rather than the constant so the setting takes effect
-- on the next drop. The grid ARTWORK is built once, so changing this rebuilds
-- it -- see U.SetGridSize.
local function GridPitch()
  local cfg = U.ModuleConfig("mover", { gridSize = GRID_SIZE })
  local value = U.Round(tonumber(cfg.gridSize) or GRID_SIZE)
  if value < GRID_LIMITS.min then value = GRID_LIMITS.min end
  if value > GRID_LIMITS.max then value = GRID_LIMITS.max end
  return value
end

-- ---------------------------------------------------------------------------
-- Position handling
--
-- knowledge.json / frames.getpoint_relative_name_y_inverted (BEHAVIOR_VERIFIED)
-- is the whole reason this file reads anchors through U.GetFramePoint: GetPoint
-- hands back the relative frame as a name string and inverts Y. That record
-- also lists two failed approaches, both avoided here:
--
--   * persisting the raw GetPoint tuple as if it were Blizzard-compatible
--   * recapturing a point and immediately clearing/re-applying it
--
-- so a drop is captured and stored, and the frame is left exactly where the
-- user released it rather than being re-anchored on the spot.
-- ---------------------------------------------------------------------------
local function ApplyStoredPosition(entry)
  local saved = U.GetPosition(entry.id)
  local position = saved or entry.default
  if not position then return false end

  local applied = U.ApplyFramePoint(entry.frame, position)
  if not applied then
    U.Debug("mover " .. entry.id .. ": failed to apply position")
    return false
  end

  if saved then
    U.Debug("mover " .. entry.id .. ": restored saved position")
  end
  return true
end

-- Snapping
--
-- The grid is only usable if a dropped frame is actually pulled onto it, and
-- the drag itself belongs to the client: StartMoving owns the frame's position
-- until StopMovingOrSizing, so the offsets can only be adjusted after the drop.
--
-- knowledge.json / frames.getpoint_relative_name_y_inverted lists "recapturing
-- then immediately clearing/reapplying the same point" as a failed approach,
-- while the same record confirms that applying a *stored* point with SetPoint
-- restores a frame correctly. The snap therefore captures and stores in the
-- drop handler, and re-applies from the store on the next shared-driver tick
-- rather than inside the handler itself.
local pendingSnap

local function ShiftHeld()
  local fn = U.G("IsShiftKeyDown")
  if type(fn) ~= "function" then return false end
  local ok, held = pcall(fn)
  if not ok then return false end
  return held and held ~= 0 and true or false
end

local function SnapValue(value)
  value = tonumber(value) or 0
  local pitch = GridPitch()
  return math.floor(value / pitch + 0.5) * pitch
end

local function ApplyPendingSnap()
  local entry = pendingSnap
  pendingSnap = nil
  U.UnregisterUpdate("mover.snap")
  if not entry then return end

  local stored = U.GetPosition(entry.id)
  if stored then U.ApplyFramePoint(entry.frame, stored) end
end

local function CapturePosition(entry)
  local point, relative, relativePoint, x, y = U.GetFramePoint(entry.frame, 1)
  if not point then
    U.Debug("mover " .. entry.id .. ": no readable anchor after drag")
    return false
  end

  -- Stored positions are always UIParent-relative. If the drag left the frame
  -- anchored to something else, say so rather than silently storing an offset
  -- that will be re-applied against a different origin.
  if relative and relative ~= UIParent then
    U.Debug("mover " .. entry.id ..
            ": anchored to a non-UIParent frame after drag; storing anyway")
  end

  -- Shift is the escape hatch for placements the grid cannot express. There is
  -- no compact-DB record for IsShiftKeyDown, so an absent or failing call reads
  -- as "not held" and the drop simply snaps.
  local snapped = false
  if not ShiftHeld() then
    local sx, sy = SnapValue(x), SnapValue(y)
    snapped = (sx ~= x) or (sy ~= y)
    x, y = sx, sy
  end

  local saved = U.SavePosition(entry.id, point, relativePoint, x, y)

  if saved and snapped then
    pendingSnap = entry
    U.RegisterUpdate("mover.snap", 0, ApplyPendingSnap)
  end

  return saved
end

-- ---------------------------------------------------------------------------
-- Dragging
--
-- The compact DB has no record at all for RegisterForDrag, StartMoving,
-- SetMovable or frame-level mouse input, so none of it can be assumed. The one
-- implementation of frame dragging demonstrably working on this client is
-- UnrealPfUI's dragger (modules/unlock.lua / CreateDragger), and the parts of
-- its recipe that QtUiPlus's first attempt did not follow are reproduced here:
--
--   * the handle is a **Button**, not a plain Frame. Buttons take mouse input
--     without EnableMouse, and Button is the only widget type this client is
--     known to deliver OnDragStart to.
--   * the handle is parented to the frame it moves and covers it with
--     SetAllPoints, rather than floating over it as a UIParent child.
--   * it is raised with SetFrameLevel rather than a strata change.
--   * SetMovable is applied immediately before each drag, not once at
--     registration.
--   * the real StartMoving is preceded by a StartMoving/StopMovingOrSizing
--     pair, which collapses a multi-point anchor down to the single point the
--     client will actually move.
--
-- Only the behaviour is reused; none of pfUI's selection, grid, scaling or dock
-- machinery is reproduced.
--
-- Failures here are reported through U.Error, not U.Debug: a mover that cannot
-- be dragged is the whole feature failing, and debug output is off by default.
-- ---------------------------------------------------------------------------
local function StartDrag(entry)
  local frame = entry.frame

  if not pcall(frame.SetMovable, frame, true) then
    U.Error("mover " .. entry.id .. ": SetMovable failed; frame cannot be moved")
    return false
  end

  if pcall(frame.StartMoving, frame) then
    pcall(frame.StopMovingOrSizing, frame)
  end

  if not pcall(frame.StartMoving, frame) then
    U.Error("mover " .. entry.id .. ": StartMoving failed; frame will not drag")
    return false
  end

  entry.dragging = true
  return true
end

local function StopDrag(entry)
  if not entry.dragging then return false end
  entry.dragging = false

  pcall(entry.frame.StopMovingOrSizing, entry.frame)
  return CapturePosition(entry)
end

-- ---------------------------------------------------------------------------
-- Drag handle
--
-- Created on first unlock and reused afterwards. knowledge.json /
-- scripts.child_onupdate_unreliable applies here: the handle is populated
-- synchronously at creation and never waits on an OnUpdate tick to become
-- usable.
--
-- The counters exist so /qtp check can report whether the client delivered
-- mouse and drag events at all. Without them a handle that never receives
-- OnDragStart is indistinguishable from one whose StartMoving failed.
-- ---------------------------------------------------------------------------
local handleCount = 0
local HANDLE_LEVEL_OFFSET = 10

local function CreateHandle(entry)
  handleCount = handleCount + 1

  -- Named because an unnamed Button gives the client nothing to report in an
  -- error, and the mover handles are exactly what a drag failure is about.
  local handle = CreateFrame("Button", "QtUiPlusMoverHandle" .. handleCount,
                             entry.frame)
  handle:SetAllPoints(entry.frame)
  handle:RegisterForDrag("LeftButton")

  -- A Button is mouse-enabled by default; this is belt and braces, and is
  -- pcall'd because the call is not verified on this client either.
  pcall(handle.EnableMouse, handle, true)

  local levelOk, level = pcall(entry.frame.GetFrameLevel, entry.frame)
  if levelOk and tonumber(level) then
    pcall(handle.SetFrameLevel, handle, level + HANDLE_LEVEL_OFFSET)
  end

  U.CreateBackdrop(handle, {
    background = M.color.mover,
    border = M.color.moverEdge,
  })

  -- knowledge.json / buttons.plain_settext_no_fontstring: an untemplated Button
  -- can accept SetText without ever showing a FontString, so the label is a
  -- FontString QtUiPlus creates and owns rather than the Button's own text.
  local label = U.CreateLabel(handle, {
    size = M.fontSize.small,
    color = M.color.text,
    inherits = "GameFontNormal",
  })
  if label then
    label:SetPoint("CENTER", handle, "CENTER", 0, 0)
    label:SetText(entry.label)
  end
  handle.label = label

  -- knowledge.json / scripts.handler_arguments_direct: handler argument shape
  -- is not guaranteed, so these close over `entry` instead of reading `this`.
  handle:SetScript("OnDragStart", function()
    entry.dragStarts = entry.dragStarts + 1
    StartDrag(entry)
  end)

  handle:SetScript("OnDragStop", function()
    entry.dragStops = entry.dragStops + 1
    StopDrag(entry)
  end)

  -- OnEnter is instrumentation as much as highlight: if the enter count stays
  -- at zero the client is not routing mouse input to the handle at all, which
  -- is a different failure from a drag that starts and does not move.
  handle:SetScript("OnEnter", function()
    entry.enters = entry.enters + 1
    U.SetBorderColor(handle, 0.2, 1.0, 0.8, 1)
  end)

  handle:SetScript("OnLeave", function()
    U.SetBorderColor(handle, M.Unpack(M.color.moverEdge))
  end)

  entry.handle = handle
  return handle
end

local function HideHandle(entry)
  if not entry.handle then return end
  if entry.handle.label then entry.handle.label:Hide() end
  entry.handle:Hide()
end

-- A module may register a frame that is not always part of the layout -- a
-- disabled action bar keeps its stored position but must not offer a handle to
-- drag. options.visible is that predicate; without one a mover is always shown.
local function IsEntryVisible(entry)
  if type(entry.visible) ~= "function" then return true end
  local ok, visible = pcall(entry.visible)
  if not ok then return true end
  return visible and true or false
end

local function ShowHandle(entry)
  if not IsEntryVisible(entry) then
    HideHandle(entry)
    return
  end

  if not entry.handle then CreateHandle(entry) end
  -- Aura rows (and similar) hide when empty. Edit mode still needs the
  -- handle, so the frame has to be shown first -- a child of a hidden parent
  -- never receives drags.
  if entry.frame and entry.frame.Show then pcall(entry.frame.Show, entry.frame) end
  entry.handle:Show()
  -- rendering.parent_alpha_not_propagated: children are shown and hidden
  -- explicitly rather than relying on the parent's visibility carrying.
  if entry.handle.label then entry.handle.label:Show() end
end

-- ---------------------------------------------------------------------------
-- Edit-mode overlay
--
-- The grid is plain textures on one full-screen frame: behavior.json /
-- textures.pfui_bar_path.v1 verifies that path, and it keeps the overlay off
-- backdrop edges, which are not reliably rasterised here.
--
-- Lines are laid out from UIParent's centre outwards so the grid is symmetric
-- and the centre axes land exactly on 0,0 -- the offsets a snapped drop
-- produces are multiples of GRID_SIZE from that same origin.
-- ---------------------------------------------------------------------------
local grid, editPanel

local function CreateGridLine(vertical, offset, color, length, thickness)
  local line = grid:CreateTexture(nil, "BACKGROUND")
  line:SetTexture(M.texture.plain)
  U.SetColor(line, M.Unpack(color))

  if vertical then
    line:SetWidth(thickness)
    line:SetHeight(length)
    line:SetPoint("CENTER", UIParent, "CENTER", offset, 0)
  else
    line:SetWidth(length)
    line:SetHeight(thickness)
    line:SetPoint("CENTER", UIParent, "CENTER", 0, offset)
  end

  return line
end

local function CreateGrid()
  grid = CreateFrame("Frame", "QtUiPlusGrid", UIParent)
  grid:SetAllPoints(UIParent)
  pcall(grid.SetFrameStrata, grid, "BACKGROUND")
  -- The grid is decoration; it must never eat a click meant for a handle.
  pcall(grid.EnableMouse, grid, false)

  local width, height = U.UIWidth(), U.UIHeight()
  local thickness = U.BorderSize()
  local offset

  CreateGridLine(true, 0, M.color.gridAxis, height, thickness)
  CreateGridLine(false, 0, M.color.gridAxis, width, thickness)

  local pitch = GridPitch()

  offset = pitch
  while offset < width / 2 do
    CreateGridLine(true, offset, M.color.grid, height, thickness)
    CreateGridLine(true, -offset, M.color.grid, height, thickness)
    offset = offset + pitch
  end

  offset = pitch
  while offset < height / 2 do
    CreateGridLine(false, offset, M.color.grid, width, thickness)
    CreateGridLine(false, -offset, M.color.grid, width, thickness)
    offset = offset + pitch
  end

  grid:Hide()
end

-- The edit panel is the only way out of edit mode that does not need a slash
-- command. It is deliberately not registered as a mover: it belongs to the mode
-- rather than to the layout.
local function CreateEditPanel()
  editPanel = U.CreatePanel(UIParent, {
    name = "QtUiPlusEditPanel",
    width = 280,
    height = 112,
  })
  editPanel:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  pcall(editPanel.SetFrameStrata, editPanel, "HIGH")

  local title = U.CreateLabel(editPanel, {
    size = M.fontSize.large,
    color = M.color.text,
    inherits = "GameFontNormal",
  })
  if title then
    title:SetPoint("TOP", editPanel, "TOP", 0, -12)
    title:SetText("QtUiPlus edit mode")
  end
  editPanel.title = title

  local hint = U.CreateLabel(editPanel, {
    size = M.fontSize.small,
    color = M.color.textDim,
    inherits = "GameFontNormalSmall",
  })
  if hint then
    hint:SetPoint("TOP", editPanel, "TOP", 0, -34)
    hint:SetText("Drag a frame to move it. It snaps to the grid.")
  end
  editPanel.hint = hint

  local hint2 = U.CreateLabel(editPanel, {
    size = M.fontSize.small,
    color = M.color.textDim,
    inherits = "GameFontNormalSmall",
  })
  if hint2 then
    hint2:SetPoint("TOP", editPanel, "TOP", 0, -50)
    hint2:SetText("Hold Shift while dropping for free placement.")
  end
  editPanel.hint2 = hint2

  editPanel.save = U.CreateButton(editPanel, {
    name = "QtUiPlusEditSave",
    text = "Save and exit",
    width = 140,
    height = 24,
    onClick = function() U.LockUI() end,
  })
  editPanel.save:SetPoint("BOTTOM", editPanel, "BOTTOM", 0, 12)

  editPanel:Hide()
end

-- rendering.parent_alpha_not_propagated: children are shown and hidden
-- explicitly rather than relying on the parent's visibility carrying.
local function ShowEditOverlay()
  if not grid then CreateGrid() end
  if not editPanel then CreateEditPanel() end

  grid:Show()
  editPanel:Show()
  if editPanel.title then editPanel.title:Show() end
  if editPanel.hint then editPanel.hint:Show() end
  if editPanel.hint2 then editPanel.hint2:Show() end
  if editPanel.save then editPanel.save:Show() end
end

local function HideEditOverlay()
  if grid then grid:Hide() end
  if not editPanel then return end

  if editPanel.title then editPanel.title:Hide() end
  if editPanel.hint then editPanel.hint:Hide() end
  if editPanel.hint2 then editPanel.hint2:Hide() end
  if editPanel.save then editPanel.save:Hide() end
  editPanel:Hide()
end

function U.GridSize()
  return GridPitch()
end

function U.GridSizeLimits()
  return GRID_LIMITS.min, GRID_LIMITS.max, GRID_LIMITS.step
end

-- Changing the pitch has to rebuild the grid artwork: the lines are created
-- once, at a fixed spacing, so a new pitch would otherwise snap frames onto a
-- grid that does not match the one being drawn.
function U.SetGridSize(value)
  local cfg = U.ModuleConfig("mover", { gridSize = GRID_SIZE })
  cfg.gridSize = U.Round(tonumber(value) or GRID_SIZE)

  if grid then
    -- The old grid frame is discarded rather than re-spaced: its lines are
    -- child regions created at a fixed offset each, and this client gives no
    -- way to destroy them individually. Hiding the old frame and building a
    -- fresh one is the only correct rebuild.
    local wasShown = grid:IsShown()
    pcall(grid.Hide, grid)
    grid = nil
    CreateGrid()
    if wasShown and grid then pcall(grid.Show, grid) end
  end

  return GridPitch()
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- id       stable string key, also the SavedVariables key
-- frame    the frame the user drags
-- options  { label = "Player", default = { point, relativePoint, x, y },
--            visible = function() return true end }
-- Re-points an existing mover at a different frame.
--
-- A window that can be closed and re-opened reuses its id (the damage meter
-- does exactly this), but the frame behind that id is a new object each time.
-- Without a rebind, RegisterMover rejects the duplicate id and the mover keeps
-- driving a frame the player can no longer see, so the new window is
-- unmovable. Returns false for an id that was never registered, so callers can
-- use it as a "rebind or register" test.
function U.RebindMover(id, frame)
  if type(id) ~= "string" or not frame then return false end
  local entry = movers[id]
  if not entry then return false end

  entry.frame = frame
  pcall(frame.SetMovable, frame, true)
  ApplyStoredPosition(entry)
  return true
end

function U.RegisterMover(id, frame, options)
  if type(id) ~= "string" or not frame then
    U.Error("RegisterMover requires an id and a frame")
    return nil
  end
  if movers[id] then
    U.Error("mover already registered: " .. id)
    return movers[id]
  end

  options = options or {}

  local entry = {
    id = id,
    frame = frame,
    label = options.label or id,
    default = options.default,
    visible = options.visible,
    dragging = false,
    -- Measured drag activity; reported by U.MoverReport.
    enters = 0,
    dragStarts = 0,
    dragStops = 0,
  }

  movers[id] = entry
  table.insert(moverOrder, id)

  pcall(frame.SetMovable, frame, true)
  -- Position is applied immediately, not deferred to a tick.
  ApplyStoredPosition(entry)

  if unlocked then ShowHandle(entry) end
  return entry
end

function U.IsUnlocked()
  return unlocked
end

function U.UnlockUI()
  unlocked = true
  if U.db then U.db.locked = false end

  ShowEditOverlay()

  local i
  for i = 1, table.getn(moverOrder) do
    ShowHandle(movers[moverOrder[i]])
  end

  U.Print("Edit mode. Drag frames onto the grid, then use " ..
          "|cffffff00Save and exit|r (or |cffffff00/qtp lock|r).")
end

function U.LockUI()
  unlocked = false
  if U.db then U.db.locked = true end

  HideEditOverlay()

  local i
  for i = 1, table.getn(moverOrder) do
    HideHandle(movers[moverOrder[i]])
  end

  U.Print("Layout saved. Edit mode closed.")
end

function U.ToggleUI()
  if unlocked then U.LockUI() else U.UnlockUI() end
end

-- Drops every saved position and puts each registered frame back on its
-- module-supplied default.
function U.ResetPositions()
  U.ClearAllPositions()

  local i, restored = nil, 0
  for i = 1, table.getn(moverOrder) do
    local entry = movers[moverOrder[i]]
    if ApplyStoredPosition(entry) then restored = restored + 1 end
  end

  U.Print("Reset " .. restored .. " frame position(s) to defaults.")
  return restored
end

function U.MoverCount()
  return table.getn(moverOrder)
end

-- Reports what the client actually did with each mover, so a drag that does not
-- work produces measured detail instead of a shrug. `enters` distinguishes "no
-- mouse input reached the handle" from "input arrived but the move failed", and
-- movable/mouse are read back rather than assumed from the setter succeeding.
function U.MoverReport()
  local report, i = {}, nil

  for i = 1, table.getn(moverOrder) do
    local entry = movers[moverOrder[i]]
    local line = {
      id = entry.id,
      enters = entry.enters,
      dragStarts = entry.dragStarts,
      dragStops = entry.dragStops,
      hasHandle = entry.handle and true or false,
      saved = U.GetPosition(entry.id) and true or false,
    }

    -- A readback of `false` is a real answer and must not be collapsed into the
    -- "call unavailable" case, so ok is tested on its own.
    local ok, value = pcall(entry.frame.IsMovable, entry.frame)
    if ok then line.movable = value else line.movable = "?" end

    line.mouse = "-"
    if entry.handle then
      ok, value = pcall(entry.handle.GetObjectType, entry.handle)
      if ok and value then line.handleType = value else line.handleType = "?" end

      ok, value = pcall(entry.handle.IsMouseEnabled, entry.handle)
      if ok then line.mouse = value else line.mouse = "?" end
    end

    local point, _, _, x, y = U.GetFramePoint(entry.frame, 1)
    line.point = point or "none"
    line.x = x
    line.y = y

    table.insert(report, line)
  end

  return report
end
