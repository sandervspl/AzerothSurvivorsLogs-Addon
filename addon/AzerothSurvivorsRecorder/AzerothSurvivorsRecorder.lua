-- WoW 1.12 / Lua 5.0 conventions. This addon never changes gameplay or HUD settings.
local VERSION = "0.1.13"
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

-- Whole-run meter packets are cumulative counters, never individual hits.
-- Keep only the latest bounded packet per stream between one-second writes.
-- Latest JSON checkpoints survive the ordinary event/history limits and are
-- optional run fields, so older importers can still read the original events.
local meter = {}
do
    local streams, lastWrite
    local MAX_PAYLOAD, MAX_HISTORY_BYTES, MAX_HISTORY = 16384, 524288, 4096
    function meter.Reset()
        streams, lastWrite = {}, nil
    end
    function meter.Receive(prefix, payload)
        local channel = prefix == "AZSMETER" and "damage" or "healing"
        local s = streams[channel]
        if not s then s = { receipt = 0, clears = 0, oversized = 0 }; streams[channel] = s end
        if payload == "" and s.nonempty then s.clears = s.clears + 1 end
        if type(payload) == "string" then s.nonempty = payload ~= "" end
        s.receipt = s.receipt + 1
        s.status = type(payload) == "string" and string.len(payload) <= MAX_PAYLOAD
            and "observed" or "oversized"
        if s.status == "oversized" then s.oversized = s.oversized + 1 end
        s.payload = s.status == "observed" and payload or nil
        s.sessionTime, s.wallTime = GetTime(), time() * 1000
        s.runTime = nil
        if not awaitingRun then s.runTime = Clock() end
        s.dirty = true
    end
    function meter.Update(force)
        if not current then return end
        local now = GetTime()
        if not force and lastWrite and now - lastWrite < 1 then return end
        lastWrite = now
        for _, channel in ipairs({ "damage", "healing" }) do
            local s = streams[channel]
            if s and (s.dirty or (force and s.receipt ~= s.savedReceipt)) then
                s.dirty = false
                -- Ignore rate/share-only changes. This runs at most once/second,
                -- not once per hit or transport packet. Raw tokens stay intact.
                local signature = s.payload and string.gsub(s.payload,
                    "([^,;]*),([^,;]*),[^,;]*,[^,;]*,([^,;]*)", "%1,%2,%3") or s.status
                local changed = signature ~= s.signature or s.clears ~= s.savedClears
                    or s.oversized ~= s.savedOversized
                if changed or force then
                    local data = { version = 1, channel = channel, status = s.status,
                        payload = s.payload, receipt = s.receipt, clears = s.clears,
                        oversizedReceipts = s.oversized,
                        receivedSessionTime = s.sessionTime, receivedWallTime = s.wallTime,
                        receivedRunTime = s.runTime }
                    current.sequence = current.sequence + 1
                    local record = { schemaVersion = 1, runId = current.id,
                        seq = current.sequence, kind = "meter_snapshot", wallTime = time() * 1000,
                        sessionTime = now, runTime = Clock(), data = data }
                    local encoded = Json(record)
                    -- Even pathological control characters cannot produce an
                    -- unimportable checkpoint beyond the 64 KiB reader limit.
                    if string.len(encoded) > 60000 then
                        data.status, data.payload = "oversized", nil
                        encoded = Json(record)
                    end
                    current[channel == "damage" and "meterDamage" or "meterHealing"] = encoded
                    if changed then
                        local bytes, count = current.meterBytes or 0, current.meterCount or 0
                        if count < MAX_HISTORY and bytes + string.len(encoded) <= MAX_HISTORY_BYTES
                            and table.getn(current.events) < MAX_EVENTS then
                            table.insert(current.events, encoded)
                            current.meterBytes, current.meterCount = bytes + string.len(encoded), count + 1
                        else
                            current.meterHistoryLimited = true
                        end
                    end
                    s.signature, s.savedClears = signature, s.clears
                    s.savedOversized, s.savedReceipt = s.oversized, s.receipt
                end
            end
        end
    end
    meter.Reset()
end

-- Read the native outgoing feed independently of the HUD: no anchors, frame
-- callbacks, combat subscriptions or per-frame polling. Names/keys are opaque.
local combatText = {}
do
    local state
    local MAX_BYTES, MAX_RETAINED_BYTES, MAX_READS, MAX_BATCH_BYTES = 8388608, 33554432, 4, 40000
    local kinds = { player = true, pet = true, summon = true, totem = true, ownedUnknown = true }
    local fields = { "eventId", "presentedAt", "kind", "amount", "sourceKind", "sourceId",
        "targetId", "targetName", "abilityName", "spellId", "critical", "periodic", "reflected",
        "damageType", "schoolMask", "meterSource", "meterSourceKey" }
    local strings = { "sourceId", "targetId", "targetName", "abilityName", "meterSource", "meterSourceKey" }
    local function Number(n) return type(n) == "number" and n - n == 0 and n >= 0 and n <= 9007199254740991 end
    local function Id(s) return type(s) == "string" and string.len(s) > 0 and string.len(s) <= 512 end
    local function Observe(value)
        local result = { resultType = type(value) }
        if type(value) ~= "table" then return result end
        for _, key in ipairs({ "apiVersion", "maxEventsPerRead", "streamId", "worldId", "clockSeconds",
            "cursor", "events", "hasMore", "droppedCount", "eventId", "presentedAt", "kind", "amount",
            "sourceKind", "critical", "periodic", "reflected", "spellId", "damageType", "schoolMask" }) do
            local v = value[key]
            result[key .. "Type"] = type(v)
            if type(v) == "boolean" or (type(v) == "number" and v - v == 0) then result[key] = v
            elseif type(v) == "string" then
                if string.len(v) <= 128 then result[key] = v else result[key .. "Bytes"] = string.len(v) end
            end
        end
        if type(value.events) == "table" then result.eventCount = table.getn(value.events) end
        return result
    end
    local function Diagnose(status, stage, reason, value, code, message)
        if not current or not state then return end
        local d = current.combatTextDiagnostic
        if not d then
            d = { version = 1, startedSessionTime = state.began }
            current.combatTextDiagnostic = d
        end
        d.status, d.stage, d.reason = status, stage, reason
        d.attempts, d.updatedSessionTime = state.attempts, GetTime()
        d.functions = { capabilities = type(AZS_GetCombatTextCapabilities), events = type(AZS_GetCombatTextEvents),
            nativeEvents = type(AZS_NativeCombatTextEvents), globalTable = type(_G),
            globalCapabilities = type(type(_G) == "table" and _G.AZS_GetCombatTextCapabilities or nil),
            globalEvents = type(type(_G) == "table" and _G.AZS_GetCombatTextEvents or nil) }
        d.observed = Observe(value)
        d.errorCode = type(code) == "string" and string.len(code) <= 128 and code or nil
        d.errorMessage, d.errorBytes = nil, nil
        if type(message) == "string" then
            d.errorBytes = string.len(message)
            -- Keep UTF-8 intact. Oversized messages are omitted, not sliced.
            d.errorMessage = string.len(message) <= 512 and message or "Native API error exceeded 512 bytes."
        end
    end
    local function Stop(reason, detail, value)
        if current and current.combatText then current.combatText.reason = reason end
        Diagnose("failed", state and state.cursor and "events" or "baseline", detail or reason, value)
        if current and current.combatTextDiagnostic then current.combatTextDiagnostic.stoppedBecause = "permanent-error" end
        if state then state.stopped = true end
    end
    local function Call(callback, cursor, limit)
        local ok, result, failure
        if cursor == nil and limit == nil then ok, result, failure = pcall(callback)
        else ok, result, failure = pcall(callback, cursor, limit) end
        if not ok then return nil, "lua_error", nil, result end
        if failure ~= nil then
            return nil, "api_error", type(failure) == "table" and failure.code or nil,
                type(failure) == "table" and failure.message or (type(failure) == "string" and failure
                    or "Unexpected API error return type: " .. type(failure))
        end
        if type(result) ~= "table" then return nil, "invalid_result", nil, "Expected a table response" end
        return result
    end
    local function StartupFailure(stage, reason, value, code, message)
        local retry = reason == "missing_api" or code == "NOT_READY" or code == "NOT_IN_WORLD"
        Diagnose(retry and "waiting" or "failed", stage, reason, value, code, message)
        if retry then
            state.retryAt = GetTime() + math.min(4, 0.5 * 2 ^ (state.attempts - 1))
        else
            state.stopped = true
            current.combatTextDiagnostic.stoppedBecause = "permanent-error"
        end
    end
    local function Event(value, clock)
        if type(value) ~= "table" or not Id(value.eventId) or not Number(value.presentedAt)
            or value.presentedAt > clock or not kinds[value.sourceKind]
            or type(value.critical) ~= "boolean" or type(value.periodic) ~= "boolean"
            or type(value.reflected) ~= "boolean" then return end
        if value.kind == "damage" then
            if not Number(value.amount) or value.result ~= nil then return end
        elseif value.kind ~= "miss" or type(value.result) ~= "table"
            or not Id(value.result.key) or (value.result.text ~= nil and not Id(value.result.text))
            or value.amount ~= nil then return end
        for _, key in ipairs(strings) do if value[key] ~= nil and not Id(value[key]) then return end end
        if value.spellId ~= nil and (not Number(value.spellId) or value.spellId < 1
            or value.spellId > 4294967295 or math.floor(value.spellId) ~= value.spellId) then return end
        if value.schoolMask ~= nil and (not Number(value.schoolMask) or value.schoolMask < 1
            or value.schoolMask > 127 or math.floor(value.schoolMask) ~= value.schoolMask) then return end
        if value.damageType ~= nil and value.damageType ~= "melee" and value.damageType ~= "ranged"
            and value.damageType ~= "spell" then return end
        local copy = {}
        for _, key in ipairs(fields) do copy[key] = value[key] end
        if value.result then copy.result = { key = value.result.key, text = value.result.text } end
        return copy
    end
    function combatText.Start()
        state = { began = GetTime(), attempts = 0, seen = {}, order = {}, slot = 0 }
        Diagnose("waiting", "availability", "starting")
        combatText.Update(false)
    end
    function combatText.Update(force)
        if not current or not state or state.stopped then return end
        local now = GetTime()
        if not state.cursor and (now - state.began >= 30 or state.attempts >= 12) then
            local d = current.combatTextDiagnostic
            d.status, d.stoppedBecause, d.updatedSessionTime = "failed", "deadline", now
            state.stopped = true
            return
        end
        if state.retryAt and now < state.retryAt then return end
        if not state.cursor then
            state.attempts = state.attempts + 1
            if type(AZS_GetCombatTextCapabilities) ~= "function" or type(AZS_GetCombatTextEvents) ~= "function" then
                StartupFailure("availability", "missing_api"); return
            end
            if not state.limit then
                local caps, reason, code, message = Call(AZS_GetCombatTextCapabilities)
                if not caps then StartupFailure("capabilities", reason, caps, code, message); return end
                if caps.apiVersion ~= 1 or not Number(caps.maxEventsPerRead) or caps.maxEventsPerRead < 1
                    or math.floor(caps.maxEventsPerRead) ~= caps.maxEventsPerRead then
                    StartupFailure("capabilities", "invalid_capabilities", caps); return
                end
                state.limit = math.min(256, caps.maxEventsPerRead)
            end
        end
        for read = 1, MAX_READS do
            local result, reason, code, message = Call(AZS_GetCombatTextEvents, state.cursor, state.limit)
            if not result then
                if not state.cursor then StartupFailure("baseline", reason, result, code, message)
                else
                    Stop("feed_error")
                    Diagnose("failed", "events", reason, result, code, message)
                    current.combatTextDiagnostic.stoppedBecause = "permanent-error"
                end
                return
            end
            state.retryAt = nil
            if result.apiVersion ~= 1 or not Id(result.streamId) or not Id(result.worldId)
                or not Number(result.clockSeconds) or not Id(result.cursor)
                or type(result.hasMore) ~= "boolean" or not Number(result.droppedCount)
                or math.floor(result.droppedCount) ~= result.droppedCount or type(result.events) ~= "table"
                or (state.clock and result.clockSeconds < state.clock) then Stop("invalid_feed", "invalid_header", result); return end
            if state.stream and (state.stream ~= result.streamId or state.world ~= result.worldId) then
                Stop("world_changed"); return
            end
            local count = table.getn(result.events)
            local keys = 0
            for key in pairs(result.events) do
                if type(key) ~= "number" or key < 1 or math.floor(key) ~= key or key > count then Stop("invalid_feed", "invalid_array", result); return end
                keys = keys + 1
            end
            if keys ~= count or count > state.limit
                or (not state.cursor and (count > 0 or result.hasMore or result.droppedCount > 0))
                or (state.cursor == result.cursor and (count > 0 or result.hasMore or result.droppedCount > 0)) then
                Stop("invalid_feed", "invalid_cursor_or_array", result); return
            end
            local page, previous = {}, state.presentedAt
            for index = 1, count do
                local value = Event(result.events[index], result.clockSeconds)
                if not value or (previous and value.presentedAt < previous) then Stop("invalid_feed", "invalid_event", result.events[index]); return end
                previous = value.presentedAt
                page[index] = value
            end
            if not current.combatText then
                Diagnose("selected", "baseline", nil, result)
                current.combatText = { version = 1, selected = true, startedSessionTime = now,
                    lateStart = now - state.began > 0.5 or (Clock() or 0) > 0.5,
                    streamId = result.streamId, worldId = result.worldId,
                    bytes = 0, batches = 0, events = 0, dropped = 0, duplicates = 0,
                    missingAttribution = 0, ended = false }
            end
            local status = current.combatText
            status.dropped = status.dropped + result.droppedCount
            local batch, size = {}, 0
            local function Flush()
                if table.getn(batch) == 0 then return true end
                local data = { version = 1, streamId = result.streamId, worldId = result.worldId,
                    clockSeconds = result.clockSeconds, events = batch }
                -- Reserve envelope bytes before encoding; the shared event limit
                -- still protects metadata and marks the whole segment truncated.
                if status.bytes + size + 8192 > MAX_BYTES or table.getn(current.events) >= MAX_EVENTS then
                    Stop("storage_limit"); return false
                end
                local retained = 0
                for _, run in ipairs(AZSRecorderDB.runs) do
                    retained = retained + (run.combatText and run.combatText.bytes or 0)
                end
                while retained + size + 8192 > MAX_RETAINED_BYTES and table.getn(AZSRecorderDB.runs) > 1 do
                    local old = table.remove(AZSRecorderDB.runs, 1)
                    retained = retained - (old.combatText and old.combatText.bytes or 0)
                end
                if not Emit("combat_text", data) then Stop("storage_limit"); return false end
                status.bytes = status.bytes + string.len(current.events[table.getn(current.events)])
                status.batches, status.events = status.batches + 1, status.events + table.getn(batch)
                batch, size = {}, 0
                return true
            end
            for _, value in ipairs(page) do
                if state.seen[value.eventId] then status.duplicates = status.duplicates + 1
                elseif value.presentedAt < status.startedSessionTime then
                    Stop("invalid_feed"); return
                else
                    local bytes = string.len(Json(value))
                    if size + bytes > MAX_BATCH_BYTES and not Flush() then return end
                    table.insert(batch, value); size = size + bytes + 1
                    if not value.meterSource or not value.meterSourceKey then
                        status.missingAttribution = status.missingAttribution + 1
                    end
                    state.slot = math.mod(state.slot, 4096) + 1
                    local old = state.order[state.slot]
                    if old then state.seen[old] = nil end
                    state.order[state.slot], state.seen[value.eventId] = value.eventId, true
                end
            end
            if not Flush() then return end
            state.cursor, state.stream, state.world = result.cursor, result.streamId, result.worldId
            state.clock, state.presentedAt = result.clockSeconds, previous
            state.hasMore = result.hasMore
            if not result.hasMore then return end
        end
    end
    function combatText.End()
        combatText.Update(true)
        if current and current.combatText then
            if state.hasMore and not state.stopped then Stop("backlog_at_end") end
            current.combatText.ended = true
        elseif current and current.combatTextDiagnostic and current.combatTextDiagnostic.status == "waiting" then
            current.combatTextDiagnostic.status = "failed"
            current.combatTextDiagnostic.stoppedBecause = "capture-end"
            current.combatTextDiagnostic.updatedSessionTime = GetTime()
        end
        state = nil
    end
    function combatText.Report()
        local run = current or AZSRecorderDB.runs[table.getn(AZSRecorderDB.runs)]
        local d = run and run.combatTextDiagnostic
        if not d then
            DEFAULT_CHAT_FRAME:AddMessage("Native capture: no startup diagnostic saved. Start a run with recorder " .. VERSION .. ".")
            return
        end
        DEFAULT_CHAT_FRAME:AddMessage("Native capture: " .. d.status .. ", stage " .. d.stage .. ", attempts " .. d.attempts
            .. (d.reason and ", " .. d.reason or "") .. (d.errorCode and " (" .. d.errorCode .. ")" or ""))
        if d.errorMessage then DEFAULT_CHAT_FRAME:AddMessage(d.errorMessage) end
        DEFAULT_CHAT_FRAME:AddMessage("Native APIs: capabilities=" .. d.functions.capabilities .. ", events=" .. d.functions.events
            .. ", native events=" .. d.functions.nativeEvents)
    end
end

-- Opt-in, two-minute callback diagnostic. No combat subscriptions by default.
local probe = {}
do
    local active
    local categories = { "CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE",
        "CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_DAMAGE", "CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_DAMAGE",
        "CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS", "CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_BUFFS",
        "CHAT_MSG_SPELL_SELF_BUFF", "CHAT_MSG_SPELL_SELF_DAMAGE", "CHAT_MSG_SPELL_PET_DAMAGE" }
    function probe.Stop(reason)
        if not active then return end
        active.reason, active.ended = reason, GetTime()
        if current then current.meterProbe = Json(active) end
        for _, category in ipairs(categories) do frame:UnregisterEvent(category) end
        active = nil
    end
    function probe.Start()
        if not current then
            DEFAULT_CHAT_FRAME:AddMessage("AZS Recorder: start a run before enabling the combat probe.")
            return
        end
        probe.Stop("restarted")
        active = { version = 1, started = GetTime(), categories = {} }
        for _, category in ipairs(categories) do
            active.categories[category] = { count = 0, samples = {}, omitted = 0 }
            frame:RegisterEvent(category)
        end
        DEFAULT_CHAT_FRAME:AddMessage("AZS Recorder: combat probe enabled for two minutes. Reload UI or exit normally afterwards to save its bounded samples.")
    end
    function probe.Receive(category, message)
        if not active then return false end
        if GetTime() - active.started >= 120 then probe.Stop("timeout"); return false end
        local counter = active.categories[category]
        if not counter then return false end
        counter.count = counter.count + 1
        if table.getn(counter.samples) < 2 then
            if type(message) == "string" and string.len(message) <= 256 then
                table.insert(counter.samples, message)
            else
                counter.omitted = counter.omitted + 1
            end
        end
        return true
    end
    function probe.Update()
        if active and GetTime() - active.started >= 120 then probe.Stop("timeout") end
    end
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
            if old and old.spell == s.spell and old.rank == s.rank then
                nextState[s.key] = old
            else
                nextState[s.key] = { spell = s.spell, rank = s.rank }
            end
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
local playerSpellState, playerSpellSnapshot, lastPlayerSpellSample
local TALENT_FIELDS = { "index", "name", "icon", "tier", "column", "rank", "maxRank" }

local function SameTalentValue(a, b)
    local kind = type(a)
    if kind ~= type(b) then return false end
    if kind == "number" then
        -- NaN and unusual number representations fall back to the JSON comparison.
        return a == b and (a ~= 0 or tostring(a) == tostring(b))
    end
    if kind == "string" or kind == "boolean" or kind == "nil" then return a == b end
    -- Unexpected native tables can be mutated in place. Never trust their identity.
    return false
end

local function SamePlayerSpells(a, b)
    if not b or a.status ~= b.status or a.tabCount ~= b.tabCount then return false end
    if a.status ~= "complete" then return true end
    if table.getn(a.tabs) ~= table.getn(b.tabs) then return false end
    for tab, data in ipairs(a.tabs) do
        local old = b.tabs[tab]
        if data.index ~= old.index or table.getn(data.talents) ~= table.getn(old.talents) then return false end
        for index, talent in ipairs(data.talents) do
            if talent ~= old.talents[index] then
                for _, field in ipairs(TALENT_FIELDS) do
                    if not SameTalentValue(talent[field], old.talents[index][field]) then return false end
                end
            end
        end
    end
    return true
end

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
        local previous = playerSpellSnapshot and playerSpellSnapshot.status == "complete"
            and playerSpellSnapshot.tabs[tab]
        for index = 1, n do
            local name, icon, tier, column, rank, maxRank = GetTalentInfo(tab, index)
            if type(name) ~= "string" or name == "" or type(rank) ~= "number"
                or type(maxRank) ~= "number" or rank < 0 or maxRank < 1 or rank > maxRank then
                return { status = "unavailable" }
            end
            local old = previous and previous.talents[index]
            -- These scalar-only rows are private and immutable after observation.
            if old and old.index == index and old.name == name
                and SameTalentValue(old.icon, icon) and SameTalentValue(old.tier, tier)
                and SameTalentValue(old.column, column) and SameTalentValue(old.rank, rank)
                and SameTalentValue(old.maxRank, maxRank) then
                talents[index] = old
            else
                talents[index] = { index = index, name = name, icon = icon,
                    tier = tier, column = column, rank = rank, maxRank = maxRank }
            end
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
    if not baseline and SamePlayerSpells(data, playerSpellSnapshot) then return end
    local encoded = Json(data)
    playerSpellSnapshot = data
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
    playerSpellState, playerSpellSnapshot, lastPlayerSpellSample = nil, nil, nil
    ObservePlayerSpells(true)
    Emit("stats", AZS_STATS or {})
    Emit("pets", { summons = AZS_PETS or {} })
    AZSRecorderJewelry.Request("baseline", current.sequence); AZSRecorderEquipment.Request("baseline", current.sequence)
    pendingZone = false
    meter.Update(true)
    combatText.Start()
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
        combatText.End()
        meter.Update(true)
        probe.Stop("capture_end")
        Emit("capture_end", { reason = "left_world_or_ready" })
        current = nil
        meter.Reset()
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
    if probe.Receive(event, arg1) then return end
    if event == "CHAT_MSG_ADDON" then
        local prefix = arg1
        if prefix == "AZSZONE" then
            combatText.End()
            meter.Update(true)
            probe.Stop("new_zone")
            if current then Emit("capture_end", { reason = "new_zone" }) end
            current, previousPhase, pendingZone, awaitingRun = nil, nil, true, true
            meter.Reset()
            return
        end
        if prefix == "AZSMETER" or prefix == "AZSHEAL" then
            local received = current or awaitingRun
            if received then meter.Receive(prefix, arg2) end
            Poll()
            if current and not received then meter.Receive(prefix, arg2) end
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
            combatText.Update(true)
            meter.Update(true)
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
        combatText.End()
        meter.Update(true)
        probe.Stop(event)
        if current then Emit("capture_end", { reason = event }) end
        current, previousPhase = nil, nil
        meter.Reset()
    elseif event == "PLAYER_ENTERING_WORLD" then
        Poll()
    end
end)
frame:SetScript("OnUpdate", function()
    elapsed = elapsed + (arg1 or 0)
    if elapsed < 0.2 then return end
    elapsed = 0
    Poll()
    combatText.Update(false)
    meter.Update(false)
    probe.Update()
    if current and (not lastPartySample or GetTime() - lastPartySample >= 1) then
        lastPartySample = GetTime()
        ObserveParty("poll", false)
    end
    if current then ObservePlayerSpells(false) end
    if current then AZSRecorderTooltips.Update(Emit) end
    if current then AZSRecorderJewelry.Update(Emit); AZSRecorderEquipment.Update(Emit) end
end)

SLASH_AZSRECORDER1 = "/azsrec"
SlashCmdList["AZSRECORDER"] = function(command)
    Init()
    if command == "probe" then probe.Start(); return end
    if command == "native" then combatText.Report(); return end
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
