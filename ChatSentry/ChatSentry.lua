-- ChatSentry v1.4.2
-- Professional chat filtering for World of Warcraft 3.3.5a

local ADDON = "ChatSentry"
local CS = CreateFrame("Frame")
_G.ChatSentry = CS

local floor, min, max = math.floor, math.min, math.max
local lower, find, gsub, format = string.lower, string.find, string.gsub, string.format
local tinsert, tremove, sort = table.insert, table.remove, table.sort
local unpack = unpack

local EVENTS = {
    "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_WHISPER", "CHAT_MSG_WHISPER_INFORM",
    "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER", "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER",
    "CHAT_MSG_RAID_WARNING", "CHAT_MSG_GUILD", "CHAT_MSG_OFFICER", "CHAT_MSG_CHANNEL",
    "CHAT_MSG_BATTLEGROUND", "CHAT_MSG_BATTLEGROUND_LEADER", "CHAT_MSG_EMOTE",
    "CHAT_MSG_TEXT_EMOTE", "CHAT_MSG_SYSTEM"
}

local CHAT_EVENT_LOOKUP = {}
for _, event in ipairs(EVENTS) do CHAT_EVENT_LOOKUP[event] = true end

local EVENT_LABELS = {
    CHAT_MSG_SAY = "Say", CHAT_MSG_YELL = "Yell", CHAT_MSG_WHISPER = "Whisper",
    CHAT_MSG_WHISPER_INFORM = "Outgoing Whisper", CHAT_MSG_PARTY = "Party",
    CHAT_MSG_PARTY_LEADER = "Party Leader", CHAT_MSG_RAID = "Raid",
    CHAT_MSG_RAID_LEADER = "Raid Leader", CHAT_MSG_RAID_WARNING = "Raid Warning",
    CHAT_MSG_GUILD = "Guild", CHAT_MSG_OFFICER = "Officer", CHAT_MSG_CHANNEL = "Channels",
    CHAT_MSG_BATTLEGROUND = "Battleground", CHAT_MSG_BATTLEGROUND_LEADER = "BG Leader",
    CHAT_MSG_EMOTE = "Emote", CHAT_MSG_TEXT_EMOTE = "Text Emote", CHAT_MSG_SYSTEM = "System"
}

local DEFAULTS = {
    enabled = true,
    minimap = { angle = 225, hide = false },
    words = {},
    users = {},
    whitelist = {},
    channels = {},
    settings = {
        caseSensitive = false,
        blockExactWords = false,
        ignoreFriends = true,
        ignoreGuild = true,
        ignorePartyRaid = true,
        notifyBlocked = false,
        repeatFilter = true,
        burstFilter = true,
        smartCurrency = true,
        smartBoost = false,
        smartGuild = false,
        smartLFG = false,
        smartLinks = false,
        placeholderMode = false,
        repeatAllowed = 2,
        repeatWindow = 10,
        burstAllowed = 6,
        burstWindow = 20,
        maxLog = 500,
    },
    log = {},
    stats = { lifetime = 0, byWord = {}, byUser = {}, byEvent = {} },
}

for _, event in ipairs(EVENTS) do DEFAULTS.channels[event] = true end
DEFAULTS.channels.CHAT_MSG_WHISPER_INFORM = false

local function DeepCopy(src)
    if type(src) ~= "table" then return src end
    local dst = {}
    for k, v in pairs(src) do dst[k] = DeepCopy(v) end
    return dst
end

local function MergeDefaults(dst, src)
    if type(dst) ~= "table" then dst = {} end
    for k, v in pairs(src) do
        if type(v) == "table" then dst[k] = MergeDefaults(dst[k], v)
        elseif dst[k] == nil then dst[k] = v end
    end
    return dst
end

local function Trim(s)
    return (gsub(gsub(tostring(s or ""), "^%s+", ""), "%s+$", ""))
end

local function NormalizeName(name)
    name = Trim(name)
    name = gsub(name, "%-.*$", "")
    return lower(name)
end

local function CleanMessage(msg)
    msg = tostring(msg or "")
    msg = gsub(msg, "|c%x%x%x%x%x%x%x%x", "")
    msg = gsub(msg, "|r", "")
    msg = gsub(msg, "|H.-|h(.-)|h", "%1")
    msg = gsub(msg, "|T.-|t", "")
    return msg
end

local function EscapePattern(s)
    return (gsub(s, "([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"))
end

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffefb94fChatSentry:|r " .. tostring(msg))
end

local function IsInList(list, value)
    value = lower(Trim(value))
    for i, entry in ipairs(list) do
        if lower(entry.value or entry) == value then return i, entry end
    end
end

local function AddListEntry(list, value, mode)
    value = Trim(value)
    if value == "" then return false, "Enter a value first." end
    if IsInList(list, value) then return false, "That entry already exists." end
    tinsert(list, { value = value, mode = mode or "contains", enabled = true, added = time() })
    return true
end

local function RemoveListEntry(list, index)
    if index and list[index] then tremove(list, index) return true end
end

-- Quick market filters group the common currency abbreviations with their full names.
-- Bracketed entries such as [Bazaar Tokens] are treated as the same phrase.
local MARKET_FILTERS = {
    dp = { label = "Donation Points / DP", values = {"Donation Points", "DP"} },
    bt = { label = "Bazaar Tokens / BT", values = {"Bazaar Tokens", "BT"} },
}

local function NormalizeMarketWord(value)
    value = lower(Trim(value))
    value = gsub(value, "^%[", "")
    value = gsub(value, "%]$", "")
    return Trim(value)
end

local function FindMarketEntries(group)
    local found = {}
    if not ChatSentryDB or not ChatSentryDB.words then return found end
    for _, wanted in ipairs(group.values) do
        local wantedNorm = NormalizeMarketWord(wanted)
        for _, entry in ipairs(ChatSentryDB.words) do
            if NormalizeMarketWord(entry.value or entry) == wantedNorm then
                tinsert(found, entry)
            end
        end
    end
    return found
end

local function MarketFilterEnabled(key)
    local group = MARKET_FILTERS[key]
    if not group then return false end
    local entries = FindMarketEntries(group)
    if #entries == 0 then return false end
    for _, entry in ipairs(entries) do
        if entry.enabled ~= false then return true end
    end
    return false
end

local function SetMarketFilter(key, enabled)
    local group = MARKET_FILTERS[key]
    if not group then return end

    -- Update every existing spelling first, including bracketed versions.
    local entries = FindMarketEntries(group)
    for _, entry in ipairs(entries) do entry.enabled = enabled and true or false end

    -- When enabled, guarantee both the abbreviation and full phrase exist.
    if enabled then
        for _, wanted in ipairs(group.values) do
            local exists
            local wantedNorm = NormalizeMarketWord(wanted)
            for _, entry in ipairs(ChatSentryDB.words) do
                if NormalizeMarketWord(entry.value or entry) == wantedNorm then
                    entry.enabled = true
                    exists = true
                end
            end
            if not exists then AddListEntry(ChatSentryDB.words, wanted, "exact") end
        end
    end
end

local function IsFriend(name)
    local target = NormalizeName(name)
    for i = 1, GetNumFriends() do
        local friend = GetFriendInfo(i)
        if friend and NormalizeName(friend) == target then return true end
    end
    return false
end

local function IsGuildMember(name)
    if not IsInGuild() then return false end
    local target = NormalizeName(name)
    for i = 1, GetNumGuildMembers(true) do
        local member = GetGuildRosterInfo(i)
        if member and NormalizeName(member) == target then return true end
    end
    return false
end

local function IsGroupMember(name)
    local target = NormalizeName(name)
    if target == NormalizeName(UnitName("player")) then return true end
    local prefix, count = "party", GetNumPartyMembers()
    if GetNumRaidMembers() > 0 then prefix, count = "raid", GetNumRaidMembers() end
    for i = 1, count do
        local n = UnitName(prefix .. i)
        if n and NormalizeName(n) == target then return true end
    end
    return false
end

local function SenderIsExempt(sender)
    if not sender or sender == "" then return false end
    local norm = NormalizeName(sender)
    if IsInList(ChatSentryDB.whitelist, norm) then return true end
    local s = ChatSentryDB.settings
    if s.ignoreFriends and IsFriend(sender) then return true end
    if s.ignoreGuild and IsGuildMember(sender) then return true end
    if s.ignorePartyRaid and IsGroupMember(sender) then return true end
    return false
end

local function MatchWord(message, entry)
    if not entry or entry.enabled == false then return false end
    local needle = Trim(entry.value or "")
    if needle == "" then return false end

    local hay = tostring(message or "")
    if not ChatSentryDB.settings.caseSensitive then
        hay, needle = lower(hay), lower(needle)
    end

    local mode = entry.mode or "contains"
    if mode == "exact" or ChatSentryDB.settings.blockExactWords then
        -- Whole-word matching for simple words. Multi-word phrases are matched literally
        -- with boundaries at the outside edges so spaces and punctuation behave correctly.
        local escaped = EscapePattern(needle)
        local first = string.sub(needle, 1, 1)
        local last = string.sub(needle, -1)
        local left = string.find(first, "[%w_]") and "%f[%w_]" or ""
        local right = string.find(last, "[%w_]") and "%f[^%w_]" or ""
        if find(hay, left .. escaped .. right) ~= nil then return true end

        -- Currency abbreviations are commonly attached directly to an amount in trade chat
        -- (for example: 35DP, 1,350BT, or 35xDP). Treat those compact forms as a match
        -- without weakening normal whole-word behavior for unrelated keywords.
        local marketNeedle = NormalizeMarketWord(needle)
        if marketNeedle == "dp" or marketNeedle == "bt" then
            local compact = "%f[%d]%d[%d,%.]*%s*[xX]?%s*" .. EscapePattern(marketNeedle) .. "%f[^%a]"
            if find(hay, compact) ~= nil then return true end
        end

        return false
    end

    return find(hay, needle, 1, true) ~= nil
end


local repeatTracker = {}
local burstTracker = {}
local trackerLastCleanup = 0

local PUBLIC_SPAM_EVENTS = {
    CHAT_MSG_CHANNEL = true, CHAT_MSG_SAY = true, CHAT_MSG_YELL = true,
    CHAT_MSG_BATTLEGROUND = true, CHAT_MSG_BATTLEGROUND_LEADER = true,
}

local function NormalizeSpamText(msg)
    local text = lower(CleanMessage(msg))
    text = gsub(text, "%s+", " ")
    text = gsub(text, "([!%?%.%,])%1+", "%1")
    text = gsub(text, "^%s+", "")
    text = gsub(text, "%s+$", "")
    return text
end

local function CleanupTrackers(now)
    if now - trackerLastCleanup < 30 then return end
    trackerLastCleanup = now
    for key, entry in pairs(repeatTracker) do
        if now - (entry.last or 0) > 90 then repeatTracker[key] = nil end
    end
    for key, entry in pairs(burstTracker) do
        if now - (entry.last or 0) > 90 then burstTracker[key] = nil end
    end
end

local function GetChannelIdentity(event, ...)
    if event ~= "CHAT_MSG_CHANNEL" then return EVENT_LABELS[event] or event end
    local best = nil
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if type(v) == "string" and v ~= "" then
            local clean = lower(gsub(v, "^%d+%.%s*", ""))
            if find(clean, "ascension", 1, true) or find(clean, "trade", 1, true) or
               find(clean, "world", 1, true) or find(clean, "global", 1, true) or
               find(clean, "lookingforgroup", 1, true) or find(clean, "lfg", 1, true) or
               find(clean, "general", 1, true) then
                return clean
            end
            if not best and #clean < 40 then best = clean end
        end
    end
    return best or "channels"
end

local function IsRepeatMessage(event, sender, msg, channel)
    local s = ChatSentryDB.settings
    if not s.repeatFilter or not PUBLIC_SPAM_EVENTS[event] then return false end
    local normalized = NormalizeSpamText(msg)
    if normalized == "" then return false end
    local now = GetTime()
    CleanupTrackers(now)
    local key = NormalizeName(sender) .. "" .. tostring(channel) .. "" .. normalized
    local entry = repeatTracker[key]
    local window = tonumber(s.repeatWindow) or 10
    local allowed = tonumber(s.repeatAllowed) or 2
    if not entry or now - entry.last > window then
        repeatTracker[key] = { count = 1, first = now, last = now }
        return false
    end
    entry.count = entry.count + 1
    entry.last = now
    return entry.count > allowed
end

local function IsBurstMessage(event, sender, channel)
    local s = ChatSentryDB.settings
    if not s.burstFilter or not PUBLIC_SPAM_EVENTS[event] then return false end
    local now = GetTime()
    CleanupTrackers(now)
    local key = NormalizeName(sender) .. "" .. tostring(channel)
    local entry = burstTracker[key]
    local window = tonumber(s.burstWindow) or 20
    local allowed = tonumber(s.burstAllowed) or 6
    if not entry or now - entry.first > window then
        burstTracker[key] = { count = 1, first = now, last = now }
        return false
    end
    entry.count = entry.count + 1
    entry.last = now
    return entry.count > allowed
end

local function ContainsAny(text, values)
    for _, value in ipairs(values) do
        if find(text, value, 1, true) then return true end
    end
    return false
end

local function MatchSmartCategory(event, msg, channel)
    local s = ChatSentryDB.settings
    local text = NormalizeSpamText(msg)

    if s.smartCurrency then
        if find(text, "%d[%d,%.]*%s*[xX]?%s*dp%f[^%a]") or find(text, "%d[%d,%.]*%s*[xX]?%s*bt%f[^%a]") or
           find(text, "donation points", 1, true) or find(text, "bazaar tokens", 1, true) then
            return "smart", "Currency trading"
        end
    end

    if s.smartLinks and not find(msg, "|Hitem:", 1, true) and not find(msg, "|Hachievement:", 1, true) then
        if find(text, "https?://") or find(text, "www%.") or find(text, "[%w%-]+%.com%f[^%a]") or
           find(text, "[%w%-]+%.net%f[^%a]") or find(text, "[%w%-]+%.org%f[^%a]") then
            return "smart", "External link"
        end
    end

    if s.smartBoost then
        local sale = ContainsAny(text, {"wts", "selling", "service", "services", "runs available"})
        local boost = ContainsAny(text, {"boost", "boosting", "carry", "carries", "piloted", "pilot run", "gdkp"})
        local price = ContainsAny(text, {"price", "cheap", "gold per", "per run", "pst", "whisper"})
        if (sale and boost) or (boost and price) then return "smart", "Boost advertising" end
    end

    if s.smartGuild then
        local guild = ContainsAny(text, {"guild", "raid team", "core roster", "community"})
        local recruit = ContainsAny(text, {"recruit", "recruiting", "looking for members", "lf members", "apply", "open spots"})
        if guild and recruit then return "smart", "Guild recruitment" end
    end

    if s.smartLFG and (event == "CHAT_MSG_CHANNEL" or event == "CHAT_MSG_YELL") then
        local lfg = ContainsAny(text, {"lfg", "lfm", "looking for group", "looking for more", "need tank", "need healer", "need heals", "need dps"})
        local role = ContainsAny(text, {"tank", "heal", "healer", "dps", "raid", "dungeon", "mythic", "keystone"})
        if lfg and role then return "smart", "LFG traffic" end
    end
end

-- LootCollector uses hidden addon-protocol traffic such as LC1:CONF:.
-- Some private-server chat bridges expose those packets as ordinary chat events.
-- Ignore them completely so ChatSentry never blocks, logs, or counts them as spam.
local function IsLootCollectorProtocol(msg)
    if type(msg) ~= "string" then return false end
    local clean = CleanMessage(msg)
    return find(clean, "^LC%d*:") ~= nil or find(clean, "^LC%d+|") ~= nil
end

local function MatchUser(sender)
    if not sender then return nil end
    local norm = NormalizeName(sender)
    for _, entry in ipairs(ChatSentryDB.users) do
        if entry.enabled ~= false and NormalizeName(entry.value) == norm then return entry.value end
    end
end

function CS:EvaluateMessage(event, msg, sender, ...)
    if not ChatSentryDB or not ChatSentryDB.enabled then return nil end
    if IsLootCollectorProtocol(msg) then return nil end
    if ChatSentryDB.channels[event] == false then return nil end

    local clean = CleanMessage(msg)
    local channel = GetChannelIdentity(event, ...)
    local now = GetTime and GetTime() or 0
    local evaluationKey = tostring(event) .. "\031" .. NormalizeName(sender) .. "\031" .. tostring(channel) .. "\031" .. NormalizeSpamText(clean)
    if CS.lastEvaluationKey == evaluationKey and (now - (CS.lastEvaluationAt or 0)) < 0.15 then
        return CS.lastEvaluationType, CS.lastEvaluationReason
    end

    -- Explicit whitelist entries bypass everything. Social exceptions do not bypass
    -- public flood protection, otherwise guildmates/friends can rapid-fire unchecked.
    if sender and IsInList(ChatSentryDB.whitelist, NormalizeName(sender)) then
        CS.lastEvaluationKey, CS.lastEvaluationAt = evaluationKey, now
        CS.lastEvaluationType, CS.lastEvaluationReason = nil, nil
        return nil
    end

    -- Always advance both counters. Previously, once a repeat matched, the burst
    -- tracker was skipped because the checks were chained with elseif.
    local repeated = IsRepeatMessage(event, sender, clean, channel)
    local burst = IsBurstMessage(event, sender, channel)
    if repeated or burst then
        local spamReason = repeated and "Repeated message" or "Message burst"
        CS.lastEvaluationKey, CS.lastEvaluationAt = evaluationKey, now
        CS.lastEvaluationType, CS.lastEvaluationReason = "spam", spamReason
        return "spam", spamReason
    end

    if SenderIsExempt(sender) then
        CS.lastEvaluationKey, CS.lastEvaluationAt = evaluationKey, now
        CS.lastEvaluationType, CS.lastEvaluationReason = nil, nil
        return nil
    end

    local blockedUser = MatchUser(sender)
    if blockedUser then
        CS.lastEvaluationKey, CS.lastEvaluationAt = evaluationKey, now
        CS.lastEvaluationType, CS.lastEvaluationReason = "user", blockedUser
        return "user", blockedUser
    end

    for _, entry in ipairs(ChatSentryDB.words) do
        if MatchWord(clean, entry) then
            CS.lastEvaluationKey, CS.lastEvaluationAt = evaluationKey, now
            CS.lastEvaluationType, CS.lastEvaluationReason = "word", entry.value
            return "word", entry.value
        end
    end

    local reasonType, reason = MatchSmartCategory(event, clean, channel)
    CS.lastEvaluationKey, CS.lastEvaluationAt = evaluationKey, now
    CS.lastEvaluationType, CS.lastEvaluationReason = reasonType, reason
    return reasonType, reason
end

local function AddLog(event, msg, sender, reasonType, reason)
    local fingerprint = tostring(event) .. "\031" .. tostring(sender) .. "\031" .. tostring(msg) .. "\031" .. tostring(reason)
    local now = GetTime and GetTime() or 0
    if CS.lastBlockFingerprint == fingerprint and (now - (CS.lastBlockAt or 0)) < 0.75 then
        return
    end
    CS.lastBlockFingerprint, CS.lastBlockAt = fingerprint, now

    local row = {
        time = time(), event = event, channel = EVENT_LABELS[event] or event,
        sender = sender or "System", message = CleanMessage(msg),
        reasonType = reasonType, reason = reason,
    }
    tinsert(ChatSentryDB.log, 1, row)
    while #ChatSentryDB.log > (ChatSentryDB.settings.maxLog or 500) do tremove(ChatSentryDB.log) end
    ChatSentryDB.stats.lifetime = (ChatSentryDB.stats.lifetime or 0) + 1
    local bucket
    if reasonType == "word" then bucket = ChatSentryDB.stats.byWord
    elseif reasonType == "user" then bucket = ChatSentryDB.stats.byUser
    else
        ChatSentryDB.stats.bySmart = ChatSentryDB.stats.bySmart or {}
        bucket = ChatSentryDB.stats.bySmart
    end
    bucket[reason] = (bucket[reason] or 0) + 1
    ChatSentryDB.stats.byEvent[event] = (ChatSentryDB.stats.byEvent[event] or 0) + 1
    CS.sessionBlocked = (CS.sessionBlocked or 0) + 1
    if CS.RefreshAll then CS:RefreshAll() end
end

function CS.Filter(chatFrame, event, msg, sender, ...)
    local reasonType, reason = CS:EvaluateMessage(event, msg, sender, ...)
    if reasonType then
        AddLog(event, msg, sender, reasonType, reason)
        if ChatSentryDB.settings.notifyBlocked then
            Print(reasonType == "user" and ("Blocked a message from " .. tostring(sender)) or ("Blocked a message matching ‘" .. tostring(reason) .. "’."))
        end
        if ChatSentryDB.settings.placeholderMode then
            return false, "|cff7f8b9c[ChatSentry: " .. tostring(reason) .. "]|r", "ChatSentry", ...
        end
        return true
    end
    return false, msg, sender, ...
end

-- Some private-server channel panels bypass Blizzard's registered chat filters.
-- Wrapping the shared message handler catches those panels while preserving normal chat.
function CS:InstallMessageHandlerBridge()
    if type(ChatFrame_MessageEventHandler) ~= "function" then return end
    if ChatFrame_MessageEventHandler == self.messageHandlerBridge then return end

    local original = ChatFrame_MessageEventHandler
    self.messageHandlerBridge = function(frame, event, ...)
        if CHAT_EVENT_LOOKUP[event] then
            local msg, sender = ...
            local reasonType, reason = CS:EvaluateMessage(event, msg, sender, select(3, ...))
            if reasonType then
                AddLog(event, msg, sender, reasonType, reason)
                if ChatSentryDB.settings.placeholderMode then
                    return original(frame, event, "|cff7f8b9c[ChatSentry: " .. tostring(reason) .. "]|r", "ChatSentry", select(3, ...))
                end
                return
            end
        end
        return original(frame, event, ...)
    end
    ChatFrame_MessageEventHandler = self.messageHandlerBridge
end

local function Backdrop(frame, bg, border)
    frame:SetBackdrop({
        bgFile = "Interface\\AddOns\\ChatSentry\\Textures\\Panel.tga",
        edgeFile = "Interface\\AddOns\\ChatSentry\\Textures\\Border.tga",
        tile = true, tileSize = 32, edgeSize = 16,
        insets = { left = 5, right = 5, top = 5, bottom = 5 }
    })
    frame:SetBackdropColor(unpack(bg or {0.035, 0.045, 0.06, 0.98}))
    frame:SetBackdropBorderColor(unpack(border or {0.93, 0.58, 0.16, 1}))
end

local function MakeText(parent, text, size, anchor, x, y, color)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(STANDARD_TEXT_FONT, size or 12, size and size >= 15 and "OUTLINE" or "")
    fs:SetText(text or "")
    fs:SetPoint(anchor or "TOPLEFT", x or 0, y or 0)
    fs:SetTextColor(unpack(color or {0.9, 0.92, 0.96, 1}))
    return fs
end

local function MakeButton(parent, text, width, height, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(width or 100, height or 26)
    Backdrop(b, {0.10, 0.12, 0.16, 1}, {0.60, 0.42, 0.18, 1})
    b.label = MakeText(b, text, 12, "CENTER", 0, 0)
    b:SetScript("OnEnter", function(self) self:SetBackdropColor(0.16, 0.19, 0.25, 1); self:SetBackdropBorderColor(1, 0.68, 0.24, 1) end)
    b:SetScript("OnLeave", function(self) self:SetBackdropColor(0.10, 0.12, 0.16, 1); self:SetBackdropBorderColor(0.60, 0.42, 0.18, 1) end)
    b:SetScript("OnMouseDown", function(self) self.label:SetPoint("CENTER", 1, -1) end)
    b:SetScript("OnMouseUp", function(self) self.label:SetPoint("CENTER", 0, 0) end)
    b:SetScript("OnClick", onClick)
    return b
end

local function MakeEditBox(parent, width, height)
    local box = CreateFrame("EditBox", nil, parent)
    box:SetSize(width, height or 26)
    box:SetAutoFocus(false)
    box:SetFontObject(ChatFontNormal)
    box:SetTextInsets(8, 8, 0, 0)
    Backdrop(box, {0.025, 0.03, 0.04, 1}, {0.28, 0.34, 0.45, 1})
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEditFocusGained", function(self) self:SetBackdropBorderColor(0.95, 0.61, 0.19, 1) end)
    box:SetScript("OnEditFocusLost", function(self) self:SetBackdropBorderColor(0.28, 0.34, 0.45, 1) end)
    return box
end

local function MakeCheckbox(parent, label, onClick)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb.text = MakeText(cb, label, 12, "LEFT", 27, 0)
    cb:SetScript("OnClick", onClick)
    return cb
end

local function CreateScrollList(parent, rowHeight, rowFactory)
    local sf = CreateFrame("ScrollFrame", nil, parent, "FauxScrollFrameTemplate")
    sf.rows, sf.rowHeight, sf.rowFactory = {}, rowHeight, rowFactory
    function sf:Build(count)
        for i = 1, count do
            local row = rowFactory(parent, i)
            row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -((i - 1) * rowHeight))
            row:SetPoint("RIGHT", parent, "RIGHT", -24, 0)
            row:SetHeight(rowHeight)
            self.rows[i] = row
        end
    end
    return sf
end

local function CreateUI()
    local f = CreateFrame("Frame", "ChatSentryFrame", UIParent)
    f:SetSize(860, 570)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true); f:EnableMouse(true); f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    Backdrop(f)
    f:Hide()
    CS.frame = f

    local header = CreateFrame("Frame", nil, f)
    header:SetPoint("TOPLEFT", 7, -7); header:SetPoint("TOPRIGHT", -7, -7); header:SetHeight(68)
    header:SetBackdrop({bgFile="Interface\\AddOns\\ChatSentry\\Textures\\Header.tga"})
    header:SetBackdropColor(1,1,1,1)

    local logo = header:CreateTexture(nil, "ARTWORK")
    logo:SetTexture("Interface\\AddOns\\ChatSentry\\Textures\\Shield.tga")
    logo:SetSize(48,48); logo:SetPoint("LEFT", 16, 0)
    MakeText(header, "CHAT|cffef9f28SENTRY|r", 21, "TOPLEFT", 72, -13)
    MakeText(header, "Private-server chat filtering and moderation", 11, "TOPLEFT", 73, -39, {0.62,0.68,0.77,1})

    local enabled = MakeCheckbox(header, "Filtering Enabled", function(self)
        ChatSentryDB.enabled = self:GetChecked() and true or false
        CS:RefreshAll()
    end)
    enabled:SetPoint("RIGHT", -54, 0); f.enabledCheck = enabled

    local close = MakeButton(header, "×", 28, 28, function() f:Hide() end)
    close:SetPoint("TOPRIGHT", -8, -8)

    local nav = CreateFrame("Frame", nil, f)
    nav:SetPoint("TOPLEFT", 12, -82); nav:SetPoint("BOTTOMLEFT", 12, 12); nav:SetWidth(150)
    Backdrop(nav, {0.025,0.032,0.045,0.96}, {0.18,0.23,0.31,1})

    local content = CreateFrame("Frame", nil, f)
    content:SetPoint("TOPLEFT", nav, "TOPRIGHT", 10, 0); content:SetPoint("BOTTOMRIGHT", -12, 12)
    Backdrop(content, {0.045,0.055,0.072,0.97}, {0.22,0.28,0.38,1})
    f.content = content

    f.pages, f.navButtons = {}, {}
    local tabs = {
        {"Dashboard", "Dashboard"}, {"Blocked Words", "Words"}, {"Blocked Users", "Users"},
        {"Exceptions", "Whitelist"}, {"Channels", "Channels"}, {"Smart Filters", "Smart"}, {"Blocked Log", "Log"}, {"Settings", "Settings"}
    }

    function f:ShowPage(key)
        for name, page in pairs(self.pages) do page:SetShown(name == key) end
        for name, b in pairs(self.navButtons) do
            b:SetBackdropColor(name == key and 0.20 or 0.07, name == key and 0.14 or 0.08, name == key and 0.07 or 0.11, 1)
            b:SetBackdropBorderColor(name == key and 1 or 0.22, name == key and 0.62 or 0.28, name == key and 0.18 or 0.38, 1)
        end
        self.activePage = key
        CS:RefreshAll()
    end

    for i, tab in ipairs(tabs) do
        local b = MakeButton(nav, tab[1], 126, 34, function() f:ShowPage(tab[2]) end)
        b:SetPoint("TOP", 0, -12 - ((i-1)*40))
        f.navButtons[tab[2]] = b
        local p = CreateFrame("Frame", nil, content)
        p:SetAllPoints(); p:Hide(); f.pages[tab[2]] = p
    end

    -- Dashboard
    do
        local p = f.pages.Dashboard
        MakeText(p, "Dashboard", 20, "TOPLEFT", 20, -18)
        MakeText(p, "Live visibility into what ChatSentry is removing from chat.", 11, "TOPLEFT", 21, -47, {0.62,0.68,0.77,1})
        p.cards = {}
        local cards = {{"Session", "session"}, {"Lifetime", "lifetime"}, {"Words", "words"}, {"Users", "users"}}
        for i, c in ipairs(cards) do
            local card = CreateFrame("Frame", nil, p); card:SetSize(142, 82)
            card:SetPoint("TOPLEFT", 20 + ((i-1)*151), -78)
            Backdrop(card, {0.06,0.075,0.10,1}, {0.26,0.34,0.46,1})
            card.value = MakeText(card, "0", 24, "CENTER", 0, 8, {1,0.67,0.25,1})
            MakeText(card, c[1], 11, "BOTTOM", 0, 13, {0.62,0.68,0.77,1})
            p.cards[c[2]] = card
        end
        local quick = CreateFrame("Frame", nil, p)
        quick:SetPoint("TOPLEFT", 20, -178); quick:SetPoint("TOPRIGHT", -20, -178); quick:SetHeight(48)
        Backdrop(quick, {0.055,0.068,0.09,1}, {0.26,0.34,0.46,1})
        MakeText(quick, "Quick market filters", 12, "LEFT", 12, 0, {0.78,0.83,0.90,1})
        p.marketChecks = {}
        local dp = MakeCheckbox(quick, "Filter Donation Points / DP", function(self)
            SetMarketFilter("dp", self:GetChecked() and true or false)
            CS:RefreshAll()
        end)
        dp:SetPoint("LEFT", 172, 0); p.marketChecks.dp = dp
        local bt = MakeCheckbox(quick, "Filter Bazaar Tokens / BT", function(self)
            SetMarketFilter("bt", self:GetChecked() and true or false)
            CS:RefreshAll()
        end)
        bt:SetPoint("LEFT", 392, 0); p.marketChecks.bt = bt

        MakeText(p, "Recent blocks", 14, "TOPLEFT", 20, -244)
        p.recent = {}
        for i=1,5 do
            local row = CreateFrame("Frame", nil, p); row:SetSize(596, 38); row:SetPoint("TOPLEFT", 20, -268-((i-1)*40))
            if i%2==0 then row:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8"}); row:SetBackdropColor(1,1,1,0.025) end
            row.sender = MakeText(row, "", 11, "LEFT", 8, 7)
            row.reason = MakeText(row, "", 10, "LEFT", 8, -9, {1,0.64,0.22,1})
            row.msg = MakeText(row, "", 11, "LEFT", 185, 0, {0.75,0.79,0.86,1}); row.msg:SetWidth(400); row.msg:SetJustifyH("LEFT")
            p.recent[i] = row
        end
    end

    local function BuildEntryPage(key, title, subtitle, listName, allowMode)
        local p = f.pages[key]
        MakeText(p, title, 20, "TOPLEFT", 20, -18)
        MakeText(p, subtitle, 11, "TOPLEFT", 21, -47, {0.62,0.68,0.77,1})
        p.input = MakeEditBox(p, 360, 28); p.input:SetPoint("TOPLEFT", 20, -75)
        p.mode = "contains"
        if allowMode then
            p.modeButton = MakeButton(p, "Phrase", 104, 28, function(self)
                p.mode = p.mode == "contains" and "exact" or "contains"
                self.label:SetText(p.mode == "contains" and "Phrase" or "Whole word")
            end)
            p.modeButton:SetPoint("LEFT", p.input, "RIGHT", 8, 0)
        end
        local add = MakeButton(p, "Add", 82, 28, function()
            local ok, err = AddListEntry(ChatSentryDB[listName], p.input:GetText(), allowMode and p.mode or "exact")
            if not ok then Print(err) else p.input:SetText(""); CS:RefreshAll() end
        end)
        add:SetPoint("LEFT", allowMode and p.modeButton or p.input, "RIGHT", 8, 0)
        p.input:SetScript("OnEnterPressed", function(self) add:Click(); self:ClearFocus() end)

        local box = CreateFrame("Frame", nil, p); box:SetPoint("TOPLEFT", 20, -120); box:SetPoint("BOTTOMRIGHT", -20, 20)
        Backdrop(box, {0.025,0.032,0.044,0.9}, {0.17,0.22,0.30,1})
        p.rows = {}
        for i=1,10 do
            local row = CreateFrame("Frame", nil, box); row:SetHeight(34); row:SetPoint("TOPLEFT", 8, -8-((i-1)*36)); row:SetPoint("RIGHT", -26, 0)
            if i%2==0 then row:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8"}); row:SetBackdropColor(1,1,1,0.025) end
            row.check = MakeCheckbox(row, "", function(self)
                local entry = ChatSentryDB[listName][self:GetParent().index]
                if entry then entry.enabled = self:GetChecked() and true or false end
            end); row.check:SetPoint("LEFT", 2, 0)
            row.value = MakeText(row, "", 12, "LEFT", 34, 0)
            row.modeText = MakeText(row, "", 10, "RIGHT", -82, 0, {0.56,0.63,0.72,1})
            row.remove = MakeButton(row, "Remove", 68, 24, function()
                RemoveListEntry(ChatSentryDB[listName], row.index); CS:RefreshAll()
            end); row.remove:SetPoint("RIGHT", -2, 0)
            p.rows[i] = row
        end
        p.scroll = CreateFrame("ScrollFrame", nil, box, "FauxScrollFrameTemplate")
        p.scroll:SetPoint("TOPLEFT", 0, -8); p.scroll:SetPoint("BOTTOMRIGHT", -2, 8)
        p.scroll:SetScript("OnVerticalScroll", function(self, offset) FauxScrollFrame_OnVerticalScroll(self, offset, 36, function() CS:RefreshEntryPage(p, listName) end) end)
        p.listName = listName
        p.visibleRows = 10
    end

    BuildEntryPage("Words", "Blocked Words", "Only matching messages are hidden. Phrase is literal; Whole word avoids partial matches.", "words", true)
    do
        local p = f.pages.Words
        p.input:SetWidth(292)
        local test = MakeButton(p, "Test Message", 106, 28, function()
            local sample = p.testInput:GetText() or ""
            local matched
            for _, entry in ipairs(ChatSentryDB.words) do
                if MatchWord(CleanMessage(sample), entry) then matched = entry.value; break end
            end
            p.testResult:SetText(matched and ("Would block: |cffef9f28" .. matched .. "|r") or "No blocked word matched.")
        end)
        test:SetPoint("TOPRIGHT", -20, -75)
        p.testInput = MakeEditBox(p, 420, 26); p.testInput:SetPoint("TOPLEFT", 20, -112)
        p.testInput:SetText("Paste a sample chat message here")
        p.testInput:SetScript("OnEditFocusGained", function(self) if self:GetText()=="Paste a sample chat message here" then self:SetText("") end end)
        p.testResult = MakeText(p, "Test a message before relying on the filter.", 10, "LEFT", 448, -125, {0.62,0.68,0.77,1})
        local box = p.rows[1]:GetParent()
        box:ClearAllPoints(); box:SetPoint("TOPLEFT", 20, -154); box:SetPoint("BOTTOMRIGHT", -20, 20)
        p.visibleRows = 8
        for i = 9, #p.rows do p.rows[i]:Hide() end
    end
    BuildEntryPage("Users", "Blocked Users", "Hide every message sent by specific players.", "users", false)
    BuildEntryPage("Whitelist", "Exceptions", "Trusted players here always bypass ChatSentry filters.", "whitelist", false)

    -- Channels
    do
        local p = f.pages.Channels
        MakeText(p, "Channels", 20, "TOPLEFT", 20, -18)
        MakeText(p, "Choose where keyword filtering is allowed to run.", 11, "TOPLEFT", 21, -47, {0.62,0.68,0.77,1})
        local note = CreateFrame("Frame", nil, p); note:SetPoint("TOPLEFT", 20, -72); note:SetPoint("TOPRIGHT", -20, -72); note:SetHeight(44)
        Backdrop(note, {0.07,0.085,0.11,1}, {0.26,0.34,0.46,1})
        MakeText(note, "These switches do not mute a channel. Checked means ChatSentry checks that channel for your blocked words and users.", 11, "LEFT", 12, 0, {0.78,0.83,0.90,1})
        p.checks = {}
        for i, event in ipairs(EVENTS) do
            local col = (i-1)%2; local row = floor((i-1)/2)
            local cb = MakeCheckbox(p, EVENT_LABELS[event], function(self)
                ChatSentryDB.channels[self.event] = self:GetChecked() and true or false
            end)
            cb.event = event; cb:SetPoint("TOPLEFT", 28+(col*300), -132-(row*39)); p.checks[event] = cb
        end
    end


    -- Smart Filters
    do
        local p = f.pages.Smart
        MakeText(p, "Smart Filters", 20, "TOPLEFT", 20, -18)
        MakeText(p, "Behavior-based protection for repetitive and common public-channel spam.", 11, "TOPLEFT", 21, -47, {0.62,0.68,0.77,1})
        local note = CreateFrame("Frame", nil, p); note:SetPoint("TOPLEFT", 20, -72); note:SetPoint("TOPRIGHT", -20, -72); note:SetHeight(52)
        Backdrop(note, {0.07,0.085,0.11,1}, {0.26,0.34,0.46,1})
        MakeText(note, "Repeat and burst protection runs in public chat even for friends or guildmates. Only explicit whitelist entries bypass flood protection.", 10, "LEFT", 12, 0, {0.78,0.83,0.90,1})
        p.checks = {}
        local smart = {
            {"repeatFilter", "Block repeated messages (after 2 repeats in 10 seconds)"},
            {"burstFilter", "Block rapid sender bursts (after 6 messages in 20 seconds)"},
            {"smartCurrency", "Detect DP / BT currency trade formats automatically"},
            {"smartBoost", "Detect contextual boost and carry advertising"},
            {"smartGuild", "Detect contextual guild recruitment"},
            {"smartLFG", "Detect LFG traffic in public channels"},
            {"smartLinks", "Block external website links (item links remain allowed)"},
            {"placeholderMode", "Show a compact placeholder instead of hiding blocked chat"},
        }
        for i, item in ipairs(smart) do
            local cb = MakeCheckbox(p, item[2], function(self)
                ChatSentryDB.settings[self.key] = self:GetChecked() and true or false
            end)
            cb.key = item[1]; cb:SetPoint("TOPLEFT", 26, -144-((i-1)*38)); p.checks[item[1]] = cb
        end
    end

    -- Log
    do
        local p = f.pages.Log
        MakeText(p, "Blocked Log", 20, "TOPLEFT", 20, -18)
        MakeText(p, "Everything removed from chat is recorded here.", 11, "TOPLEFT", 21, -47, {0.62,0.68,0.77,1})
        p.search = MakeEditBox(p, 350, 28); p.search:SetPoint("TOPLEFT", 20, -75)
        p.search:SetScript("OnTextChanged", function() CS:RefreshLog() end)
        local clear = MakeButton(p, "Clear Log", 90, 28, function() wipe(ChatSentryDB.log); CS:RefreshAll() end); clear:SetPoint("TOPRIGHT", -20, -75)
        local box = CreateFrame("Frame", nil, p); box:SetPoint("TOPLEFT", 20, -118); box:SetPoint("BOTTOMRIGHT", -20, 20)
        Backdrop(box, {0.025,0.032,0.044,0.9}, {0.17,0.22,0.30,1})
        p.rows = {}
        for i=1,9 do
            local row = CreateFrame("Frame", nil, box); row:SetHeight(41); row:SetPoint("TOPLEFT", 8, -8-((i-1)*43)); row:SetPoint("RIGHT", -26, 0)
            if i%2==0 then row:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8"}); row:SetBackdropColor(1,1,1,0.025) end
            row.top = MakeText(row, "", 10, "TOPLEFT", 5, -5)
            row.msg = MakeText(row, "", 11, "BOTTOMLEFT", 5, 6, {0.72,0.77,0.84,1}); row.msg:SetWidth(550); row.msg:SetJustifyH("LEFT")
            p.rows[i] = row
        end
        p.scroll = CreateFrame("ScrollFrame", nil, box, "FauxScrollFrameTemplate")
        p.scroll:SetPoint("TOPLEFT", 0, -8); p.scroll:SetPoint("BOTTOMRIGHT", -2, 8)
        p.scroll:SetScript("OnVerticalScroll", function(self, offset) FauxScrollFrame_OnVerticalScroll(self, offset, 43, function() CS:RefreshLog() end) end)
    end

    -- Settings
    do
        local p = f.pages.Settings
        MakeText(p, "Settings", 20, "TOPLEFT", 20, -18)
        MakeText(p, "Tune how ChatSentry behaves.", 11, "TOPLEFT", 21, -47, {0.62,0.68,0.77,1})
        local settings = {
            {"caseSensitive", "Case-sensitive keyword matching"},
            {"blockExactWords", "Force exact-word matching for all keywords"},
            {"ignoreFriends", "Always allow messages from friends"},
            {"ignoreGuild", "Always allow messages from guild members"},
            {"ignorePartyRaid", "Always allow party and raid members"},
            {"notifyBlocked", "Print a small notice when a message is blocked"},
        }
        p.checks = {}
        for i, item in ipairs(settings) do
            local cb = MakeCheckbox(p, item[2], function(self)
                ChatSentryDB.settings[self.key] = self:GetChecked() and true or false
            end)
            cb.key = item[1]; cb:SetPoint("TOPLEFT", 26, -82-((i-1)*38)); p.checks[item[1]] = cb
        end
        local export = MakeButton(p, "Export Lists", 120, 30, function()
            local data = {"WORDS:"}
            for _,e in ipairs(ChatSentryDB.words) do tinsert(data, e.value .. "|" .. (e.mode or "contains")) end
            tinsert(data, "USERS:"); for _,e in ipairs(ChatSentryDB.users) do tinsert(data, e.value) end
            tinsert(data, "WHITELIST:"); for _,e in ipairs(ChatSentryDB.whitelist) do tinsert(data, e.value) end
            CS:ShowTransfer(table.concat(data, "\n"), false)
        end); export:SetPoint("BOTTOMLEFT", 24, 28)
        local import = MakeButton(p, "Import Lists", 120, 30, function() CS:ShowTransfer("", true) end); import:SetPoint("LEFT", export, "RIGHT", 10, 0)
        local reset = MakeButton(p, "Reset Addon", 120, 30, function()
            ChatSentryDB = DeepCopy(DEFAULTS); CS.sessionBlocked = 0; CS:RefreshAll(); Print("Settings reset.")
        end); reset:SetPoint("LEFT", import, "RIGHT", 10, 0)
    end

    f:ShowPage("Dashboard")
end

function CS:RefreshEntryPage(page, listName)
    if not page or not page:IsShown() then return end
    local list = ChatSentryDB[listName]
    local visibleRows = page.visibleRows or #page.rows
    FauxScrollFrame_Update(page.scroll, #list, visibleRows, 36)
    local offset = FauxScrollFrame_GetOffset(page.scroll)
    for i,row in ipairs(page.rows) do
        if i > visibleRows then row:Hide() else
        local idx = offset+i; local e = list[idx]; row.index = idx
        if e then
            row:Show(); row.value:SetText(e.value); row.check:SetChecked(e.enabled ~= false)
            row.modeText:SetText(listName == "words" and (e.mode == "exact" and "Whole word" or "Phrase") or "")
        else row:Hide() end
        end
    end
end

function CS:GetFilteredLog()
    local q = self.frame and self.frame.pages.Log.search:GetText() or ""
    q = lower(Trim(q)); if q == "" then return ChatSentryDB.log end
    local out = {}
    for _,e in ipairs(ChatSentryDB.log) do
        local hay = lower((e.sender or "") .. " " .. (e.message or "") .. " " .. (e.reason or "") .. " " .. (e.channel or ""))
        if find(hay, q, 1, true) then tinsert(out,e) end
    end
    return out
end

function CS:RefreshLog()
    if not self.frame or not self.frame.pages.Log:IsShown() then return end
    local p = self.frame.pages.Log; local list = self:GetFilteredLog()
    FauxScrollFrame_Update(p.scroll, #list, #p.rows, 43)
    local offset = FauxScrollFrame_GetOffset(p.scroll)
    for i,row in ipairs(p.rows) do
        local e = list[offset+i]
        if e then
            row:Show()
            row.top:SetText(format("|cffef9f28%s|r  |cff9ca8b8%s|r  |cffffffff%s|r  —  %s: |cffef9f28%s|r", date("%H:%M", e.time), e.channel, e.sender, e.reasonType, e.reason))
            local msg = e.message or ""; if #msg > 92 then msg = string.sub(msg,1,89).."..." end
            row.msg:SetText(msg)
        else row:Hide() end
    end
end

function CS:RefreshAll()
    if not ChatSentryDB or not self.frame then return end
    self.frame.enabledCheck:SetChecked(ChatSentryDB.enabled)
    local d = self.frame.pages.Dashboard
    d.cards.session.value:SetText(self.sessionBlocked or 0)
    d.cards.lifetime.value:SetText(ChatSentryDB.stats.lifetime or 0)
    d.cards.words.value:SetText(#ChatSentryDB.words)
    d.cards.users.value:SetText(#ChatSentryDB.users)
    if d.marketChecks then
        d.marketChecks.dp:SetChecked(MarketFilterEnabled("dp"))
        d.marketChecks.bt:SetChecked(MarketFilterEnabled("bt"))
    end
    for i,row in ipairs(d.recent) do
        local e = ChatSentryDB.log[i]
        if e then
            row:Show(); row.sender:SetText("|cffffffff"..(e.sender or "System").."|r  |cff7f8b9c"..(e.channel or "").."|r")
            row.reason:SetText("Blocked: "..(e.reason or ""))
            local msg=e.message or ""; if #msg>62 then msg=string.sub(msg,1,59).."..." end; row.msg:SetText(msg)
        else row:Hide() end
    end
    for _, key in ipairs({"Words","Users","Whitelist"}) do local p=self.frame.pages[key]; self:RefreshEntryPage(p,p.listName) end
    for event,cb in pairs(self.frame.pages.Channels.checks) do cb:SetChecked(ChatSentryDB.channels[event] ~= false) end
    for key,cb in pairs(self.frame.pages.Smart.checks) do cb:SetChecked(ChatSentryDB.settings[key] and true or false) end
    for key,cb in pairs(self.frame.pages.Settings.checks) do cb:SetChecked(ChatSentryDB.settings[key] and true or false) end
    self:RefreshLog()
end

function CS:ShowTransfer(text, importing)
    if not self.transfer then
        local f=CreateFrame("Frame",nil,UIParent); f:SetSize(520,360); f:SetPoint("CENTER"); f:SetFrameStrata("TOOLTIP"); Backdrop(f); f:Hide(); self.transfer=f
        f.title=MakeText(f,"Import / Export",18,"TOPLEFT",18,-16)
        local sf=CreateFrame("ScrollFrame",nil,f,"UIPanelScrollFrameTemplate"); sf:SetPoint("TOPLEFT",18,-50); sf:SetPoint("BOTTOMRIGHT",-38,56)
        local eb=CreateFrame("EditBox",nil,sf); eb:SetMultiLine(true); eb:SetAutoFocus(false); eb:SetFontObject(ChatFontNormal); eb:SetWidth(445); eb:SetHeight(245); eb:SetTextInsets(6,6,6,6); eb:SetScript("OnEscapePressed",function() f:Hide() end); sf:SetScrollChild(eb); f.edit=eb
        f.apply=MakeButton(f,"Import",90,28,function()
            wipe(ChatSentryDB.words); wipe(ChatSentryDB.users); wipe(ChatSentryDB.whitelist)
            local section
            for line in string.gmatch(f.edit:GetText().."\n","(.-)\n") do
                line=Trim(line)
                if line=="WORDS:" or line=="USERS:" or line=="WHITELIST:" then section=line
                elseif line~="" and section then
                    if section=="WORDS:" then local v,m=string.match(line,"^(.-)|([^|]+)$"); AddListEntry(ChatSentryDB.words,v or line,m or "contains")
                    elseif section=="USERS:" then AddListEntry(ChatSentryDB.users,line,"exact")
                    else AddListEntry(ChatSentryDB.whitelist,line,"exact") end
                end
            end
            f:Hide(); CS:RefreshAll(); Print("Lists imported.")
        end); f.apply:SetPoint("BOTTOMLEFT",18,16)
        local done=MakeButton(f,"Close",90,28,function() f:Hide() end); done:SetPoint("BOTTOMRIGHT",-18,16)
    end
    self.transfer.edit:SetText(text or ""); self.transfer.edit:HighlightText(); self.transfer.apply:SetShown(importing); self.transfer.title:SetText(importing and "Import Lists" or "Export Lists"); self.transfer:Show()
end

local function CreateMinimapButton()
    local b=CreateFrame("Button","ChatSentryMinimapButton",Minimap); b:SetSize(32,32); b:SetFrameStrata("MEDIUM"); b:SetFrameLevel(8); b:RegisterForClicks("LeftButtonUp","RightButtonUp"); b:RegisterForDrag("LeftButton")
    local icon=b:CreateTexture(nil,"ARTWORK"); icon:SetTexture("Interface\\AddOns\\ChatSentry\\Textures\\Shield.tga"); icon:SetSize(26,26); icon:SetPoint("CENTER")
    local border=b:CreateTexture(nil,"OVERLAY"); border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder"); border:SetSize(54,54); border:SetPoint("TOPLEFT")
    local function Position()
        local a=math.rad(ChatSentryDB.minimap.angle or 225); b:SetPoint("CENTER",Minimap,"CENTER",52*math.cos(a),52*math.sin(a))
    end
    b:SetScript("OnClick",function(self, button)
        if IsShiftKeyDown() then
            ChatSentryDB.enabled = not ChatSentryDB.enabled
            Print(ChatSentryDB.enabled and "Filtering enabled." or "Filtering disabled.")
            CS:RefreshAll()
            return
        end

        if button == "RightButton" then
            CS.frame:Show()
            CS.frame:ShowPage("Settings")
            CS:RefreshAll()
            return
        end

        if CS.frame:IsShown() and CS.frame.activePage == "Dashboard" then
            CS.frame:Hide()
        else
            CS.frame:Show()
            CS.frame:ShowPage("Dashboard")
            CS:RefreshAll()
        end
    end)
    b:SetScript("OnDragStart",function() b:SetScript("OnUpdate",function()
        local mx,my=Minimap:GetCenter(); local x,y=GetCursorPosition(); local s=UIParent:GetEffectiveScale(); x,y=x/s,y/s
        ChatSentryDB.minimap.angle=math.deg(math.atan2(y-my,x-mx)); Position()
    end) end)
    b:SetScript("OnDragStop",function() b:SetScript("OnUpdate",nil) end)
    b:SetScript("OnEnter",function(self)
        GameTooltip:SetOwner(self,"ANCHOR_LEFT")
        GameTooltip:AddLine("ChatSentry",1,.68,.25)
        GameTooltip:AddLine("Left-click: Open dashboard",.8,.8,.8)
        GameTooltip:AddLine("Right-click: Open settings",.8,.8,.8)
        GameTooltip:AddLine("Shift-click: Toggle filtering",.8,.8,.8)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave",function() GameTooltip:Hide() end)
    Position(); b:SetShown(not ChatSentryDB.minimap.hide); CS.minimapButton=b
end

local function SanitizeSavedLists()
    for _, listName in ipairs({"words", "users", "whitelist"}) do
        local list = ChatSentryDB[listName] or {}
        for i = #list, 1, -1 do
            local entry = list[i]
            if type(entry) == "string" then entry = { value = entry, enabled = true, mode = "contains" }; list[i] = entry end
            entry.value = Trim(entry.value or "")
            if entry.value == "" then tremove(list, i)
            else
                entry.enabled = entry.enabled ~= false
                if listName == "words" then entry.mode = entry.mode == "exact" and "exact" or "contains" else entry.mode = "exact" end
            end
        end
        ChatSentryDB[listName] = list
    end
end

SLASH_CHATSENTRY1="/chatsentry"; SLASH_CHATSENTRY2="/cs"
SlashCmdList.CHATSENTRY=function(msg)
    msg=Trim(msg)
    local cmd,arg=string.match(msg,"^(%S*)%s*(.-)$"); cmd=lower(cmd or "")
    if cmd=="add" then local ok,err=AddListEntry(ChatSentryDB.words,arg,"contains"); Print(ok and ("Added keyword: "..arg) or err); CS:RefreshAll()
    elseif cmd=="user" then local ok,err=AddListEntry(ChatSentryDB.users,arg,"exact"); Print(ok and ("Blocked user: "..arg) or err); CS:RefreshAll()
    elseif cmd=="on" then ChatSentryDB.enabled=true; Print("Filtering enabled."); CS:RefreshAll()
    elseif cmd=="off" then ChatSentryDB.enabled=false; Print("Filtering disabled."); CS:RefreshAll()
    else if CS.frame:IsShown() then CS.frame:Hide() else CS.frame:Show(); CS:RefreshAll() end end
end

CS:RegisterEvent("ADDON_LOADED")
CS:RegisterEvent("PLAYER_ENTERING_WORLD")
CS:SetScript("OnEvent",function(self,event,arg1)
    if event=="ADDON_LOADED" and arg1==ADDON then
        ChatSentryDB=MergeDefaults(ChatSentryDB or {},DeepCopy(DEFAULTS)); SanitizeSavedLists(); self.sessionBlocked=0
        CreateUI(); CreateMinimapButton()
        for _,ev in ipairs(EVENTS) do ChatFrame_AddMessageEventFilter(ev, CS.Filter) end
        self:InstallMessageHandlerBridge()
        Print("Loaded. Type |cffffffff/cs|r to open.")
        self:UnregisterEvent("ADDON_LOADED")
    elseif event=="PLAYER_ENTERING_WORLD" and ChatSentryDB then
        self:InstallMessageHandlerBridge()
    end
end)
