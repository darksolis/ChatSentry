-- ChatSentry v1.6.4
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

-- Some private-server addons leak hidden protocol packets into ordinary chat events.
-- Ignore them completely so ChatSentry never blocks, logs, or counts them as spam.
local function IsHiddenAddonProtocol(msg)
    if type(msg) ~= "string" then return false end
    local clean = CleanMessage(msg)
    return find(clean, "^LC%d*:") ~= nil
        or find(clean, "^LC%d+|") ~= nil
        or find(clean, "^BLFG%d*[%^~:]") ~= nil
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
    if IsHiddenAddonProtocol(msg) then return nil end
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
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 14,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    frame:SetBackdropColor(unpack(bg or {0.02, 0.04, 0.07, 0.96}))
    frame:SetBackdropBorderColor(unpack(border or {0.28, 0.45, 0.72, 0.95}))
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
    b:SetSize(width or 100, height or 30)
    b.baseBg = {0.025, 0.07, 0.12, 0.96}
    b.baseBorder = {0.22, 0.39, 0.62, 0.92}
    Backdrop(b, b.baseBg, b.baseBorder)

    b.highlight = b:CreateTexture(nil, "BORDER")
    b.highlight:SetTexture("Interface\\Buttons\\WHITE8X8")
    b.highlight:SetPoint("TOPLEFT", 4, -4)
    b.highlight:SetPoint("TOPRIGHT", -4, -4)
    b.highlight:SetHeight(1)
    b.highlight:SetVertexColor(1, 1, 1, 0.08)

    b.label = MakeText(b, text, 12, "CENTER", 0, 0, {0.92, 0.96, 1.00, 1})
    b:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.05, 0.11, 0.19, 0.98)
        self:SetBackdropBorderColor(0.95, 0.68, 0.22, 1)
        self.label:SetTextColor(1.00, 0.90, 0.68, 1)
    end)
    b:SetScript("OnLeave", function(self)
        self:SetBackdropColor(unpack(self.baseBg))
        self:SetBackdropBorderColor(unpack(self.baseBorder))
        self.label:SetTextColor(0.92, 0.96, 1.00, 1)
    end)
    b:SetScript("OnMouseDown", function(self) self.label:SetPoint("CENTER", 1, -1) end)
    b:SetScript("OnMouseUp", function(self) self.label:SetPoint("CENTER", 0, 0) end)
    b:SetScript("OnClick", onClick)
    return b
end

local function MakeEditBox(parent, width, height)
    local box = CreateFrame("EditBox", nil, parent)
    box:SetSize(width, height or 30)
    box:SetAutoFocus(false)
    box:SetFontObject(ChatFontNormal)
    box:SetTextInsets(10, 10, 0, 0)
    Backdrop(box, {0.01, 0.03, 0.06, 0.94}, {0.20, 0.33, 0.53, 0.90})
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEditFocusGained", function(self) self:SetBackdropBorderColor(0.95, 0.68, 0.22, 1) end)
    box:SetScript("OnEditFocusLost", function(self) self:SetBackdropBorderColor(0.20, 0.33, 0.53, 0.90) end)
    return box
end

local function MakeCheckbox(parent, label, onClick)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb.text = MakeText(cb, label, 12, "LEFT", 27, 0, {0.84, 0.90, 0.98, 1})
    cb.text:SetJustifyH("LEFT")
    if label and label ~= "" then cb:SetHitRectInsets(0, -180, 0, 0) end
    cb:SetScript("OnClick", function(self)
        if self.text then
            if self:GetChecked() then self.text:SetTextColor(0.97, 0.77, 0.29, 1)
            else self.text:SetTextColor(0.84, 0.90, 0.98, 1) end
        end
        if onClick then onClick(self) end
    end)
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
    f:SetSize(1060, 680)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true); f:EnableMouse(true); f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    Backdrop(f, {0.008, 0.024, 0.045, 0.985}, {0.56, 0.41, 0.18, 0.95})
    f:Hide()
    CS.frame = f

    local shadow = f:CreateTexture(nil, "BACKGROUND")
    shadow:SetAllPoints(f)
    shadow:SetTexture("Interface\\Buttons\\WHITE8X8")
    shadow:SetVertexColor(0, 0, 0, 0.15)

    local header = CreateFrame("Frame", nil, f)
    header:SetPoint("TOPLEFT", 12, -12)
    header:SetPoint("TOPRIGHT", -12, -12)
    header:SetHeight(84)
    Backdrop(header, {0.012, 0.05, 0.10, 0.99}, {0.23, 0.38, 0.60, 1})
    local hbg = header:CreateTexture(nil, "BACKGROUND")
    hbg:SetAllPoints(header)
    hbg:SetTexture("Interface\\Buttons\\WHITE8X8")
    hbg:SetGradientAlpha("HORIZONTAL", 0.05, 0.10, 0.17, 0.96, 0.01, 0.03, 0.08, 0.96)

    local logo = header:CreateTexture(nil, "ARTWORK")
    logo:SetTexture("Interface\\AddOns\\ChatSentry\\Textures\\Shield.tga")
    logo:SetSize(56, 56)
    logo:SetPoint("LEFT", 18, 0)

    local title = MakeText(header, "CHAT|cffefb94fSENTRY|r", 25, "TOPLEFT", 84, -12)
    local subtitle = MakeText(header, "Private-server chat filtering and moderation", 12, "TOPLEFT", 86, -44, {0.68, 0.76, 0.88, 1})
    title:SetFont(STANDARD_TEXT_FONT, 25, "OUTLINE")

    local statusPill = CreateFrame("Frame", nil, header)
    statusPill:SetSize(196, 42)
    statusPill:SetPoint("RIGHT", -56, 0)
    Backdrop(statusPill, {0.02, 0.07, 0.12, 0.95}, {0.76, 0.57, 0.22, 0.95})
    local statusGlow = statusPill:CreateTexture(nil, "BACKGROUND")
    statusGlow:SetAllPoints(statusPill)
    statusGlow:SetTexture("Interface\\Buttons\\WHITE8X8")
    statusGlow:SetVertexColor(1, 1, 1, 0.02)

    local enabled = MakeCheckbox(statusPill, "Filtering Enabled", function(self)
        ChatSentryDB.enabled = self:GetChecked() and true or false
        CS:RefreshAll()
    end)
    enabled:SetPoint("LEFT", 8, 0)
    f.enabledCheck = enabled
    f.statusPill = statusPill
    f.statusText = enabled.text

    local close = MakeButton(header, "X", 26, 26, function() f:Hide() end)
    close:SetPoint("TOPRIGHT", -8, -8)
    close.baseBg = {0.18, 0.05, 0.05, 0.95}
    close.baseBorder = {0.70, 0.20, 0.20, 0.95}
    close:SetBackdropColor(unpack(close.baseBg))
    close:SetBackdropBorderColor(unpack(close.baseBorder))

    local nav = CreateFrame("Frame", nil, f)
    nav:SetPoint("TOPLEFT", 12, -104)
    nav:SetPoint("BOTTOMLEFT", 12, 12)
    nav:SetWidth(220)
    Backdrop(nav, {0.01, 0.03, 0.06, 0.97}, {0.17, 0.30, 0.48, 0.85})
    local navbg = nav:CreateTexture(nil, "BACKGROUND")
    navbg:SetAllPoints(nav)
    navbg:SetTexture("Interface\\Buttons\\WHITE8X8")
    navbg:SetGradientAlpha("VERTICAL", 0.02, 0.06, 0.10, 0.20, 0.00, 0.00, 0.00, 0.00)

    local content = CreateFrame("Frame", nil, f)
    content:SetPoint("TOPLEFT", nav, "TOPRIGHT", 10, 0)
    content:SetPoint("BOTTOMRIGHT", -12, 12)
    Backdrop(content, {0.01, 0.035, 0.065, 0.97}, {0.17, 0.30, 0.48, 0.85})
    f.content = content

    local navFooter = CreateFrame("Frame", nil, nav)
    navFooter:SetPoint("BOTTOMLEFT", 12, 12)
    navFooter:SetPoint("BOTTOMRIGHT", -12, 12)
    navFooter:SetHeight(78)
    Backdrop(navFooter, {0.015, 0.055, 0.095, 0.94}, {0.17, 0.30, 0.48, 0.70})
    MakeText(navFooter, "ADDON STATUS", 10, "TOPLEFT", 14, -12, {0.55, 0.65, 0.78, 1})
    f.footerStatus = MakeText(navFooter, "|cff4bd66f●|r  Active", 13, "TOPLEFT", 14, -32, {0.88, 0.94, 1.00, 1})
    MakeText(navFooter, "v1.6.4  •  By Darksolis", 11, "TOPLEFT", 14, -54, {0.68, 0.76, 0.90, 1})

    f.pages, f.navButtons = {}, {}
    local tabs = {
        {"Dashboard", "Dashboard", "Interface\\Icons\\INV_Misc_Spyglass_03"},
        {"Blocked Words", "Words", "Interface\\Icons\\INV_Misc_Note_01"},
        {"Blocked Users", "Users", "Interface\\Icons\\INV_Misc_GroupLooking"},
        {"Exceptions", "Whitelist", "Interface\\Icons\\Ability_Paladin_ShieldoftheTemplar"},
        {"Channels", "Channels", "Interface\\Icons\\INV_Misc_Head_Dragon_Bronze"},
        {"Smart Filters", "Smart", "Interface\\Icons\\INV_Gizmo_02"},
        {"Blocked Log", "Log", "Interface\\Icons\\INV_Scroll_11"},
        {"Settings", "Settings", "Interface\\Icons\\INV_Gizmo_GoblinBoomBox_01"},
    }

    local function CreateNavButton(parent, text, iconPath, onClick)
        local b = CreateFrame("Button", nil, parent)
        b:SetSize(194, 42)
        b.baseBg = {0.018, 0.055, 0.095, 0.94}
        b.baseBorder = {0.17, 0.30, 0.48, 0.82}
        Backdrop(b, b.baseBg, b.baseBorder)

        b.accent = b:CreateTexture(nil, "ARTWORK")
        b.accent:SetTexture("Interface\\Buttons\\WHITE8X8")
        b.accent:SetPoint("TOPLEFT", 0, -3)
        b.accent:SetPoint("BOTTOMLEFT", 0, 3)
        b.accent:SetWidth(3)
        b.accent:SetVertexColor(0.95, 0.68, 0.22, 0)

        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetTexture(iconPath)
        b.icon:SetSize(18, 18)
        b.icon:SetPoint("LEFT", 14, 0)
        b.icon:SetVertexColor(0.64, 0.73, 0.86, 1)

        b.label = MakeText(b, text, 13, "LEFT", 42, 0, {0.86, 0.92, 1.00, 1})
        b.label:SetFont(STANDARD_TEXT_FONT, 13, "")
        b:SetScript("OnEnter", function(self)
            self:SetBackdropColor(0.04, 0.10, 0.17, 0.98)
            self:SetBackdropBorderColor(0.34, 0.50, 0.78, 1)
        end)
        b:SetScript("OnLeave", function(self)
            if not self.isActive then
                self:SetBackdropColor(unpack(self.baseBg))
                self:SetBackdropBorderColor(unpack(self.baseBorder))
            end
        end)
        b:SetScript("OnClick", onClick)
        return b
    end

    function f:ShowPage(key)
        for name, page in pairs(self.pages) do page:SetShown(name == key) end
        for name, b in pairs(self.navButtons) do
            b.isActive = (name == key)
            if b.isActive then
                b:SetBackdropColor(0.06, 0.13, 0.20, 0.98)
                b:SetBackdropBorderColor(0.95, 0.68, 0.22, 1)
                b.accent:SetVertexColor(0.95, 0.68, 0.22, 1)
                b.icon:SetVertexColor(1.00, 0.82, 0.32, 1)
                b.label:SetTextColor(1.00, 0.82, 0.32, 1)
            else
                b:SetBackdropColor(unpack(b.baseBg))
                b:SetBackdropBorderColor(unpack(b.baseBorder))
                b.accent:SetVertexColor(0.95, 0.68, 0.22, 0)
                b.icon:SetVertexColor(0.64, 0.73, 0.86, 1)
                b.label:SetTextColor(0.86, 0.92, 1.00, 1)
            end
        end
        self.activePage = key
        CS:RefreshAll()
    end

    for i, tab in ipairs(tabs) do
        local b = CreateNavButton(nav, tab[1], tab[3], function() f:ShowPage(tab[2]) end)
        b:SetPoint("TOPLEFT", 13, -14 - ((i-1) * 48))
        f.navButtons[tab[2]] = b
        local p = CreateFrame("Frame", nil, content)
        p:SetAllPoints()
        p:Hide()
        f.pages[tab[2]] = p
    end

    local function PageHeader(parent, titleText, subtitleText)
        local title = MakeText(parent, titleText, 23, "TOPLEFT", 24, -22, {0.94, 0.96, 1.00, 1})
        title:SetFont(STANDARD_TEXT_FONT, 23, "OUTLINE")
        MakeText(parent, subtitleText, 12, "TOPLEFT", 26, -56, {0.68, 0.76, 0.88, 1})
        local div = parent:CreateTexture(nil, "ARTWORK")
        div:SetTexture("Interface\\Buttons\\WHITE8X8")
        div:SetVertexColor(0.72, 0.52, 0.20, 0.55)
        div:SetPoint("TOPLEFT", 24, -74)
        div:SetPoint("TOPRIGHT", -24, -74)
        div:SetHeight(1)
    end

    local function MakePanel(parent, x1, y1, x2, y2)
        local box = CreateFrame("Frame", nil, parent)
        box:SetPoint("TOPLEFT", x1, y1)
        box:SetPoint("BOTTOMRIGHT", x2, y2)
        Backdrop(box, {0.015, 0.05, 0.09, 0.95}, {0.18, 0.31, 0.49, 0.85})
        local sheen = box:CreateTexture(nil, "BACKGROUND")
        sheen:SetTexture("Interface\\Buttons\\WHITE8X8")
        sheen:SetPoint("TOPLEFT", 4, -4)
        sheen:SetPoint("TOPRIGHT", -4, -4)
        sheen:SetHeight(1)
        sheen:SetVertexColor(1, 1, 1, 0.06)
        return box
    end

    -- Dashboard
    do
        local p = f.pages.Dashboard
        PageHeader(p, "Dashboard", "Live visibility into what ChatSentry is removing from chat.")
        p.cards = {}
        local cards = {{"Session", "session"}, {"Lifetime", "lifetime"}, {"Words", "words"}, {"Users", "users"}}
        for i, c in ipairs(cards) do
            local card = CreateFrame("Frame", nil, p)
            card:SetSize(172, 94)
            card:SetPoint("TOPLEFT", 24 + ((i-1) * 182), -92)
            Backdrop(card, {0.018, 0.055, 0.095, 0.95}, {0.20, 0.33, 0.53, 0.85})
            local bar = card:CreateTexture(nil, "ARTWORK")
            bar:SetTexture("Interface\\Buttons\\WHITE8X8")
            bar:SetPoint("TOPLEFT", 1, -1)
            bar:SetPoint("TOPRIGHT", -1, -1)
            bar:SetHeight(2)
            bar:SetVertexColor(0.95, 0.68, 0.22, 0.95)
            card.value = MakeText(card, "0", 28, "TOPLEFT", 16, -18, {0.97, 0.74, 0.24, 1})
            card.value:SetFont(STANDARD_TEXT_FONT, 28, "OUTLINE")
            MakeText(card, c[1], 12, "TOPLEFT", 16, -62, {0.68, 0.76, 0.88, 1})
            p.cards[c[2]] = card
        end

        local quick = CreateFrame("Frame", nil, p)
        quick:SetPoint("TOPLEFT", 24, -198)
        quick:SetPoint("TOPRIGHT", -24, -198)
        quick:SetHeight(56)
        Backdrop(quick, {0.015, 0.05, 0.09, 0.95}, {0.18, 0.31, 0.49, 0.85})
        local quickSheen = quick:CreateTexture(nil, "BACKGROUND")
        quickSheen:SetTexture("Interface\Buttons\WHITE8X8")
        quickSheen:SetPoint("TOPLEFT", 4, -4)
        quickSheen:SetPoint("TOPRIGHT", -4, -4)
        quickSheen:SetHeight(1)
        quickSheen:SetVertexColor(1, 1, 1, 0.06)
        MakeText(quick, "Quick Market Filters", 13, "LEFT", 14, 10, {0.90, 0.94, 1.00, 1})
        MakeText(quick, "Fast toggles for the most common currency spam.", 11, "LEFT", 14, -12, {0.63, 0.73, 0.86, 1})
        p.marketChecks = {}
        local dp = MakeCheckbox(quick, "Donation Points / DP", function(self)
            SetMarketFilter("dp", self:GetChecked() and true or false)
            CS:RefreshAll()
        end)
        dp:SetPoint("LEFT", 336, 10)
        p.marketChecks.dp = dp
        local bt = MakeCheckbox(quick, "Bazaar Tokens / BT", function(self)
            SetMarketFilter("bt", self:GetChecked() and true or false)
            CS:RefreshAll()
        end)
        bt:SetPoint("LEFT", 566, 10)
        p.marketChecks.bt = bt

        MakeText(p, "Recent Blocks", 15, "TOPLEFT", 24, -278, {0.92, 0.96, 1.00, 1})
        local recentBox = MakePanel(p, 24, -304, -24, 24)
        p.recent = {}
        p.recentVisibleRows = 5
        for i = 1, p.recentVisibleRows do
            local row = CreateFrame("Frame", nil, recentBox)
            row:SetHeight(46)
            row:SetPoint("TOPLEFT", 8, -8 - ((i-1) * 48))
            row:SetPoint("RIGHT", -32, 0)
            if i % 2 == 1 then row:SetBackdrop({bgFile="Interface\Buttons\WHITE8X8"}); row:SetBackdropColor(1, 1, 1, 0.025) end
            row.sender = MakeText(row, "", 11, "TOPLEFT", 10, -8)
            row.sender:SetWidth(245)
            row.sender:SetJustifyH("LEFT")
            row.reason = MakeText(row, "", 10, "TOPLEFT", 10, -26, {0.97, 0.74, 0.24, 1})
            row.reason:SetWidth(245)
            row.reason:SetJustifyH("LEFT")
            row.msg = MakeText(row, "", 11, "LEFT", 270, 0, {0.75, 0.82, 0.92, 1})
            row.msg:SetWidth(430)
            row.msg:SetJustifyH("LEFT")
            p.recent[i] = row
        end
        p.recentScroll = CreateFrame("ScrollFrame", nil, recentBox, "FauxScrollFrameTemplate")
        p.recentScroll:SetPoint("TOPLEFT", 0, -8)
        p.recentScroll:SetPoint("BOTTOMRIGHT", -2, 8)
        p.recentScroll:SetScript("OnVerticalScroll", function(self, offset)
            FauxScrollFrame_OnVerticalScroll(self, offset, 48, function() CS:RefreshDashboardRecent() end)
        end)
    end

    local function BuildEntryPage(key, titleText, subtitleText, listName, allowMode)
        local p = f.pages[key]
        PageHeader(p, titleText, subtitleText)
        p.input = MakeEditBox(p, 430, 32)
        p.input:SetPoint("TOPLEFT", 24, -92)
        p.mode = "contains"
        if allowMode then
            p.modeButton = MakeButton(p, "Phrase", 112, 32, function(self)
                p.mode = p.mode == "contains" and "exact" or "contains"
                self.label:SetText(p.mode == "contains" and "Phrase" or "Whole word")
            end)
            p.modeButton:SetPoint("LEFT", p.input, "RIGHT", 10, 0)
        end
        local add = MakeButton(p, listName == "words" and "Add Filter" or "Add", 98, 32, function()
            local ok, err = AddListEntry(ChatSentryDB[listName], p.input:GetText(), allowMode and p.mode or "exact")
            if not ok then Print(err) else p.input:SetText(""); CS:RefreshAll() end
        end)
        add:SetPoint("LEFT", allowMode and p.modeButton or p.input, "RIGHT", 10, 0)
        p.input:SetScript("OnEnterPressed", function(self) add:Click(); self:ClearFocus() end)

        local boxTop = listName == "words" and -172 or -138
        local box = MakePanel(p, 24, boxTop, -24, 24)
        local hdr = CreateFrame("Frame", nil, box)
        hdr:SetPoint("TOPLEFT", 8, -8)
        hdr:SetPoint("TOPRIGHT", -24, -8)
        hdr:SetHeight(30)
        hdr:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8"})
        hdr:SetBackdropColor(1, 1, 1, 0.03)
        MakeText(hdr, listName == "words" and "FILTER" or "VALUE", 11, "LEFT", 12, 0, {0.76, 0.84, 0.96, 1})
        if listName == "words" then MakeText(hdr, "MATCH TYPE", 11, "LEFT", 520, 0, {0.76, 0.84, 0.96, 1}) end
        MakeText(hdr, "ACTION", 11, "RIGHT", -20, 0, {0.76, 0.84, 0.96, 1})

        p.rows = {}
        for i = 1, 9 do
            local row = CreateFrame("Frame", nil, box)
            row:SetHeight(42)
            row:SetPoint("TOPLEFT", 8, -42 - ((i-1) * 44))
            row:SetPoint("RIGHT", -26, 0)
            if i % 2 == 1 then row:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8"}); row:SetBackdropColor(1, 1, 1, 0.02) end
            row.check = MakeCheckbox(row, "", function(self)
                local entry = ChatSentryDB[listName][self:GetParent().index]
                if entry then entry.enabled = self:GetChecked() and true or false end
            end)
            row.check:SetPoint("LEFT", 2, 0)
            row.value = MakeText(row, "", 12, "LEFT", 34, 0)
            row.value:SetWidth(470)
            row.value:SetJustifyH("LEFT")
            row.modeText = MakeText(row, "", 11, "LEFT", 520, 0, {0.53, 0.70, 0.98, 1})
            row.remove = MakeButton(row, "Remove", 92, 28, function()
                RemoveListEntry(ChatSentryDB[listName], row.index)
                CS:RefreshAll()
            end)
            row.remove:SetPoint("RIGHT", -4, 0)
            p.rows[i] = row
        end
        p.scroll = CreateFrame("ScrollFrame", nil, box, "FauxScrollFrameTemplate")
        p.scroll:SetPoint("TOPLEFT", 0, -42)
        p.scroll:SetPoint("BOTTOMRIGHT", -2, 8)
        p.scroll:SetScript("OnVerticalScroll", function(self, offset)
            FauxScrollFrame_OnVerticalScroll(self, offset, 44, function() CS:RefreshEntryPage(p, listName) end)
        end)
        p.listName = listName
        p.visibleRows = 9
    end

    BuildEntryPage("Words", "Blocked Words", "Only matching messages are hidden. Phrase is literal; Whole word avoids partial matches.", "words", true)
    do
        local p = f.pages.Words
        p.input:SetWidth(315)
        local test = MakeButton(p, "Test Message", 120, 32, function()
            local sample = p.testInput:GetText() or ""
            local matched
            for _, entry in ipairs(ChatSentryDB.words) do
                if MatchWord(CleanMessage(sample), entry) then matched = entry.value; break end
            end
            p.testResult:SetText(matched and ("Would block: |cffefb94f" .. matched .. "|r") or "No blocked word matched.")
        end)
        test:SetPoint("TOPRIGHT", -24, -92)
        p.testInput = MakeEditBox(p, 430, 30)
        p.testInput:SetPoint("TOPLEFT", 24, -132)
        p.testInput:SetText("Paste a sample chat message here")
        p.testInput:SetScript("OnEditFocusGained", function(self) if self:GetText() == "Paste a sample chat message here" then self:SetText("") end end)
        p.testResult = MakeText(p, "Test a message before relying on the filter.", 11, "LEFT", 468, -148, {0.68, 0.76, 0.88, 1})
    end
    BuildEntryPage("Users", "Blocked Users", "Hide every message sent by specific players.", "users", false)
    BuildEntryPage("Whitelist", "Exceptions", "Trusted players here always bypass ChatSentry filters.", "whitelist", false)

    -- Channels
    do
        local p = f.pages.Channels
        PageHeader(p, "Channels", "Choose where keyword filtering is allowed to run.")
        local note = CreateFrame("Frame", nil, p)
        note:SetPoint("TOPLEFT", 24, -92)
        note:SetPoint("TOPRIGHT", -24, -92)
        note:SetHeight(48)
        Backdrop(note, {0.015, 0.05, 0.09, 0.95}, {0.18, 0.31, 0.49, 0.85})
        MakeText(note, "Checked means ChatSentry evaluates that channel for your rules. It does not mute an entire channel outright.", 11, "LEFT", 12, 0, {0.76, 0.84, 0.96, 1})
        local box = MakePanel(p, 24, -150, -24, 24)
        p.checks = {}
        for i, event in ipairs(EVENTS) do
            local col = (i-1) % 2
            local row = floor((i-1) / 2)
            local cb = MakeCheckbox(box, EVENT_LABELS[event], function(self)
                ChatSentryDB.channels[self.event] = self:GetChecked() and true or false
            end)
            cb.event = event
            cb:SetPoint("TOPLEFT", 22 + (col * 360), -22 - (row * 42))
            p.checks[event] = cb
        end
    end

    -- Smart Filters
    do
        local p = f.pages.Smart
        PageHeader(p, "Smart Filters", "Behavior-based protection for repetitive and common public-channel spam.")
        local note = CreateFrame("Frame", nil, p)
        note:SetPoint("TOPLEFT", 24, -92)
        note:SetPoint("TOPRIGHT", -24, -92)
        note:SetHeight(56)
        Backdrop(note, {0.015, 0.05, 0.09, 0.95}, {0.18, 0.31, 0.49, 0.85})
        local noteText = MakeText(note, "Repeat and burst protection still applies in public chat, even to friends or guildmates. Only explicit whitelist entries bypass flood protection.", 10, "LEFT", 12, 0, {0.76, 0.84, 0.96, 1})
        noteText:SetWidth(720)
        noteText:SetJustifyH("LEFT")
        local box = MakePanel(p, 24, -158, -24, 24)
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
            local cb = MakeCheckbox(box, item[2], function(self)
                ChatSentryDB.settings[self.key] = self:GetChecked() and true or false
            end)
            cb.key = item[1]
            cb:SetPoint("TOPLEFT", 22, -20 - ((i-1) * 42))
            p.checks[item[1]] = cb
        end
    end

    -- Log
    do
        local p = f.pages.Log
        PageHeader(p, "Blocked Log", "Everything removed from chat is recorded here.")
        p.search = MakeEditBox(p, 420, 32)
        p.search:SetPoint("TOPLEFT", 24, -92)
        p.search:SetScript("OnTextChanged", function() CS:RefreshLog() end)
        local clear = MakeButton(p, "Clear Log", 104, 32, function() wipe(ChatSentryDB.log); CS:RefreshAll() end)
        clear:SetPoint("TOPRIGHT", -24, -92)
        local box = MakePanel(p, 24, -138, -24, 24)
        p.rows = {}
        for i = 1, 9 do
            local row = CreateFrame("Frame", nil, box)
            row:SetHeight(41)
            row:SetPoint("TOPLEFT", 8, -8 - ((i-1) * 43))
            row:SetPoint("RIGHT", -34, 0)
            if i % 2 == 1 then row:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8"}); row:SetBackdropColor(1, 1, 1, 0.025) end
            row.top = MakeText(row, "", 10, "TOPLEFT", 6, -6)
            row.top:SetWidth(660)
            row.top:SetJustifyH("LEFT")
            row.msg = MakeText(row, "", 11, "BOTTOMLEFT", 6, 6, {0.72, 0.80, 0.92, 1})
            row.msg:SetWidth(660)
            row.msg:SetJustifyH("LEFT")
            p.rows[i] = row
        end
        p.scroll = CreateFrame("ScrollFrame", nil, box, "FauxScrollFrameTemplate")
        p.scroll:SetPoint("TOPLEFT", 0, -8)
        p.scroll:SetPoint("BOTTOMRIGHT", -2, 8)
        p.scroll:SetScript("OnVerticalScroll", function(self, offset) FauxScrollFrame_OnVerticalScroll(self, offset, 43, function() CS:RefreshLog() end) end)
    end

    -- Settings
    do
        local p = f.pages.Settings
        PageHeader(p, "Settings", "Tune how ChatSentry behaves.")
        local box = MakePanel(p, 24, -92, -24, 68)
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
            local cb = MakeCheckbox(box, item[2], function(self)
                ChatSentryDB.settings[self.key] = self:GetChecked() and true or false
            end)
            cb.key = item[1]
            cb:SetPoint("TOPLEFT", 22, -18 - ((i-1) * 42))
            p.checks[item[1]] = cb
        end
        local export = MakeButton(p, "Export Lists", 120, 32, function()
            local data = {"WORDS:"}
            for _, e in ipairs(ChatSentryDB.words) do tinsert(data, e.value .. "|" .. (e.mode or "contains")) end
            tinsert(data, "USERS:"); for _, e in ipairs(ChatSentryDB.users) do tinsert(data, e.value) end
            tinsert(data, "WHITELIST:"); for _, e in ipairs(ChatSentryDB.whitelist) do tinsert(data, e.value) end
            CS:ShowTransfer(table.concat(data, "\n"), false)
        end)
        export:SetPoint("BOTTOMLEFT", 24, 24)
        local import = MakeButton(p, "Import Lists", 120, 32, function() CS:ShowTransfer("", true) end)
        import:SetPoint("LEFT", export, "RIGHT", 12, 0)
        local reset = MakeButton(p, "Reset Addon", 120, 32, function()
            ChatSentryDB = DeepCopy(DEFAULTS)
            CS.sessionBlocked = 0
            CS:RefreshAll()
            Print("Settings reset.")
        end)
        reset:SetPoint("LEFT", import, "RIGHT", 12, 0)
    end

    f:ShowPage("Dashboard")
end

function CS:RefreshEntryPage(page, listName)
    if not page or not page:IsShown() then return end
    local list = ChatSentryDB[listName]
    local visibleRows = page.visibleRows or #page.rows
    FauxScrollFrame_Update(page.scroll, #list, visibleRows, 44)
    local offset = FauxScrollFrame_GetOffset(page.scroll)
    for i, row in ipairs(page.rows) do
        if i > visibleRows then row:Hide() else
            local idx = offset + i
            local e = list[idx]
            row.index = idx
            if e then
                row:Show()
                row.value:SetText(e.value)
                row.check:SetChecked(e.enabled ~= false)
                row.modeText:SetText(listName == "words" and (e.mode == "exact" and "Whole word" or "Phrase") or "")
            else
                row:Hide()
            end
        end
    end
end
function CS:RefreshDashboardRecent()
    if not self.frame or not self.frame.pages.Dashboard:IsShown() then return end
    local p = self.frame.pages.Dashboard
    local list = ChatSentryDB.log or {}
    local visible = p.recentVisibleRows or #p.recent
    FauxScrollFrame_Update(p.recentScroll, #list, visible, 48)
    local offset = FauxScrollFrame_GetOffset(p.recentScroll)
    for i, row in ipairs(p.recent) do
        local e = list[offset + i]
        if e then
            row:Show()
            local sender = tostring(e.sender or "System")
            local channel = tostring(e.channel or "")
            if #sender > 22 then sender = string.sub(sender, 1, 19) .. "..." end
            if #channel > 15 then channel = string.sub(channel, 1, 12) .. "..." end
            row.sender:SetText("|cffffffff" .. sender .. "|r  |cff7f8b9c" .. channel .. "|r")
            local reason = tostring(e.reason or "")
            if #reason > 30 then reason = string.sub(reason, 1, 27) .. "..." end
            row.reason:SetText("Blocked: " .. reason)
            local msg = tostring(e.message or "")
            if #msg > 68 then msg = string.sub(msg, 1, 65) .. "..." end
            row.msg:SetText(msg)
        else
            row:Hide()
        end
    end
end

function CS:GetFilteredLog()
    local q = self.frame and self.frame.pages.Log.search:GetText() or ""
    q = lower(Trim(q))
    local out = {}
    for _,e in ipairs(ChatSentryDB.log) do
        if not IsHiddenAddonProtocol(e.message) then
            local hay = lower((e.sender or "") .. " " .. (e.message or "") .. " " .. (e.reason or "") .. " " .. (e.channel or ""))
            if q == "" or find(hay, q, 1, true) then tinsert(out,e) end
        end
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
            local channel = tostring(e.channel or "")
            local sender = tostring(e.sender or "System")
            local reasonType = tostring(e.reasonType or "")
            local reason = tostring(e.reason or "")
            if #channel > 16 then channel = string.sub(channel, 1, 13) .. "..." end
            if #sender > 24 then sender = string.sub(sender, 1, 21) .. "..." end
            if #reason > 28 then reason = string.sub(reason, 1, 25) .. "..." end
            row.top:SetText(format("|cffef9f28%s|r  |cff9ca8b8%s|r  |cffffffff%s|r  -  %s: |cffef9f28%s|r", date("%H:%M", e.time), channel, sender, reasonType, reason))
            local msg = tostring(e.message or "")
            if #msg > 86 then msg = string.sub(msg, 1, 83) .. "..." end
            row.msg:SetText(msg)
        else row:Hide() end
    end
end

function CS:RefreshAll()
    if not ChatSentryDB or not self.frame then return end
    self.frame.enabledCheck:SetChecked(ChatSentryDB.enabled)
    if self.frame.footerStatus then
        if ChatSentryDB.enabled then
            self.frame.footerStatus:SetText("|cff4bd66f●|r  Active")
            self.frame.footerStatus:SetTextColor(0.88, 0.94, 1.00, 1)
        else
            self.frame.footerStatus:SetText("|cffff5b5b●|r  Disabled")
            self.frame.footerStatus:SetTextColor(0.82, 0.87, 0.96, 1)
        end
    end
    if self.frame.statusText then
        if ChatSentryDB.enabled then
            self.frame.statusText:SetText("Filtering Enabled")
            self.frame.statusText:SetTextColor(0.97, 0.78, 0.30, 1)
            if self.frame.statusPill then
                self.frame.statusPill:SetBackdropColor(0.02, 0.07, 0.12, 0.95)
                self.frame.statusPill:SetBackdropBorderColor(0.76, 0.57, 0.22, 0.95)
            end
        else
            self.frame.statusText:SetText("Filtering Disabled")
            self.frame.statusText:SetTextColor(0.82, 0.87, 0.96, 1)
            if self.frame.statusPill then
                self.frame.statusPill:SetBackdropColor(0.04, 0.05, 0.07, 0.95)
                self.frame.statusPill:SetBackdropBorderColor(0.36, 0.42, 0.52, 0.90)
            end
        end
    end
    local d = self.frame.pages.Dashboard
    d.cards.session.value:SetText(self.sessionBlocked or 0)
    d.cards.lifetime.value:SetText(ChatSentryDB.stats.lifetime or 0)
    d.cards.words.value:SetText(#ChatSentryDB.words)
    d.cards.users.value:SetText(#ChatSentryDB.users)
    if d.marketChecks then
        d.marketChecks.dp:SetChecked(MarketFilterEnabled("dp"))
        d.marketChecks.bt:SetChecked(MarketFilterEnabled("bt"))
        if d.marketChecks.dp.text then d.marketChecks.dp.text:SetTextColor(d.marketChecks.dp:GetChecked() and 0.97 or 0.84, d.marketChecks.dp:GetChecked() and 0.77 or 0.90, d.marketChecks.dp:GetChecked() and 0.29 or 0.98, 1) end
        if d.marketChecks.bt.text then d.marketChecks.bt.text:SetTextColor(d.marketChecks.bt:GetChecked() and 0.97 or 0.84, d.marketChecks.bt:GetChecked() and 0.77 or 0.90, d.marketChecks.bt:GetChecked() and 0.29 or 0.98, 1) end
    end
    self:RefreshDashboardRecent()
    for _, key in ipairs({"Words","Users","Whitelist"}) do local p=self.frame.pages[key]; self:RefreshEntryPage(p,p.listName) end
    for event,cb in pairs(self.frame.pages.Channels.checks) do
        cb:SetChecked(ChatSentryDB.channels[event] ~= false)
        if cb.text then cb.text:SetTextColor(cb:GetChecked() and 0.97 or 0.84, cb:GetChecked() and 0.77 or 0.90, cb:GetChecked() and 0.29 or 0.98, 1) end
    end
    for key,cb in pairs(self.frame.pages.Smart.checks) do
        cb:SetChecked(ChatSentryDB.settings[key] and true or false)
        if cb.text then cb.text:SetTextColor(cb:GetChecked() and 0.97 or 0.84, cb:GetChecked() and 0.77 or 0.90, cb:GetChecked() and 0.29 or 0.98, 1) end
    end
    for key,cb in pairs(self.frame.pages.Settings.checks) do
        cb:SetChecked(ChatSentryDB.settings[key] and true or false)
        if cb.text then cb.text:SetTextColor(cb:GetChecked() and 0.97 or 0.84, cb:GetChecked() and 0.77 or 0.90, cb:GetChecked() and 0.29 or 0.98, 1) end
    end
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

local function SanitizeBlockedLog()
    if not ChatSentryDB or not ChatSentryDB.log then return end
    for i = #ChatSentryDB.log, 1, -1 do
        local entry = ChatSentryDB.log[i]
        if entry and IsHiddenAddonProtocol(entry.message) then
            tremove(ChatSentryDB.log, i)
        end
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
        ChatSentryDB=MergeDefaults(ChatSentryDB or {},DeepCopy(DEFAULTS)); SanitizeSavedLists(); SanitizeBlockedLog(); self.sessionBlocked=0
        CreateUI(); CreateMinimapButton()
        for _,ev in ipairs(EVENTS) do ChatFrame_AddMessageEventFilter(ev, CS.Filter) end
        self:InstallMessageHandlerBridge()
        Print("Loaded. Type |cffffffff/cs|r to open.")
        self:UnregisterEvent("ADDON_LOADED")
    elseif event=="PLAYER_ENTERING_WORLD" and ChatSentryDB then
        self:InstallMessageHandlerBridge()
    end
end)
