-- Independent stock 1.12 tooltip reader. Never clicks actions or choice cards.
AZSRecorderTooltips = {}
local T = AZSRecorderTooltips
local tip, pending, signatures, count, nextCheck, capped
local NAME = "AZSRecorderSpellScan"

local function Plain(text)
    text = string.gsub(text or "", "|c%x%x%x%x%x%x%x%x", "")
    text = string.gsub(text, "|r", "")
    return (string.gsub(text, "^%s*(.-)%s*$", "%1"))
end

local function Scanner()
    if not tip then tip = CreateFrame("GameTooltip", NAME, UIParent, "GameTooltipTemplate") end
    return tip
end

local function ReadLines(scan)
    local lines, clipped, bytes = {}, false, 0
    local n = scan:NumLines() or 0
    if n > 32 then clipped = true; n = 32 end
    for i = 1, n do
        local row = {}
        for _, side in ipairs({ "Left", "Right" }) do
            local fs = getglobal(NAME .. "Text" .. side .. i)
            local text = fs and fs:GetText()
            if type(text) == "string" then
                -- Do not cut through UTF-8. Omit an oversized side and flag the gap.
                if string.len(text) > 4000 or bytes + string.len(text) > 8000 then
                    clipped = true
                else
                    local key = string.lower(side)
                    row[key] = text
                    bytes = bytes + string.len(text)
                    if fs.GetTextColor then
                        local r, g, b = fs:GetTextColor()
                        if r and g and b then row[key .. "Color"] = { r, g, b } end
                    end
                end
            end
        end
        table.insert(lines, row)
    end
    return lines, clipped
end

local function Read(method, value)
    local scan = Scanner()
    scan:SetOwner(UIParent, "ANCHOR_NONE")
    scan:ClearLines()
    scan[method](scan, value)
    local lines, clipped = ReadLines(scan)
    scan:Hide()
    return lines, clipped
end

local function Signature(data)
    local parts = { data.status, tostring(data.spell), tostring(data.rank), tostring(data.slot), tostring(data.truncated) }
    for _, line in ipairs(data.lines) do
        table.insert(parts, line.left or "")
        table.insert(parts, line.right or "")
    end
    return table.concat(parts, "\001")
end

function T.Reset()
    pending, signatures, count, nextCheck, capped = nil, {}, 0, 0, false
end

function T.Request(reason, sequence)
    -- Coalesce a burst, but repeated events must not postpone its final read forever.
    if not pending then pending = { reason = reason, sequence = sequence, at = GetTime(), pass = 1 }
    else pending.reason = reason; pending.sequence = sequence end
end

function T.Forget(key)
    signatures[key] = nil
end

local function Capture(emit, reason, sequence, attempt)
    local spells, names, byName, actions = AZS_SPELLS or {}, {}, {}, {}
    local available = type(HasAction) == "function" and type(getglobal) == "function"
    for _, s in ipairs(spells) do
        if s.key and s.spell and available then
            local ok, lines = pcall(Read, "SetHyperlink", "enchant:" .. tostring(s.spell))
            local name = ok and lines[1] and Plain(lines[1].left)
            if name and name ~= "" then
                names[s.key] = name
                byName[name] = (byName[name] or 0) + 1
            end
        end
    end
    if available then
        for slot = 1, 120 do
            local ok, has = pcall(HasAction, slot)
            if ok and has then
                local read, lines, clipped = pcall(Read, "SetAction", slot)
                if read and lines[1] then
                    local name = Plain(lines[1].left)
                    if byName[name] then
                        actions[name] = actions[name] or {}
                        table.insert(actions[name], { slot = slot, lines = lines, truncated = clipped })
                    end
                end
            end
        end
    end
    if tip then pcall(function() tip:Hide() end) end
    for _, s in ipairs(spells) do
        if s.key and s.spell and s.rank then
            local name = names[s.key]
            local candidates = name and actions[name]
            local data = {
                key = s.key, spell = s.spell, rank = s.rank, cdmax = s.cdmax,
                extractorVersion = 1, reason = reason, triggerSeq = sequence, attempt = attempt,
                locale = type(GetLocale) == "function" and GetLocale() or "unknown",
                mapping = "none", status = "unavailable", lines = {},
            }
            if name and (byName[name] > 1 or (candidates and table.getn(candidates) > 1)) then
                data.status = "ambiguous"
            elseif candidates and table.getn(candidates) == 1 then
                local candidate = candidates[1]
                data.mapping, data.status, data.slot = "unique-tooltip-name", "matched", candidate.slot
                data.lines, data.truncated = candidate.lines, candidate.truncated
            end
            local signature = Signature(data)
            if signatures[s.key] ~= signature then
                if count >= 2000 then
                    if not capped then emit("tooltip_capture_limit", { limit = 2000 }); capped = true end
                    return
                end
                emit("spell_tooltip", data)
                signatures[s.key], count = signature, count + 1
            end
        end
    end
    -- A removal/reacquisition requires a new baseline even if its tooltip is identical.
    local present = {}
    for _, s in ipairs(spells) do if s.key then present[s.key] = true end end
    for key in pairs(signatures) do if not present[key] then signatures[key] = nil end end
end

function T.Update(emit)
    if capped then return end
    local now = GetTime()
    if pending then
        local delay = ({ 0, 0.4, 1.2 })[pending.pass]
        if now - pending.at >= delay then
            Capture(emit, pending.reason, pending.sequence, pending.pass)
            pending.pass = pending.pass + 1
            if pending.pass > 3 then pending = nil; nextCheck = now + 5 end
        end
    elseif now >= nextCheck then
        Capture(emit, "periodic", nil, 1)
        nextCheck = now + 5
    end
end

T.Reset()
