-- WoW 1.12 / Lua 5.0 conventions. This addon never changes gameplay or HUD settings.
local VERSION = "0.1.8"
local MAX_RUNS, MAX_EVENTS = 8, 24000
local frame = CreateFrame("Frame")
local current, previousPhase, spellState, lastSample, pendingZone, awaitingRun
local elapsed = 0

local function Escape(text)
    text = string.gsub(text, "\\", "\\\\")
    text = string.gsub(text, '"', '\\"')
    text = string.gsub(text, "[%z\1-\31]", function(c)
        return string.format("\\u%04x", string.byte(c))
    end)
    return '"' .. text .. '"'
end

local function Json(value, depth)
    depth = depth or 0
    if depth > 12 then return "null" end
    local kind = type(value)
    if kind == "string" then return Escape(value) end
    if kind == "boolean" then return value and "true" or "false" end
    if kind == "number" then
        -- Lua 5.0 has no math.huge. Finite numbers subtract from themselves to zero.
        if value - value ~= 0 then return "null" end
        return tostring(value)
    end
    if kind ~= "table" then return "null" end
    local result, count, isArray = {}, 0, true
    for k in pairs(value) do
        count = count + 1
        if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then isArray = false end
    end
    if count == 0 then return "{}" end
    if isArray and count == table.getn(value) then
        for i = 1, count do result[i] = Json(value[i], depth + 1) end
        return "[" .. table.concat(result, ",") .. "]"
    end
    for k, v in pairs(value) do
        table.insert(result, Escape(tostring(k)) .. ":" .. Json(v, depth + 1))
    end
    return "{" .. table.concat(result, ",") .. "}"
end

local function Init()
    if type(AZSRecorderDB) ~= "table" or AZSRecorderDB.schemaVersion ~= 1 then
        AZSRecorderDB = { schemaVersion = 1, counter = 0, runs = {} }
    end
end

local function Clock()
    if type(AZS_GetRunTime) == "function" then return AZS_GetRunTime() end
end

local function Emit(kind, data)
    if not current then return end
    local n = table.getn(current.events)
    if n >= MAX_EVENTS and kind ~= "summary" and kind ~= "capture_end" then
        current.truncated = true
        return
    end
    current.sequence = current.sequence + 1
    table.insert(current.events, Json({
        schemaVersion = 1, runId = current.id, seq = current.sequence,
        kind = kind, wallTime = time() * 1000,
        sessionTime = GetTime(), runTime = Clock(), data = data or {},
    }))
    if kind == "spell_tooltip" then
        current.tooltipCount = (current.tooltipCount or 0) + 1
        if data.status == "matched" then current.tooltipMatched = (current.tooltipMatched or 0) + 1 end
    end
    if kind == "jewelry" then current.jewelryCount = (current.jewelryCount or 0) + 1 end
    return current.sequence
end

-- Count observations are evidence of other players, not proof of lifetime solo mode.
local partyState, lastPartySample
local function PartyCount(fn)
    if type(fn) ~= "function" then return nil end
    local ok, n = pcall(fn)
    if ok and type(n) == "number" and n >= 0 and n <= 40 and math.floor(n) == n then return n end
end
local function ObserveParty(reason, freshMeter)
    if not current then return end
    local data = { source = "client-party-apis", partyMembers = PartyCount(GetNumPartyMembers),
        raidMembers = PartyCount(GetNumRaidMembers) }
    -- AZS_PARTY can retain the previous run. Only capture it on a fresh transport update.
    if freshMeter then data.meter = AZS_PARTY or {}; data.source = "AZSPARTY" end
    local encoded = Json(data)
    if reason == "baseline" or freshMeter or encoded ~= partyState then
        partyState = encoded
        data.reason = reason
        Emit("party_observation", data)
    end
end
local function ObserveClientVersion()
    local data = { source = "GetBuildInfo", namespace = "base-wow", status = "unsupported" }
    if type(GetBuildInfo) == "function" then
        local ok, version, build, date, interface = pcall(GetBuildInfo)
        data.status = ok and "observed" or "error"
        if ok then
            -- The inspected client returns stock WoW constants here, not its AZS build.
            if type(version) == "string" then data.version = version end
            if type(build) == "string" or type(build) == "number" then data.build = build end
            if type(date) == "string" then data.date = date end
            if type(interface) == "number" then data.interface = interface end
        end
    end
    Emit("client_version", data)
end

local function ObserveSpells(baseline)
    local nextState = {}
    local changed = false
    for _, s in ipairs(AZS_SPELLS or {}) do
        if s.key then
            local old = spellState[s.key]
            nextState[s.key] = { spell = s.spell, rank = s.rank }
            if baseline or not old or old.spell ~= s.spell or old.rank ~= s.rank then
                changed = true
                Emit(baseline and "spell_baseline" or (old and "spell_changed" or "spell_acquired"), {
                    key = s.key, spell = s.spell, rank = s.rank,
                    previousRank = old and old.rank, previousSpell = old and old.spell,
                    cdmax = s.cdmax,
                })
            end
        end
    end
    if not baseline then
        for key, old in pairs(spellState) do
            if not nextState[key] then
                changed = true
                AZSRecorderTooltips.Forget(key)
                Emit("spell_removed", { key = key, spell = old.spell, rank = old.rank })
            end
        end
    end
    spellState = nextState
    if changed then AZSRecorderTooltips.Request(baseline and "baseline" or "spell_state", current.sequence) end
end

-- Stock talent-API tuples expose learned player passives, not native AZS allocations.
local playerSpellState, lastPlayerSpellSample
local function ReadPlayerSpells()
    if type(GetNumTalentTabs) ~= "function" or type(GetNumTalents) ~= "function"
        or type(GetTalentInfo) ~= "function" then
        return { status = "unavailable" }
    end
    local count = GetNumTalentTabs()
    if type(count) ~= "number" or count < 1 or count > 20 or math.floor(count) ~= count then
        return { status = "unavailable" }
    end
    local tabs = {}
    for tab = 1, count do
        local n = GetNumTalents(tab)
        if type(n) ~= "number" or n < 1 or n > 200 or math.floor(n) ~= n then
            return { status = "unavailable" }
        end
        local talents = {}
        for index = 1, n do
            local name, icon, tier, column, rank, maxRank = GetTalentInfo(tab, index)
            if type(name) ~= "string" or name == "" or type(rank) ~= "number"
                or type(maxRank) ~= "number" or rank < 0 or maxRank < 1 or rank > maxRank then
                return { status = "unavailable" }
            end
            table.insert(talents, { index = index, name = name, icon = icon,
                tier = tier, column = column, rank = rank, maxRank = maxRank })
        end
        table.insert(tabs, { index = tab, talents = talents })
    end
    return { status = "complete", tabCount = count, tabs = tabs }
end

local function ObservePlayerSpells(baseline)
    local now = GetTime()
    if not baseline and lastPlayerSpellSample and now - lastPlayerSpellSample < 1 then return end
    lastPlayerSpellSample = now
    local ok, data = pcall(ReadPlayerSpells)
    if not ok then data = { status = "error" } end
    local encoded = Json(data)
    if baseline or encoded ~= playerSpellState then
        playerSpellState = encoded
        data.reason = baseline and "baseline" or "observed_change"
        Emit("player_spell_snapshot", data)
    end
end

local noticeCount = 0
local function Notice(source, text)
    if not current or type(text) ~= "string" then return end
    if noticeCount >= 500 then
        if noticeCount == 500 then Emit("item_notice_limit", { limit = 500 }); noticeCount = 501 end
        return
    end
    noticeCount = noticeCount + 1
    local clipped = string.len(text) > 4000
    -- Omit an oversized message rather than split UTF-8 bytes.
    Emit("item_notice", { source = source, text = clipped and "" or text, truncated = clipped })
end

local function StartRun()
    Init()
    -- A persisted recording is intentionally not silently spliced across reloads.
    -- A new segment is marked partial, so the importer never invents continuity.
    AZSRecorderDB.counter = AZSRecorderDB.counter + 1
    local hero = (AZS_ZONE and AZS_ZONE.hero) or (UnitName and UnitName("player")) or "unknown"
    local id = hero .. "-" .. tostring(time()) .. "-" .. tostring(AZSRecorderDB.counter)
        .. "-" .. tostring(math.floor(GetTime() * 1000))
    current = {
        id = id, events = {}, sequence = 0, recorderVersion = VERSION,
        partial = not pendingZone or (Clock() or 99) > 2,
        startedAt = time() * 1000,
    }
    table.insert(AZSRecorderDB.runs, current)
    while table.getn(AZSRecorderDB.runs) > MAX_RUNS do table.remove(AZSRecorderDB.runs, 1) end
    spellState, lastSample = {}, nil
    AZSRecorderTooltips.Reset()
    AZSRecorderJewelry.Reset()
    AZSRecorderEquipment.Reset()
    noticeCount = 0
    Emit("run_start", { zone = AZS_ZONE or {}, partial = current.partial, recorderVersion = VERSION })
    ObserveClientVersion()
    partyState, lastPartySample = nil, GetTime()
    ObserveParty("baseline", false)
    ObserveSpells(true)
    playerSpellState, lastPlayerSpellSample = nil, nil
    ObservePlayerSpells(true)
    Emit("stats", AZS_STATS or {})
    Emit("pets", { summons = AZS_PETS or {} })
    AZSRecorderJewelry.Request("baseline", current.sequence); AZSRecorderEquipment.Request("baseline", current.sequence)
    pendingZone = false
end

local function Poll()
    if type(AZS_GetPhase) ~= "function" then return end
    if awaitingRun then return end
    local phase = AZS_GetPhase()
    local active = phase == "playing" or phase == "choosing" or phase == "paused"
    if active and not current and Clock() ~= nil then StartRun() end
    if not current then previousPhase = phase; return end
    if phase ~= previousPhase then
        Emit("phase", { phase = phase or "unknown", previous = previousPhase })
        previousPhase = phase
        AZSRecorderTooltips.Request("phase", current.sequence)
        AZSRecorderJewelry.Request("phase", current.sequence); AZSRecorderEquipment.Request("phase", current.sequence)
    end
    local clock = Clock()
    if clock and clock ~= lastSample and (not lastSample or math.abs(clock - lastSample) >= 1) then
        Emit("sample", AZS_RUN or {})
        lastSample = clock
    end
    if phase == "ready" or phase == nil then
        Emit("capture_end", { reason = "left_world_or_ready" })
        current = nil
    end
end

frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_LEAVING_WORLD")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("CHAT_MSG_LOOT")
frame:RegisterEvent("CHAT_MSG_SYSTEM")
frame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
frame:RegisterEvent("UNIT_INVENTORY_CHANGED")
frame:RegisterEvent("BAG_UPDATE")
frame:RegisterEvent("BAG_UPDATE_COOLDOWN")
frame:RegisterEvent("PARTY_MEMBERS_CHANGED")
frame:RegisterEvent("RAID_ROSTER_UPDATE")
frame:SetScript("OnEvent", function()
    Init()
    if event == "CHAT_MSG_ADDON" then
        local prefix = arg1
        if prefix == "AZSZONE" then
            if current then Emit("capture_end", { reason = "new_zone" }) end
            current, previousPhase, pendingZone, awaitingRun = nil, nil, true, true
            return
        end
        if prefix == "AZSRUN" then awaitingRun = false end
        Poll()
        if not current then return end
        if prefix == "AZSPARTY" then ObserveParty("transport", true) end
        if prefix == "AZSSPELLS" then ObserveSpells(false)
        elseif prefix == "AZSPETS" then Emit("pets", { summons = AZS_PETS or {} })
        elseif prefix == "AZS" then Emit("stats", AZS_STATS or {})
        elseif prefix == "AZSEND" and AZS_END and AZS_END.result then
            Emit("summary", AZS_END)
        elseif prefix == "AZSBANNER" and AZS_BANNER then Emit("banner", AZS_BANNER)
        elseif prefix == "AZSBOSSES" then Emit("bosses", AZS_SCHEDULE or {})
        end
        if prefix == "AZS" or prefix == "AZSBUFFS" then AZSRecorderTooltips.Request("bonuses", current.sequence) end
        if prefix == "AZS" or prefix == "AZSBUFFS" then AZSRecorderJewelry.Request("bonuses", current.sequence); AZSRecorderEquipment.Request("bonuses", current.sequence) end
        AZSRecorderTooltips.Update(Emit)
        AZSRecorderJewelry.Update(Emit); AZSRecorderEquipment.Update(Emit)
    elseif event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
        ObserveParty(event, false)
    elseif event == "ACTIONBAR_SLOT_CHANGED" then
        if current then AZSRecorderTooltips.Request("actionbar", current.sequence) end
    elseif event == "CHAT_MSG_LOOT" then
        if current then Emit("loot_message", { text = arg1 or "", source = event }) end
        Notice(event, arg1)
    elseif event == "CHAT_MSG_SYSTEM" then
        Notice(event, arg1)
    elseif event == "UNIT_INVENTORY_CHANGED" then
        if current and arg1 == "player" then
            AZSRecorderJewelry.Request("inventory", current.sequence); AZSRecorderEquipment.Request("inventory", current.sequence)
            AZSRecorderJewelry.Update(Emit); AZSRecorderEquipment.Update(Emit)
        end
    elseif event == "BAG_UPDATE" or event == "BAG_UPDATE_COOLDOWN" then
        if current then AZSRecorderJewelry.Request("bags", current.sequence); AZSRecorderEquipment.Request("bags", current.sequence) end
    elseif event == "PLAYER_LEAVING_WORLD" or event == "PLAYER_LOGOUT" then
        if current then Emit("capture_end", { reason = event }) end
        current, previousPhase = nil, nil
    elseif event == "PLAYER_ENTERING_WORLD" then
        Poll()
    end
end)
frame:SetScript("OnUpdate", function()
    elapsed = elapsed + (arg1 or 0)
    if elapsed < 0.2 then return end
    elapsed = 0
    Poll()
    if current and (not lastPartySample or GetTime() - lastPartySample >= 1) then
        lastPartySample = GetTime()
        ObserveParty("poll", false)
    end
    if current then ObservePlayerSpells(false) end
    if current then AZSRecorderTooltips.Update(Emit) end
    if current then AZSRecorderJewelry.Update(Emit); AZSRecorderEquipment.Update(Emit) end
end)

SLASH_AZSRECORDER1 = "/azsrec"
SlashCmdList["AZSRECORDER"] = function()
    Init()
    local recorded, tooltips, matched, jewelry = 0, 0, 0, 0
    for _, run in ipairs(AZSRecorderDB.runs) do
        recorded = recorded + table.getn(run.events or {})
        tooltips = tooltips + (run.tooltipCount or 0)
        matched = matched + (run.tooltipMatched or 0)
        jewelry = jewelry + (run.jewelryCount or 0)
    end
    DEFAULT_CHAT_FRAME:AddMessage("AZS Recorder " .. VERSION .. ": " .. table.getn(AZSRecorderDB.runs)
        .. " retained run segments, " .. recorded .. " recorded events, " .. tooltips .. " tooltip snapshots ("
        .. matched .. " matched), " .. jewelry .. " jewelry observations. Reload UI or exit normally to save before uploading."
        .. (current and current.truncated and " Capture limit reached; this segment is incomplete." or ""))
end
