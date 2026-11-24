-------------------------------------------------------------------------------
-- Guild kill tracker: high scores for honorable kills, weekly and all-time,
-- split into world PvP kills and battleground/arena kills.
--
-- Counting: 12.x addons can't read the combat log, so kills come from the
-- game's own honorable kill counters. When a counter goes up, the new kills
-- count as world kills only if we were in the open world both at the last
-- check and now. Anything near a battleground or arena counts as instanced.
-- Honorable kills are kills you took part in, not killing blows, and the game
-- doesn't award them for gray-level targets.
--
-- Two counters are read because older honor systems update the lifetime total
-- only at the daily honor calculation, while the "today" count moves straight
-- away. Each kill is counted once, whichever counter shows it first: each
-- counter keeps a tally of credited kills it hasn't shown yet.
--
-- Sharing: like the buff tracker, each player's addon broadcasts its own
-- totals to the guild.
-------------------------------------------------------------------------------
local _, ns = ...
ns = ns or {}
local SafeCall = ns.SafeCall or function(fn, ...) return fn(...) end
local RecordError = ns.RecordError or function() end
local T = ns.tracker
if not T then
    return
end

local PREFIX = "GIGAKILL"
local TICK_INTERVAL = 5
local BROADCAST_INTERVAL = 60
local REQUEST_REPLY_INTERVAL = 60
local BOARD_EXPIRY = 90 * 24 * 60 * 60
local LEADERBOARD_SIZE = 10
-- The counters can read 0 until PvP stats load after login, so changes in
-- this window only move the starting point.
local LOGIN_GRACE = 60

local db = nil -- Giga_KillTracker (saved per character)
local me = nil -- character name
local lastInWorld = nil -- open world at the last check
local loginTime = nil
local dirty = false
local lastBroadcast = 0
local lastRequestReply = 0
local RefreshScores -- defined with the UI

-------------------------------------------------------------------------------
-- Reading the game's counters
-------------------------------------------------------------------------------
local function ReadCount(fn)
    if not fn then
        return nil
    end

    local ok, value = pcall(fn)
    if ok and type(value) == "number" and T.IsReadable(value) and value >= 0 then
        return value
    end

    return nil
end

local function InOpenWorld()
    if not IsInInstance then
        return true
    end

    local _, instanceType = IsInInstance()
    if not T.IsReadable(instanceType) then
        return false
    end

    return instanceType == nil or instanceType == "none"
end

-------------------------------------------------------------------------------
-- Saved data
-------------------------------------------------------------------------------
local function NewPeriod()
    return { world = 0, instanced = 0 }
end

local function ValidPeriod(period)
    return type(period) == "table"
        and type(period.world) == "number"
        and type(period.instanced) == "number"
end

local function CheckWeek()
    local key = T.GetWeekKey()
    if db.weekKey ~= key then
        db.weekKey = key
        db.weekly = NewPeriod()
        dirty = true
    end
end

local function InitDB()
    if type(Giga_KillTracker) ~= "table" then
        Giga_KillTracker = {}
    end

    db = Giga_KillTracker
    if not ValidPeriod(db.allTime) then db.allTime = NewPeriod() end
    if not ValidPeriod(db.weekly) then db.weekly = NewPeriod() end
    if type(db.aheadLifetime) ~= "number" or db.aheadLifetime < 0 then db.aheadLifetime = 0 end
    if type(db.aheadSession) ~= "number" or db.aheadSession < 0 then db.aheadSession = 0 end
    if type(db.board) ~= "table" then db.board = {} end
    if not db.namesOnly then
        db.board = T.RekeyBoard(db.board)
        db.namesOnly = true
    end

    -- Earlier versions could credit kills made before installing, from a
    -- counter read before PvP stats loaded. Start those totals over.
    if not db.loginGraceFix then
        db.allTime = NewPeriod()
        db.weekly = NewPeriod()
        db.lifetime, db.session = nil, nil
        db.aheadLifetime, db.aheadSession = 0, 0
        db.loginGraceFix = true
    end

    local now = T.Now()
    for name, entry in pairs(db.board) do
        if type(entry) ~= "table" or type(entry.seen) ~= "number" or now - entry.seen > BOARD_EXPIRY then
            db.board[name] = nil
        end
    end

    CheckWeek()
end

-- A reading lower than the saved count is a counter that hasn't loaded yet
-- (after login or a loading screen): the lifetime total never goes down, and
-- a reset of the daily count shows as a lower count once the next kill lands.
local function ReadLifetime()
    local lifetime = ReadCount(GetPVPLifetimeStats)
    if lifetime and type(db.lifetime) == "number" and lifetime < db.lifetime then
        return nil
    end

    return lifetime
end

local function ReadSession()
    local session = ReadCount(GetPVPSessionStats)
    if session == 0 and type(db.session) == "number" and db.session > 0 then
        return nil
    end

    return session
end

-- Start counting from the game's current totals. Kills already on the
-- character, or made while the addon wasn't running, are never credited.
local function SyncBaseline()
    local lifetime = ReadLifetime()
    if lifetime then
        if type(db.lifetime) == "number" then
            -- Kills credited from the daily count may have reached the
            -- lifetime total while we were away.
            db.aheadLifetime = math.max(0, db.aheadLifetime - (lifetime - db.lifetime))
        end

        db.lifetime = lifetime
    end

    local session = ReadSession()
    if session then
        db.session = session
        db.aheadSession = 0
    end

    lastInWorld = InOpenWorld()
end

-------------------------------------------------------------------------------
-- Crediting kills
-------------------------------------------------------------------------------
local function CreditKills(count, inWorld)
    CheckWeek()
    local field = inWorld and "world" or "instanced"
    db.weekly[field] = db.weekly[field] + count
    db.allTime[field] = db.allTime[field] + count
    dirty = true

    if RefreshScores then
        SafeCall(RefreshScores)
    end
end

local function CheckKills()
    if not db then
        return
    end

    if not loginTime or T.Now() - loginTime < LOGIN_GRACE then
        SyncBaseline()
        return
    end

    local inWorld = InOpenWorld()
    local lifetimeDelta, sessionDelta = 0, 0

    local lifetime = ReadLifetime()
    if lifetime then
        if type(db.lifetime) == "number" then
            lifetimeDelta = lifetime - db.lifetime
        end

        db.lifetime = lifetime
    end

    local session = ReadSession()
    if session then
        if type(db.session) == "number" then
            if session >= db.session then
                sessionDelta = session - db.session
            else
                -- The daily count reset since the last check.
                sessionDelta = session
                db.aheadSession = 0
            end
        end

        db.session = session
    end

    -- ahead*: kills already credited that this counter hasn't shown yet.
    local new = math.max(0, lifetimeDelta - db.aheadLifetime, sessionDelta - db.aheadSession)
    db.aheadLifetime = db.aheadLifetime + new - lifetimeDelta
    db.aheadSession = db.aheadSession + new - sessionDelta

    if new > 0 then
        CreditKills(new, inWorld and lastInWorld ~= false)
    end

    lastInWorld = inWorld
end

-------------------------------------------------------------------------------
-- Addon messages
-------------------------------------------------------------------------------
local THROTTLED_RESULTS = { [3] = true, [8] = true } -- AddonMessageThrottle, ChannelThrottle

-- Returns false if the message should be retried later.
local function TrySend(msg)
    if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then
        return true
    end

    if C_ChatInfo.InChatMessagingLockdown then
        local okLockdown, locked = pcall(C_ChatInfo.InChatMessagingLockdown)
        if okLockdown and locked then
            return false
        end
    end

    local ok, result = pcall(C_ChatInfo.SendAddonMessage, PREFIX, msg, "GUILD")
    if not ok then
        RecordError(result)
        return true
    end

    return not THROTTLED_RESULTS[result]
end

local function BroadcastStats()
    if not (IsInGuild and IsInGuild()) then
        return
    end

    CheckWeek()
    local w, a = db.weekly, db.allTime
    local msg = table.concat({ "S", db.weekKey, w.world, w.instanced, a.world, a.instanced }, "\t")
    if TrySend(msg) then
        lastBroadcast = T.Now()
        dirty = false
    else
        dirty = true -- the tick tries again
    end
end

local function OnStatsReceived(sender, fields)
    local values = {}
    for i = 2, 6 do
        local n = tonumber(fields[i])
        if not n or n < 0 or n ~= math.floor(n) then
            return
        end

        values[#values + 1] = n
    end

    db.board[sender] = {
        weekKey = values[1],
        weeklyWorld = values[2], weeklyInstanced = values[3],
        allWorld = values[4], allInstanced = values[5],
        seen = T.Now(),
    }

    if RefreshScores then
        SafeCall(RefreshScores)
    end
end

local function OnAddonMessage(prefix, text, channel, sender)
    if prefix ~= PREFIX
        or type(text) ~= "string"
        or not T.IsReadable(text)
        or not T.IsReadable(channel)
        or channel ~= "GUILD"
    then
        return
    end

    sender = T.NormalizeName(sender)
    if not sender or sender == me then
        return
    end

    local fields = T.Split(text)
    if fields[1] == "S" then
        OnStatsReceived(sender, fields)
    elseif fields[1] == "R" then
        local now = T.Now()
        if now - lastRequestReply >= REQUEST_REPLY_INTERVAL then
            lastRequestReply = now
            -- Spread replies out so a request doesn't flood guild chat.
            C_Timer.After(2 + math.random() * 8, function()
                SafeCall(BroadcastStats)
            end)
        end
    end
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_PVP_KILLS_CHANGED")
events:RegisterEvent("CHAT_MSG_ADDON")

local handlers = {}

function handlers.ADDON_LOADED(name)
    if name ~= "TwitchEmotes_Giga" then
        return
    end

    events:UnregisterEvent("ADDON_LOADED")
    InitDB()
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    end
end

function handlers.PLAYER_LOGIN()
    me = T.UnitNormalizedName("player")
    loginTime = T.Now()
    SyncBaseline()

    -- Let the guild channel settle, then share and ask for everyone's scores.
    C_Timer.After(10, function()
        SafeCall(BroadcastStats)
        if IsInGuild and IsInGuild() then
            TrySend("R")
        end
    end)

    -- Polling also catches kills if the counter event doesn't fire.
    C_Timer.NewTicker(TICK_INTERVAL, function()
        SafeCall(CheckKills)
        SafeCall(CheckWeek)
        if dirty and T.Now() - lastBroadcast >= BROADCAST_INTERVAL then
            SafeCall(BroadcastStats)
        end
    end)
end

-- Settle kills made before a loading screen. lastInWorld still holds where
-- we were before it, so kills made just before leaving a battleground count
-- as instanced.
function handlers.PLAYER_ENTERING_WORLD()
    if me then
        CheckKills()
    end
end

function handlers.PLAYER_PVP_KILLS_CHANGED(unit)
    if not me or (unit ~= nil and unit ~= "player") then
        return
    end

    CheckKills()
    -- The counters can lag the event a little.
    C_Timer.After(1, function()
        SafeCall(CheckKills)
    end)
end

function handlers.CHAT_MSG_ADDON(prefix, text, channel, sender)
    if db then
        OnAddonMessage(prefix, text, channel, sender)
    end
end

events:SetScript("OnEvent", function(_, event, ...)
    local handler = handlers[event]
    if handler then
        SafeCall(handler, ...)
    end
end)

-------------------------------------------------------------------------------
-- High scores tab
-------------------------------------------------------------------------------
local panel = ns.killPanel
if not panel then
    return
end

local METRICS = {
    { title = "World PvP kills", weekly = "weeklyWorld", allTime = "allWorld", own = "world" },
    { title = "Battleground & arena kills", weekly = "weeklyInstanced", allTime = "allInstanced", own = "instanced" },
}
local COLUMN_X = { 110, 370 }
local ROW_HEIGHT = 18

local showWeekly = true

local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", panel, "TOP", 0, -32)
title:SetText("Kill High Scores")

local weeklyButton = CreateFrame("Button", nil, panel, "GameMenuButtonTemplate")
weeklyButton:SetSize(100, 22)
weeklyButton:SetPoint("TOPRIGHT", panel, "TOP", -4, -58)
weeklyButton:SetText("This week")

local allTimeButton = CreateFrame("Button", nil, panel, "GameMenuButtonTemplate")
allTimeButton:SetSize(100, 22)
allTimeButton:SetPoint("TOPLEFT", panel, "TOP", 4, -58)
allTimeButton:SetText("All time")

local columns = {}
for i, metric in ipairs(METRICS) do
    local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    header:SetPoint("TOPLEFT", panel, "TOPLEFT", COLUMN_X[i], -100)
    header:SetText(metric.title)

    local rows = {}
    for r = 1, LEADERBOARD_SIZE do
        local row = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row:SetPoint("TOPLEFT", panel, "TOPLEFT", COLUMN_X[i], -100 - r * ROW_HEIGHT)
        row:SetWidth(220)
        row:SetJustifyH("LEFT")
        rows[r] = row
    end

    local own = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    own:SetPoint("TOPLEFT", panel, "TOPLEFT", COLUMN_X[i], -100 - (LEADERBOARD_SIZE + 1.5) * ROW_HEIGHT)
    own:SetWidth(220)
    own:SetJustifyH("LEFT")

    columns[i] = { rows = rows, own = own }
end

local note = panel:CreateFontString(nil, "OVERLAY", "GameFontDisable")
note:SetPoint("BOTTOM", panel, "BOTTOM", 0, 48)
note:SetWidth(540)
note:SetText("Honorable kills counted since installing Giga, shared by each guildie's addon. World PvP means kills outside battlegrounds and arenas.")

local function CollectEntries(metric)
    local entries = {}
    local guildMembers = T.GetGuildMembers()
    local filterByGuild = next(guildMembers) ~= nil
    for name, entry in pairs(db.board) do
        if name ~= me and (not filterByGuild or guildMembers[name]) then
            local value
            if showWeekly then
                value = (entry.weekKey == db.weekKey) and entry[metric.weekly] or 0
            else
                value = entry[metric.allTime]
            end

            if type(value) == "number" and value > 0 then
                entries[#entries + 1] = { name = name, value = value }
            end
        end
    end

    local period = showWeekly and db.weekly or db.allTime
    if me then
        entries[#entries + 1] = { name = me, value = period[metric.own], isMe = true }
    end

    table.sort(entries, function(a, b)
        if a.value ~= b.value then
            return a.value > b.value
        end

        return a.name < b.name
    end)

    return entries
end

RefreshScores = function()
    if not db or not panel:IsShown() then
        return
    end

    CheckWeek()
    if showWeekly then
        weeklyButton:LockHighlight()
        allTimeButton:UnlockHighlight()
    else
        allTimeButton:LockHighlight()
        weeklyButton:UnlockHighlight()
    end

    for i, metric in ipairs(METRICS) do
        local entries = CollectEntries(metric)
        local column = columns[i]
        local myRank, myValue = nil, 0

        for rank, entry in ipairs(entries) do
            if entry.isMe then
                myRank, myValue = rank, entry.value
            end
        end

        for r = 1, LEADERBOARD_SIZE do
            local entry = entries[r]
            if entry and (entry.value > 0 or entry.isMe) then
                local color = entry.isMe and "|cFFFFD100" or ""
                local reset = entry.isMe and "|r" or ""
                column.rows[r]:SetText(color .. r .. ". " .. entry.name .. "  " .. entry.value .. reset)
            else
                column.rows[r]:SetText("")
            end
        end

        if myRank then
            column.own:SetText("You: #" .. myRank .. " (" .. myValue .. ")")
        else
            column.own:SetText("")
        end
    end
end

weeklyButton:SetScript("OnClick", function()
    showWeekly = true
    SafeCall(RefreshScores)
end)

allTimeButton:SetScript("OnClick", function()
    showWeekly = false
    SafeCall(RefreshScores)
end)

panel:HookScript("OnShow", function()
    SafeCall(RefreshScores)
end)
