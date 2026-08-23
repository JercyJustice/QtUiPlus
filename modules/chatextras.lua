-- QtUiPlus :: modules/chatextras.lua
--
-- Three additions to the stock chat frames, ported from QtUI Chat.lua:
-- timestamps, class-coloured player names, and working mouse-wheel scrolling.
-- modules/chat.lua owns the resize grip and geometry; this file only touches
-- message text and scrolling, so the two do not overlap.
--
-- Two client-specific details drive the implementation, both recorded by QtUI
-- against this same client:
--
--  * Scrolling. This client's ScrollingMessageFrame exposes ScrollUp and
--    ScrollDown but NOT PageUp / PageDown, while the stock ChatFrame.lua still
--    calls frame:PageUp() from ChatFrame_ChatPageUp. Page keys therefore error
--    out unless the two page functions are replaced with repeated ScrollUp /
--    ScrollDown calls.
--
--  * Link colouring. This client ignores a |c colour code placed outside an
--    |h...|h link and paints the link from the Font object instead. The colour
--    has to be repeated INSIDE the visible link text, as a full 8-digit code,
--    or the name renders in the default link colour.
--
-- Class colours come from core/media.lua's M.ClassColor, which already prefers
-- the client's RAID_CLASS_COLORS and falls back to its own table -- this file
-- does not carry a second copy of the palette.

local U = QtUiPlus
local M = U.media

local C = U.RegisterModule("chatextras")

-- How many ScrollUp/ScrollDown calls one Page Up / Page Down should make.
local PAGE_STEPS = 8
-- Stock chat frame count on 1.12.
local NUM_CHAT_FRAMES = 7

-- Guild roster and some unit calls report a LOCALISED class name rather than
-- the uppercase English token M.ClassColor expects. This maps the ones this
-- client ships back to the token. A label that is not listed simply does not
-- colour, which is the same outcome as before the port.
local CLASS_FROM_LABEL = {
  warrior = "WARRIOR", krieger = "WARRIOR",
  mage = "MAGE", magier = "MAGE",
  rogue = "ROGUE", schurke = "ROGUE",
  druid = "DRUID", druide = "DRUID",
  hunter = "HUNTER", ["j\195\164ger"] = "HUNTER", jager = "HUNTER",
  shaman = "SHAMAN", schamane = "SHAMAN",
  priest = "PRIEST", priester = "PRIEST",
  warlock = "WARLOCK", hexenmeister = "WARLOCK",
  paladin = "PALADIN",
}

-- name (lowercased) -> class token. Populated opportunistically from whatever
-- units and rosters happen to be readable; a name that is never resolved just
-- renders white.
local classCache = {}
local pagingHooked = false

local FONT_LIMITS = { min = 8, max = 20, step = 1 }
local FONT_DEFAULT = 12
local chatCfg

local function FontSize()
  if not chatCfg then return FONT_DEFAULT end
  local size = U.Round(tonumber(chatCfg.fontSize) or FONT_DEFAULT)
  if size < FONT_LIMITS.min then size = FONT_LIMITS.min end
  if size > FONT_LIMITS.max then size = FONT_LIMITS.max end
  return size
end

-- Applies the configured size to every stock chat frame. U.SetFont resolves a
-- font path this client actually honours; a plain SetFont is a no-op here while
-- a Font object is attached, which is why it goes through the helper.
local function ApplyChatFont()
  local size = FontSize()
  local i
  for i = 1, NUM_CHAT_FRAMES do
    local frame = U.G("ChatFrame" .. i)
    if frame then U.SetFont(frame, size, "") end
  end
end

local function Truthy(value)
  return value == true or value == 1 or value == "1"
end

local function Layout()
  return QtP:GetLayout()
end

-- ---------------------------------------------------------------------------
-- Class colour resolution
-- ---------------------------------------------------------------------------

local function TokenFor(token)
  if type(token) ~= "string" or token == "" then return nil end
  local upper = string.upper(token)
  if M.ClassColor(upper) then return upper end
  return CLASS_FROM_LABEL[string.lower(token)]
end

local function RememberClass(name, token)
  if type(name) ~= "string" or name == "" then return end
  local resolved = TokenFor(token)
  if resolved then classCache[string.lower(name)] = resolved end
end

local function RememberUnit(unit)
  local unitName = U.G("UnitName")
  local unitClass = U.G("UnitClass")
  if type(unitName) ~= "function" or type(unitClass) ~= "function" then return end

  local exists = U.G("UnitExists")
  if type(exists) == "function" then
    local ok, value = pcall(exists, unit)
    if not ok or not Truthy(value) then return end
  end

  local nameOk, name = pcall(unitName, unit)
  if not nameOk or not name then return end
  -- UnitClass returns localised name first, English token second.
  local classOk, _, token = pcall(unitClass, unit)
  if classOk then RememberClass(name, token) end
end

local function ScanNearbyUnits()
  RememberUnit("player")
  RememberUnit("target")
  RememberUnit("mouseover")
  RememberUnit("pet")

  local i
  local partyCount = U.G("GetNumPartyMembers")
  local party = 0
  if type(partyCount) == "function" then
    local ok, value = pcall(partyCount)
    party = (ok and tonumber(value)) or 0
  end
  for i = 1, party do
    RememberUnit("party" .. i)
    RememberUnit("partypet" .. i)
  end

  local raidCount = U.G("GetNumRaidMembers")
  local raid = 0
  if type(raidCount) == "function" then
    local ok, value = pcall(raidCount)
    raid = (ok and tonumber(value)) or 0
  end
  local rosterInfo = U.G("GetRaidRosterInfo")
  for i = 1, raid do
    RememberUnit("raid" .. i)
    RememberUnit("raidpet" .. i)
    if type(rosterInfo) == "function" then
      local ok, name, _, _, _, _, fileName = pcall(rosterInfo, i)
      if ok then RememberClass(name, fileName) end
    end
  end
end

local function ScanGuildRoster()
  local count = U.G("GetNumGuildMembers")
  local info = U.G("GetGuildRosterInfo")
  if type(count) ~= "function" or type(info) ~= "function" then return end

  local ok, total = pcall(count)
  total = (ok and tonumber(total)) or 0

  local i
  for i = 1, total do
    local rowOk, name, _, _, _, class = pcall(info, i)
    if rowOk then RememberClass(name, class) end
  end
end

-- Returns a 6-digit hex string. White when the class is unknown, so an
-- unresolved name is still legible rather than invisible.
local function HexForName(name)
  if type(name) ~= "string" or name == "" then return "ffffff" end

  local key = string.lower(name)
  local token = classCache[key]
  if not token then
    -- A name in chat is very often someone on screen or in the group. One
    -- rescan on a miss is cheaper than polling the roster on a timer.
    ScanNearbyUnits()
    token = classCache[key]
  end
  if not token then return "ffffff" end

  local color = M.ClassColor(token)
  if not color then return "ffffff" end
  return string.format("%02x%02x%02x",
                       math.floor((color[1] or 1) * 255 + 0.5),
                       math.floor((color[2] or 1) * 255 + 0.5),
                       math.floor((color[3] or 1) * 255 + 0.5))
end

-- ---------------------------------------------------------------------------
-- Message rewriting
-- ---------------------------------------------------------------------------

-- Rebuilds every |Hplayer:...|h...|h link in `text` with the colour repeated
-- inside the link body. See the header note: an outer |c alone is ignored here.
local function ColorPlayerNames(text, byClass)
  if type(text) ~= "string" then return text end
  if not string.find(text, "|Hplayer:", 1, true) then return text end

  local out = ""
  local pos = 1
  local len = string.len(text)

  while pos <= len do
    local startAt, payloadEnd, payload = string.find(text, "|Hplayer:([^|]+)|h", pos)
    if not startAt then
      out = out .. string.sub(text, pos)
      break
    end

    local close = string.find(text, "|h", payloadEnd + 1, true)
    if not close then
      -- Unterminated link: emit the rest untouched rather than guessing where
      -- it should end and corrupting the line.
      out = out .. string.sub(text, pos)
      break
    end

    -- The visible label may already carry colour codes from another addon.
    -- Strip them so this one is not nested inside a stale colour.
    local display = string.sub(text, payloadEnd + 1, close - 1)
    display = string.gsub(display, "|c%x%x%x%x%x%x%x%x", "")
    display = string.gsub(display, "|r", "")
    if display == "" then display = payload end

    -- The payload is "Name" or "Name:extra"; only the name resolves a class.
    local name = payload
    local colon = string.find(name, ":", 1, true)
    if colon then name = string.sub(name, 1, colon - 1) end

    local hex = "ffffff"
    if byClass then hex = HexForName(name) end

    out = out .. string.sub(text, pos, startAt - 1)
      .. "|cff" .. hex .. "|Hplayer:" .. payload .. "|h|cff" .. hex
      .. display .. "|r|h|r"
    pos = close + 2
  end

  return out
end

local function TimeStamp()
  local dateFn = U.G("date")
  if type(dateFn) == "function" then
    local ok, value = pcall(dateFn, "%H:%M")
    if ok and type(value) == "string" and string.len(value) >= 4 then
      return value
    end
  end

  local gameTime = U.G("GetGameTime")
  if type(gameTime) == "function" then
    local ok, hour, minute = pcall(gameTime)
    if ok then
      return string.format("%02d:%02d", tonumber(hour) or 0, tonumber(minute) or 0)
    end
  end
  return nil
end

local function HookChatFrame(frame)
  if not frame or frame.qtpChatHooked then return end
  local original = frame.AddMessage
  if type(original) ~= "function" then return end
  frame.qtpChatHooked = true

  frame.AddMessage = function(self, text, r, g, b, id)
    local layout = Layout()

    if type(text) == "string" then
      if layout and layout.chatTime ~= false then
        -- Guard against double-stamping: this same frame can be re-hooked by
        -- another addon that re-enters AddMessage with an already-stamped line.
        if not string.find(text, "^|cff888888%[%d%d:%d%d%]") then
          local stamp = TimeStamp()
          if stamp then text = "|cff888888[" .. stamp .. "]|r " .. text end
        end
      end
      text = ColorPlayerNames(text, layout and Truthy(layout.chatClassNames))
    end

    -- Near-black text is unreadable on this client's dark chat background and
    -- is what several stock message types pass. Promote those to white rather
    -- than letting the line disappear.
    r = tonumber(r)
    g = tonumber(g)
    b = tonumber(b)
    if not r or not g or not b or (r <= .04 and g <= .04 and b <= .04) then
      r, g, b = 1, 1, 1
    end

    return original(self, text, r, g, b, id)
  end
end

local function HookAllChatFrames()
  local i
  for i = 1, NUM_CHAT_FRAMES do
    HookChatFrame(U.G("ChatFrame" .. i))
  end
  HookChatFrame(U.G("DEFAULT_CHAT_FRAME"))
end

-- ---------------------------------------------------------------------------
-- Scrolling
-- ---------------------------------------------------------------------------

local function ActiveChatFrame()
  return U.G("SELECTED_CHAT_FRAME") or U.G("SELECTED_DOCK_FRAME")
      or U.G("DEFAULT_CHAT_FRAME") or U.G("ChatFrame1")
end

local function ChatScroll(frame, direction, steps)
  if not frame then return end
  steps = tonumber(steps) or 1
  if steps < 1 then steps = 1 end

  local method
  if direction > 0 then method = frame.ScrollUp else method = frame.ScrollDown end
  if type(method) ~= "function" then return end

  local i
  for i = 1, steps do pcall(method, frame) end
end

local function HookPaging()
  if pagingHooked then return end
  pagingHooked = true

  U.SetG("ChatFrame_ChatPageUp", function()
    ChatScroll(ActiveChatFrame(), 1, PAGE_STEPS)
  end)
  U.SetG("ChatFrame_ChatPageDown", function()
    ChatScroll(ActiveChatFrame(), -1, PAGE_STEPS)
  end)

  -- The wheel handler is reached in more than one argument shape on this
  -- client (see core/init.lua on handler globals), so resolve the frame and
  -- the delta from whichever of the two actually arrived.
  U.SetG("ChatFrame_OnMouseWheel", function(a, b)
    local frame = a
    local wheel = tonumber(b)

    if type(frame) ~= "table" and type(frame) ~= "userdata" then
      wheel = tonumber(a) or tonumber(U.G("arg1")) or 0
      frame = U.G("this") or ActiveChatFrame()
    elseif not wheel then
      wheel = tonumber(U.G("arg1")) or 0
    end

    if wheel > 0 then
      ChatScroll(frame, 1, 1)
    elseif wheel < 0 then
      ChatScroll(frame, -1, 1)
    end
  end)
end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------
local function BuildSettingsPage(parent)
  local widgets = {}

  local header = U.CreateSectionHeader(parent, {
    text = "Chat", width = 484, y = -4,
  })
  table.insert(widgets, header)

  local timestamps = U.CreateCheckbox(parent, {
    name = "QtUiPlusChatTimestamps",
    text = "Timestamps",
    value = QtP:GetLayout().chatTime ~= false,
    onChange = function(value)
      QtP:GetLayout().chatTime = value and true or false
    end,
  })
  timestamps.SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -34)
  table.insert(widgets, timestamps)

  local classNames = U.CreateCheckbox(parent, {
    name = "QtUiPlusChatClassNames",
    text = "Class-coloured player names",
    value = QtP:GetLayout().chatClassNames ~= false,
    onChange = function(value)
      QtP:GetLayout().chatClassNames = value and true or false
    end,
  })
  classNames.SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -58)
  table.insert(widgets, classNames)

  local font = U.CreateSlider(parent, {
    name = "QtUiPlusChatFontSize",
    text = "Chat Font Size",
    width = 200,
    min = FONT_LIMITS.min, max = FONT_LIMITS.max, step = FONT_LIMITS.step,
    value = FontSize(),
    onChange = function(value)
      if chatCfg then chatCfg.fontSize = value end
      ApplyChatFont()
    end,
  })
  font.SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -102)
  table.insert(widgets, font)

  local hint = U.CreateSettingsLabel(parent, {
    size = M.fontSize.small, color = M.color.textDim,
    inherits = "GameFontNormalSmall", justify = "LEFT",
  })
  if hint then
    U.AnchorSettingsDescription(hint, font.box,
                                -math.floor((font.width - font.boxWidth) / 2))
    hint:SetText("Chat width and height are set by dragging the grip on the " ..
                 "bottom-right corner of the chat window.")
    table.insert(widgets, hint)
  end

  local function Refresh()
    local layout = QtP:GetLayout()
    timestamps.SetValue(layout.chatTime ~= false)
    classNames.SetValue(layout.chatClassNames ~= false)
    font.SetValue(FontSize())
  end

  return widgets, Refresh
end

function C:OnInit()
  chatCfg = U.ModuleConfig("chatextras", { fontSize = FONT_DEFAULT })
  if type(U.RegisterSettingsTab) == "function" then
    U.RegisterSettingsTab("chatextras", "Chat", BuildSettingsPage)
  end
end

function C:OnEnable()
  if not chatCfg then
    chatCfg = U.ModuleConfig("chatextras", { fontSize = FONT_DEFAULT })
  end
  ApplyChatFont()
  HookAllChatFrames()
  HookPaging()

  -- Seed the class cache from whatever is already known, then keep it current
  -- from the events that introduce new names.
  ScanNearbyUnits()

  U.RegisterEvent("PLAYER_TARGET_CHANGED", function() RememberUnit("target") end)
  U.RegisterEvent("UPDATE_MOUSEOVER_UNIT", function() RememberUnit("mouseover") end)
  U.RegisterEvent("PARTY_MEMBERS_CHANGED", ScanNearbyUnits)
  U.RegisterEvent("RAID_ROSTER_UPDATE", ScanNearbyUnits)
  U.RegisterEvent("GUILD_ROSTER_UPDATE", ScanGuildRoster)

  -- Ask for the guild roster once so guildmates colour before they are ever
  -- targeted. GUILD_ROSTER_UPDATE above picks up every refresh after this.
  local request = U.G("GuildRoster")
  if type(request) == "function" then pcall(request) end
end
