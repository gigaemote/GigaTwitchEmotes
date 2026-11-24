-------------------------------------------------------------------------------
-- Guild buff tracker: high scores for unique guildies buffed, buffs applied
-- and buffs received, weekly and all-time.
--
-- Counting: when you cast a tracked buff on a guildie, your addon credits you
-- and whispers them so their addon credits a buff received. A caster gets
-- credit for the same guildie and buff family at most once per buff duration,
-- so recasting or refreshing a buff never raises a score, and the single and
-- group versions of a buff share one window.
--
-- Sharing: each player's addon broadcasts its own totals to the guild and the
-- leaderboard shows the latest totals heard from each guildie. Scores are
-- reported by each player's own addon.
-------------------------------------------------------------------------------
local _, ns = ...
ns = ns or {}
local SafeCall = ns.SafeCall or function(fn, ...) return fn(...) end
local RecordError = ns.RecordError or function() end

local PREFIX = "GIGABUFF"
local WEEK_SECONDS = 7 * 24 * 60 * 60
local MIN_CREDIT_WINDOW = 60
local MAX_CREDIT_WINDOW = 2 * 60 * 60
local AURA_CHECK_DELAY = 0.5
local TICK_INTERVAL = 5
local BROADCAST_INTERVAL = 60
local REQUEST_REPLY_INTERVAL = 60
local BOARD_EXPIRY = 90 * 24 * 60 * 60
local MAX_OUTBOX = 50
local LEADERBOARD_SIZE = 10

-- WoW Forever buff spells, from EllesmereUI's FOREVER_BUFF_FAMILIES.
-- single/group: the ranks players cast. names: spells whose localized names
-- cover every rank, used to find the buff on a player. duration: fallback in
-- seconds when the aura's real duration can't be read. minWindow: optional
-- shortest time between credits, for buffs shorter than that.
local FAMILIES = {
    fortitude = {
        single = { 1243, 1244, 1245, 2791, 10937, 10938 }, group = { 21562, 21564 },
        names = { 1243, 21562 }, duration = 30 * 60, groupDuration = 60 * 60,
    },
    wild = {
        single = { 1126, 5232, 6756, 5234, 8907, 9884, 9885 }, group = { 21849, 21850 },
        names = { 1126, 21849 }, duration = 30 * 60, groupDuration = 60 * 60,
    },
    spirit = {
        single = { 14752, 14818, 14819, 27841 }, group = { 27681 },
        names = { 14752, 27681 }, duration = 30 * 60, groupDuration = 60 * 60,
    },
    thorns = {
        single = { 467, 782, 1075, 8914, 9756, 9910 }, group = {},
        names = { 467 }, duration = 10 * 60,
    },
    intellect = {
        single = { 1459, 1460, 1461, 10156, 10157 }, group = { 23028 },
        names = { 1459, 23028 }, duration = 30 * 60, groupDuration = 60 * 60,
    },
    might = {
        single = { 19740, 19834, 19835, 19836, 19837, 19838, 25291 }, group = { 25782, 25916 },
        names = { 19740, 25782 }, duration = 5 * 60, groupDuration = 15 * 60,
    },
    wisdom = {
        single = { 19742, 19850, 19852, 19853, 19854, 25290 }, group = { 25894, 25918 },
        names = { 19742, 25894 }, duration = 5 * 60, groupDuration = 15 * 60,
    },
    kings = {
        single = { 20217 }, group = { 25898 },
        names = { 20217, 25898 }, duration = 5 * 60, groupDuration = 15 * 60,
    },
    salvation = {
        single = { 1038 }, group = { 25895 },
        names = { 1038, 25895 }, duration = 5 * 60, groupDuration = 15 * 60,
    },
    -- Not in EllesmereUI's list, which only covers raid buffs.
    shadowProt = {
        single = { 976, 10957, 10958 }, group = { 27683 },
        names = { 976, 27683 }, duration = 10 * 60, groupDuration = 20 * 60,
    },
    light = {
        single = { 19977, 19978, 19979 }, group = { 25890 },
        names = { 19977, 25890 }, duration = 5 * 60, groupDuration = 15 * 60,
    },
    sanctuary = {
        single = { 20911, 20912, 20913, 20914 }, group = { 25899 },
        names = { 20911, 25899 }, duration = 5 * 60, groupDuration = 15 * 60,
    },
    amplify = {
        single = { 1008, 8455, 10169, 10170 }, group = {},
        names = { 1008 }, duration = 10 * 60,
    },
    dampen = {
        single = { 604, 8450, 8451, 10173, 10174 }, group = {},
        names = { 604 }, duration = 10 * 60,
    },
    -- Cast by using a soulstone item; every size gives Soulstone Resurrection.
    soulstone = {
        single = { 20707, 20762, 20763, 20764, 20765 }, group = {},
        names = { 20707 }, duration = 30 * 60,
    },
    fearWard = {
        single = { 6346 }, group = {},
        names = { 6346 }, duration = 10 * 60,
    },
    breath = {
        single = { 5697 }, group = {},
        names = { 5697 }, duration = 10 * 60,
    },
    waterBreathing = {
        single = { 131 }, group = {},
        names = { 131 }, duration = 10 * 60,
    },
    waterWalking = {
        single = { 546 }, group = {},
        names = { 546 }, duration = 10 * 60,
    },
    -- Short buffs credit at most once per minWindow, so recasting them on
    -- the same guildie can't farm a score.
    levitate = {
        single = { 1706 }, group = {},
        names = { 1706 }, duration = 2 * 60, minWindow = 10 * 60,
    },
    slowFall = {
        single = { 130 }, group = {},
        names = { 130 }, duration = 30, minWindow = 10 * 60,
    },
    -- Lesser, normal and greater are separate spells with their own names.
    detectInvis = {
        single = { 132, 2970, 11743 }, group = {},
        names = { 132, 2970, 11743 }, duration = 10 * 60,
    },
}

-- spell ID -> { family = key, group = bool }
local CAST_SPELLS = {}
for key, family in pairs(FAMILIES) do
    for _, id in ipairs(family.single) do
        CAST_SPELLS[id] = { family = key, group = false }
    end

    for _, id in ipairs(family.group) do
        CAST_SPELLS[id] = { family = key, group = true }
    end
end

local db = nil -- Giga_BuffTracker (saved per character)
local me = nil -- character name
local guildMembers = {} -- "Name" -> full name from the roster, for whispers
local pendingTargets = {} -- castGUID -> target name from UNIT_SPELLCAST_SENT
local outbox = {}
local dirty = false
local lastBroadcast = 0
local lastRequestReply = 0
local RefreshScores -- defined with the UI

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------
local function IsReadable(value)
    return not (issecretvalue and issecretvalue(value))
end

local function Now()
    return GetServerTime and GetServerTime() or time()
end

-- Players are identified by character name alone. Names arrive in several
-- forms, e.g. "Name", "Name-Realm" or, on Forever, "Name Realm-ShardLayer",
-- and character names can't contain spaces or hyphens.
local function NormalizeName(name)
    if type(name) ~= "string" or not IsReadable(name) then
        return nil
    end

    return name:match("^[^%s%-]+")
end

local function UnitNormalizedName(unit)
    if not UnitExists(unit) or not UnitIsPlayer(unit) then
        return nil
    end

    return NormalizeName((UnitName(unit)))
end

local function ClampWindow(seconds, minWindow)
    minWindow = minWindow or MIN_CREDIT_WINDOW
    seconds = tonumber(seconds) or minWindow
    return math.max(minWindow, math.min(MAX_CREDIT_WINDOW, math.floor(seconds)))
end

local function Split(text)
    local fields = {}
    for field in text:gmatch("[^\t]+") do
        fields[#fields + 1] = field
    end

    return fields
end

-- Start of the current weekly reset, rounded so every client agrees.
local function GetWeekKey()
    local now = Now()
    local untilReset = C_DateAndTime
        and C_DateAndTime.GetSecondsUntilWeeklyReset
        and C_DateAndTime.GetSecondsUntilWeeklyReset()
    if type(untilReset) == "number" and untilReset > 0 then
        local weekStart = now + untilReset - WEEK_SECONDS
        return math.floor(weekStart / 3600 + 0.5) * 3600
    end

    return math.floor(now / WEEK_SECONDS) * WEEK_SECONDS
end

-- Whether unit has the family's buff. Returns has, duration; has is nil when
-- the game is hiding aura data (secret values), so the caller can't tell.
local function FindFamilyAura(unit, familyKey, filter)
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName and C_Spell and C_Spell.GetSpellName) then
        return nil
    end

    local unreadable = false
    for _, id in ipairs(FAMILIES[familyKey].names) do
        local spellName = C_Spell.GetSpellName(id)
        if spellName and IsReadable(spellName) then
            local ok, aura = pcall(C_UnitAuras.GetAuraDataBySpellName, unit, spellName, filter)
            if not ok or not IsReadable(aura) then
                unreadable = true
            elseif type(aura) == "table" then
                local duration = aura.duration
                if type(duration) == "number" and IsReadable(duration) and duration > 0 then
                    return true, duration
                end

                return true, nil
            end
        end
    end

    if unreadable then
        return nil
    end

    return false
end

local function ForEachGroupUnit(fn)
    if IsInRaid and IsInRaid() then
        for i = 1, (GetNumGroupMembers() or 0) do
            fn("raid" .. i)
        end
    elseif IsInGroup and IsInGroup() then
        for i = 1, 4 do
            fn("party" .. i)
        end
    end
end

local function FindUnitForName(name)
    for _, unit in ipairs({ "target", "mouseover", "focus" }) do
        if UnitNormalizedName(unit) == name then
            return unit
        end
    end

    local found = nil
    ForEachGroupUnit(function(unit)
        if not found and UnitNormalizedName(unit) == name then
            found = unit
        end
    end)

    return found
end

-------------------------------------------------------------------------------
-- Saved data
-------------------------------------------------------------------------------
local function NewPeriod()
    return { applied = 0, received = 0, unique = {}, uniqueCount = 0 }
end

local function ValidPeriod(period)
    return type(period) == "table"
        and type(period.applied) == "number"
        and type(period.received) == "number"
        and type(period.unique) == "table"
        and type(period.uniqueCount) == "number"
end

local function CheckWeek()
    local key = GetWeekKey()
    if db.weekKey ~= key then
        db.weekKey = key
        db.weekly = NewPeriod()
        dirty = true
    end
end

local function PruneExpired(windows, now)
    for key, untilTime in pairs(windows) do
        if type(untilTime) ~= "number" or untilTime <= now then
            windows[key] = nil
        end
    end
end

-- Saved data from before players were identified by name alone used
-- "Name-Realm" keys. These convert it, merging anyone listed twice.
local function RekeyBoard(board)
    local rekeyed = {}
    for key, entry in pairs(board) do
        local name = NormalizeName(key)
        local existing = name and rekeyed[name]
        if name and type(entry) == "table" and type(entry.seen) == "number"
            and not (existing and existing.seen >= entry.seen)
        then
            rekeyed[name] = entry
        end
    end

    return rekeyed
end

-- Keys are "player|family"; keeps the later expiry when two merge.
local function RekeyWindows(windows)
    local rekeyed = {}
    for key, untilTime in pairs(windows) do
        local player, family = tostring(key):match("^(.*)|([^|]+)$")
        local name = NormalizeName(player)
        if name and type(untilTime) == "number" then
            local newKey = name .. "|" .. family
            rekeyed[newKey] = math.max(rekeyed[newKey] or 0, untilTime)
        end
    end

    return rekeyed
end

local function RekeyUnique(period)
    local unique, count = {}, 0
    for key in pairs(period.unique) do
        local name = NormalizeName(key)
        if name and not unique[name] then
            unique[name] = true
            count = count + 1
        end
    end

    period.unique, period.uniqueCount = unique, count
end

local function InitDB()
    if type(Giga_BuffTracker) ~= "table" then
        Giga_BuffTracker = {}
    end

    db = Giga_BuffTracker
    if not ValidPeriod(db.allTime) then db.allTime = NewPeriod() end
    if not ValidPeriod(db.weekly) then db.weekly = NewPeriod() end
    if type(db.creditUntil) ~= "table" then db.creditUntil = {} end
    if type(db.receivedUntil) ~= "table" then db.receivedUntil = {} end
    if type(db.board) ~= "table" then db.board = {} end

    if not db.namesOnly then
        db.board = RekeyBoard(db.board)
        db.creditUntil = RekeyWindows(db.creditUntil)
        db.receivedUntil = RekeyWindows(db.receivedUntil)
        RekeyUnique(db.allTime)
        RekeyUnique(db.weekly)
        db.namesOnly = true
    end

    local now = Now()
    PruneExpired(db.creditUntil, now)
    PruneExpired(db.receivedUntil, now)
    for name, entry in pairs(db.board) do
        if type(entry) ~= "table" or type(entry.seen) ~= "number" or now - entry.seen > BOARD_EXPIRY then
            db.board[name] = nil
        end
    end

    CheckWeek()
end

local function AddToPeriod(period, field, guildie)
    period[field] = period[field] + 1
    if guildie and not period.unique[guildie] then
        period.unique[guildie] = true
        period.uniqueCount = period.uniqueCount + 1
    end
end

-------------------------------------------------------------------------------
-- Addon messages
-------------------------------------------------------------------------------
local THROTTLED_RESULTS = { [3] = true, [8] = true } -- AddonMessageThrottle, ChannelThrottle

local function InMessagingLockdown()
    return C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown()
end

local function QueueMessage(msg, channel, target)
    if #outbox >= MAX_OUTBOX then
        table.remove(outbox, 1)
    end

    outbox[#outbox + 1] = { msg = msg, channel = channel, target = target }
end

-- Returns false if the message should be retried later. A message that
-- errors is dropped (and recorded) rather than retried forever.
local function TrySend(msg, channel, target)
    if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then
        return true
    end

    local okLockdown, locked = pcall(InMessagingLockdown)
    if okLockdown and locked then
        return false
    end

    local ok, result = pcall(C_ChatInfo.SendAddonMessage, PREFIX, msg, channel, target)
    if not ok then
        RecordError(result)
        return true
    end

    return not THROTTLED_RESULTS[result]
end

local function Send(msg, channel, target)
    if #outbox > 0 or not TrySend(msg, channel, target) then
        QueueMessage(msg, channel, target)
    end
end

local function FlushOutbox()
    while #outbox > 0 do
        local item = outbox[1]
        if not TrySend(item.msg, item.channel, item.target) then
            return
        end

        table.remove(outbox, 1)
    end
end

local function BroadcastStats()
    if not (IsInGuild and IsInGuild()) then
        return
    end

    CheckWeek()
    local w, a = db.weekly, db.allTime
    Send(table.concat({
        "S", db.weekKey,
        w.applied, w.uniqueCount, w.received,
        a.applied, a.uniqueCount, a.received,
    }, "\t"), "GUILD")
    lastBroadcast = Now()
    dirty = false
end

-------------------------------------------------------------------------------
-- Crediting buffs
-------------------------------------------------------------------------------
local function CreditCast(guildie, info, duration)
    if not guildie or guildie == me or not guildMembers[guildie] then
        return
    end

    local now = Now()
    local key = guildie .. "|" .. info.family
    local untilTime = db.creditUntil[key]
    if untilTime and untilTime > now then
        return
    end

    local family = FAMILIES[info.family]
    local fallback = info.group and family.groupDuration or family.duration
    db.creditUntil[key] = now + ClampWindow(duration or fallback, family.minWindow)

    CheckWeek()
    AddToPeriod(db.weekly, "applied", guildie)
    AddToPeriod(db.allTime, "applied", guildie)
    dirty = true

    Send("C\t" .. info.family, "WHISPER", guildMembers[guildie])
    if RefreshScores then
        SafeCall(RefreshScores)
    end
end

-- Credits a cast. Returns true when it's settled, or false when the game is
-- hiding data it needs (mid-combat) and it should be tried again later.
-- Retrying is safe: CreditCast's windows stop anyone being credited twice.
local function ResolveCredits(info, targetName, targetHidden)
    if info.group or targetHidden then
        -- Credit every guildie nearby who now has our buff. A single-target
        -- cast whose target name was hidden also checks our current target.
        local unreadable = false
        local function Check(unit)
            if not UnitExists(unit) then
                return
            end

            local has, duration = FindFamilyAura(unit, info.family, "HELPFUL|PLAYER")
            if has == nil then
                unreadable = true
            elseif has then
                local guildie = UnitNormalizedName(unit)
                if guildie then
                    CreditCast(guildie, info, duration)
                else
                    unreadable = true
                end
            end
        end

        ForEachGroupUnit(Check)
        if not info.group then
            Check("target")
        end

        return not unreadable
    end

    local guildie = NormalizeName(targetName)
    if not guildie then
        return true
    end

    local duration = nil
    local unit = FindUnitForName(guildie)
    if unit then
        local has, auraDuration = FindFamilyAura(unit, info.family, "HELPFUL|PLAYER")
        if has == false then
            return true -- the buff isn't on them, so the cast didn't land
        end

        duration = auraDuration
    end

    CreditCast(guildie, info, duration)
    return true
end

-- Casts that couldn't be settled in combat, tried again once it's over.
local DEFERRED_EXPIRY = 15 * 60
local MAX_DEFERRED = 50
local deferredCasts = {}

local function DeferCast(info, targetName, targetHidden)
    if #deferredCasts >= MAX_DEFERRED then
        table.remove(deferredCasts, 1)
    end

    deferredCasts[#deferredCasts + 1] = {
        info = info, target = targetName, hidden = targetHidden, at = Now(),
    }
end

local function RetryDeferredCasts()
    if #deferredCasts == 0 or (InCombatLockdown and InCombatLockdown()) then
        return
    end

    local now = Now()
    local remaining = {}
    for _, cast in ipairs(deferredCasts) do
        if now - cast.at < DEFERRED_EXPIRY then
            local ok, settled = pcall(ResolveCredits, cast.info, cast.target, cast.hidden)
            if not ok then
                RecordError(settled)
            elseif not settled then
                remaining[#remaining + 1] = cast
            end
        end
    end

    deferredCasts = remaining
end

local function OnBuffReceived(sender, familyKey)
    local family = FAMILIES[familyKey]
    if not family or not guildMembers[sender] then
        return
    end

    local now = Now()
    local key = sender .. "|" .. familyKey
    local untilTime = db.receivedUntil[key]
    if untilTime and untilTime > now then
        return
    end

    local has, duration = FindFamilyAura("player", familyKey, "HELPFUL")
    if has == false then
        return -- no such buff on us
    end

    db.receivedUntil[key] = now + ClampWindow(duration or family.duration, family.minWindow)
    CheckWeek()
    AddToPeriod(db.weekly, "received")
    AddToPeriod(db.allTime, "received")
    dirty = true

    if RefreshScores then
        SafeCall(RefreshScores)
    end
end

local function OnStatsReceived(sender, fields)
    local values = {}
    for i = 2, 8 do
        local n = tonumber(fields[i])
        if not n or n < 0 or n ~= math.floor(n) then
            return
        end

        values[#values + 1] = n
    end

    db.board[sender] = {
        weekKey = values[1],
        weeklyApplied = values[2], weeklyUnique = values[3], weeklyReceived = values[4],
        allApplied = values[5], allUnique = values[6], allReceived = values[7],
        seen = Now(),
    }

    if RefreshScores then
        SafeCall(RefreshScores)
    end
end

local function OnAddonMessage(prefix, text, channel, sender)
    if prefix ~= PREFIX
        or type(text) ~= "string"
        or not IsReadable(text)
        or not IsReadable(channel)
    then
        return
    end

    sender = NormalizeName(sender)
    if not sender or sender == me then
        return
    end

    local fields = Split(text)
    local kind = fields[1]
    if kind == "S" and channel == "GUILD" then
        OnStatsReceived(sender, fields)
    elseif kind == "R" and channel == "GUILD" then
        local now = Now()
        if now - lastRequestReply >= REQUEST_REPLY_INTERVAL then
            lastRequestReply = now
            -- Spread replies out so a request doesn't flood guild chat.
            C_Timer.After(2 + math.random() * 8, function()
                SafeCall(BroadcastStats)
            end)
        end
    elseif kind == "C" and channel == "WHISPER" then
        OnBuffReceived(sender, fields[2])
    end
end

local function UpdateGuildMembers()
    if not (IsInGuild and IsInGuild()) or not GetNumGuildMembers then
        return
    end

    local members = {}
    for i = 1, (GetNumGuildMembers() or 0) do
        local fullName = GetGuildRosterInfo(i)
        local name = NormalizeName(fullName)
        if name then
            members[name] = fullName
        end
    end

    if next(members) then
        guildMembers = members
    end
end

-- Shared with killtracker.lua, which loads after this file.
ns.tracker = {
    IsReadable = IsReadable,
    Now = Now,
    NormalizeName = NormalizeName,
    UnitNormalizedName = UnitNormalizedName,
    Split = Split,
    GetWeekKey = GetWeekKey,
    RekeyBoard = RekeyBoard,
    GetGuildMembers = function() return guildMembers end,
}

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("GUILD_ROSTER_UPDATE")
events:RegisterEvent("CHAT_MSG_ADDON")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterUnitEvent("UNIT_SPELLCAST_SENT", "player")
events:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
events:RegisterUnitEvent("UNIT_SPELLCAST_FAILED", "player")
events:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", "player")

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
    me = UnitNormalizedName("player")
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        C_GuildInfo.GuildRoster()
    end

    -- Let the guild channel settle, then share and ask for everyone's scores.
    C_Timer.After(10, function()
        SafeCall(UpdateGuildMembers)
        SafeCall(BroadcastStats)
        if IsInGuild and IsInGuild() then
            Send("R", "GUILD")
        end
    end)

    C_Timer.NewTicker(TICK_INTERVAL, function()
        SafeCall(FlushOutbox)
        SafeCall(RetryDeferredCasts)
        SafeCall(CheckWeek)
        if dirty and Now() - lastBroadcast >= BROADCAST_INTERVAL then
            SafeCall(BroadcastStats)
        end
    end)
end

function handlers.GUILD_ROSTER_UPDATE()
    UpdateGuildMembers()
end

function handlers.CHAT_MSG_ADDON(prefix, text, channel, sender)
    if db then
        OnAddonMessage(prefix, text, channel, sender)
    end
end

function handlers.UNIT_SPELLCAST_SENT(_, target, castGUID, spellID)
    if castGUID and IsReadable(castGUID) and IsReadable(spellID) and CAST_SPELLS[spellID] then
        if IsReadable(target) then
            pendingTargets[castGUID] = { name = target }
        else
            pendingTargets[castGUID] = { hidden = true }
        end
    end
end

function handlers.UNIT_SPELLCAST_SUCCEEDED(_, castGUID, spellID)
    if not db or not IsReadable(spellID) then
        return
    end

    local info = CAST_SPELLS[spellID]
    if not info then
        return
    end

    local pending = nil
    if castGUID and IsReadable(castGUID) then
        pending = pendingTargets[castGUID]
        pendingTargets[castGUID] = nil
    end

    local targetName = pending and pending.name
    local targetHidden = pending and pending.hidden or false

    -- Give the aura a moment to appear before checking who has it.
    C_Timer.After(AURA_CHECK_DELAY, function()
        if SafeCall(ResolveCredits, info, targetName, targetHidden) == false then
            DeferCast(info, targetName, targetHidden)
        end
    end)
end

function handlers.PLAYER_REGEN_ENABLED()
    -- Aura data can take a moment to become readable after combat.
    C_Timer.After(1, function()
        SafeCall(RetryDeferredCasts)
    end)
end

function handlers.UNIT_SPELLCAST_FAILED(_, castGUID)
    if castGUID and IsReadable(castGUID) then
        pendingTargets[castGUID] = nil
    end
end
handlers.UNIT_SPELLCAST_INTERRUPTED = handlers.UNIT_SPELLCAST_FAILED

events:SetScript("OnEvent", function(_, event, ...)
    local handler = handlers[event]
    if handler then
        SafeCall(handler, ...)
    end
end)

-------------------------------------------------------------------------------
-- High scores tab
-------------------------------------------------------------------------------
local panel = ns.buffPanel
if not panel then
    return
end

local METRICS = {
    { title = "Unique guildies buffed", weekly = "weeklyUnique", allTime = "allUnique", own = "uniqueCount" },
    { title = "Buffs applied", weekly = "weeklyApplied", allTime = "allApplied", own = "applied" },
    { title = "Buffs received", weekly = "weeklyReceived", allTime = "allReceived", own = "received" },
}
local COLUMN_X = { 70, 255, 440 }
local ROW_HEIGHT = 18

local showWeekly = true

local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", panel, "TOP", 0, -32)
title:SetText("Buff High Scores")

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
        row:SetWidth(175)
        row:SetJustifyH("LEFT")
        rows[r] = row
    end

    local own = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    own:SetPoint("TOPLEFT", panel, "TOPLEFT", COLUMN_X[i], -100 - (LEADERBOARD_SIZE + 1.5) * ROW_HEIGHT)
    own:SetWidth(175)
    own:SetJustifyH("LEFT")

    columns[i] = { rows = rows, own = own }
end

local note = panel:CreateFontString(nil, "OVERLAY", "GameFontDisable")
note:SetPoint("BOTTOM", panel, "BOTTOM", 0, 48)
note:SetWidth(540)
note:SetText("Scores are shared by each guildie's Giga addon. Buffing the same guildie with the same buff counts once per buff duration.")

local function CollectEntries(metric)
    local entries = {}
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
