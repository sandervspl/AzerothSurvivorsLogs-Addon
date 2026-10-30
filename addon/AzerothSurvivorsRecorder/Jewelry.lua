-- Observations of equipped state, never clicks or inferred selected cards.
AZSRecorderJewelry = {}
local J = AZSRecorderJewelry
local slots = { "Finger0Slot", "Finger1Slot", "NeckSlot", "Trinket0Slot", "Trinket1Slot" }
local NAME = "AZSRecorderJewelryScan"
local tip, signatures, pending, nextCheck, count, capped

local function Lines(slot, equipment)
    if not tip then tip = CreateFrame("GameTooltip", NAME, UIParent, "GameTooltipTemplate") end
    tip:SetOwner(UIParent, "ANCHOR_NONE")
    tip:ClearLines()
    local hasItem = tip:SetInventoryItem("player", slot)
    local lines, bytes, clipped = {}, 0, false
    local byteLimit = equipment and 6000 or 8000
    local n = tip:NumLines() or 0
    local limit = equipment and 64 or 32
    if n > limit then n = limit; clipped = true end
    for i = 1, n do
        local row = {}
        for _, side in ipairs({ "Left", "Right" }) do
            local fs = getglobal(NAME .. "Text" .. side .. i)
            local text = fs and fs:GetText()
            if type(text) == "string" then
                if string.len(text) > 4000 or bytes + string.len(text) > byteLimit then
                    clipped = true
                else
                    local key = string.lower(side)
                    row[key] = text
                    bytes = bytes + string.len(text)
                    if fs.GetTextColor then
                        local r, g, b, a = fs:GetTextColor()
                        if r and g and b then
                            row[key .. "Color"] = { r, g, b }
                            if equipment and type(a) == "number" then row[key .. "Color"][4] = a end
                        end
                    end
                end
            end
        end
        table.insert(lines, row)
    end
    tip:Hide()
    return lines, clipped, hasItem
end

local function Read(key, equipment)
    local data = { slotKey = key, status = "unavailable", lines = {} }
    if type(GetInventorySlotInfo) ~= "function" or type(GetInventoryItemLink) ~= "function"
        or type(GetInventoryItemTexture) ~= "function" then return data end
    local slot = GetInventorySlotInfo(key)
    if type(slot) ~= "number" or slot < 1 or slot > 30 then return data end
    data.slot = slot
    local link = GetInventoryItemLink("player", slot)
    local icon = GetInventoryItemTexture("player", slot)
    if type(link) == "string" and string.len(link) <= 4000 then data.link = link end
    if type(icon) == "string" and string.len(icon) <= 1000 then data.icon = icon end
    if not equipment and not link and not icon then data.status = "empty"; return data end
    if type(GetInventoryItemQuality) == "function" then
        local ok, quality = pcall(GetInventoryItemQuality, "player", slot)
        if ok and type(quality) == "number" and quality >= 0 and quality <= 7
            and math.floor(quality) == quality then data.quality = quality end
    end
    if type(getglobal) ~= "function" then return data end
    local hasItem
    data.lines, data.truncated, hasItem = Lines(slot, equipment)
    if equipment and not link and not icon and (hasItem == false or hasItem == 0) then
        data.status = "empty"; return data
    end
    local title = data.lines[1] and data.lines[1].left
    if title and title ~= "" and data.link then data.status = "captured" end
    return data
end

local function Signature(data)
    local parts = {}
    local function Add(value)
        local text = tostring(value)
        table.insert(parts, tostring(string.len(text)) .. ":" .. text)
    end
    for _, field in ipairs({ "status", "slot", "link", "icon", "quality", "truncated" }) do Add(data[field]) end
    for _, row in ipairs(data.lines) do
        Add(row.left); Add(row.right)
        for _, color in ipairs({ "leftColor", "rightColor" }) do
            for i = 1, 4 do Add(row[color] and row[color][i]) end
        end
    end
    return table.concat(parts)
end

function J.Reset()
    signatures, pending, nextCheck, count, capped = {}, nil, 0, 0, false
end

function J.Request(reason, sequence)
    if not pending then pending = { reason = reason, sequence = sequence, at = GetTime(), pass = 1 }
    else pending.reason = reason; pending.sequence = sequence end
end

local function Capture(emit, reason, sequence, attempt)
    for _, key in ipairs(slots) do
        local ok, data = pcall(Read, key)
        if tip then pcall(function() tip:Hide() end) end
        if not ok then data = { slotKey = key, status = "unavailable", lines = {} } end
        local signature = Signature(data)
        if signature ~= signatures[key] then
            if count >= 2000 then
                if not capped then emit("jewelry_capture_limit", { limit = 2000 }); capped = true end
                return
            end
            data.baseline = signatures[key] == nil
            data.extractorVersion, data.reason, data.triggerSeq, data.attempt = 1, reason, sequence, attempt
            data.locale = "unknown"
            if type(GetLocale) == "function" then
                local read, locale = pcall(GetLocale)
                if read and type(locale) == "string" then data.locale = locale end
            end
            emit("jewelry", data)
            signatures[key], count = signature, count + 1
        end
    end
end

function J.Update(emit)
    if capped then return end
    local now = GetTime()
    if pending then
        local delay = ({ 0, 0.4, 1.2 })[pending.pass]
        if now - pending.at >= delay then
            Capture(emit, pending.reason, pending.sequence, pending.pass)
            pending.pass = pending.pass + 1
            if pending.pass > 3 then pending = nil; nextCheck = now + 2 end
        end
    elseif now >= nextCheck then
        Capture(emit, "periodic", nil, 1)
        nextCheck = now + 2
    end
end

J.Reset()

-- Persistent equipment details supplement independently observed native-save identity.
-- They are timestamped observations, never retroactively labelled pre-run reads.
AZSRecorderEquipment = {}
local E = AZSRecorderEquipment
local equipmentSlots = { "HeadSlot", "ShoulderSlot", "ShirtSlot", "ChestSlot",
    "WaistSlot", "LegsSlot", "FeetSlot", "WristSlot", "HandsSlot", "BackSlot",
    "MainHandSlot", "SecondaryHandSlot", "RangedSlot", "TabardSlot" }
local gearSignatures, gearPending, gearNext, gearCount, gearCapped
function E.Reset()
    gearSignatures, gearPending, gearNext, gearCount, gearCapped = {}, nil, 0, 0, false
end
function E.Request(reason, sequence)
    if not gearPending then gearPending = { reason = reason, sequence = sequence, at = GetTime(), pass = 1 }
    else gearPending.reason = reason; gearPending.sequence = sequence end
end
function E.Update(emit)
    if gearCapped then return end
    local now = GetTime()
    if gearPending then
        if now - gearPending.at < ({ 0, 0.4, 1.2 })[gearPending.pass] then return end
    elseif now < gearNext then return end
    local request = gearPending or { reason = "periodic", pass = 1 }
    for _, key in ipairs(equipmentSlots) do
        local ok, data = pcall(Read, key, true)
        if tip then pcall(function() tip:Hide() end) end
        if not ok then data = { slotKey = key, status = "unavailable", lines = {} } end
        local signature = Signature(data)
        if signature ~= gearSignatures[key] then
            if gearCount >= 1000 then
                emit("equipment_capture_limit", { limit = 1000 }); gearCapped = true; return
            end
            data.baseline = gearSignatures[key] == nil
            data.extractorVersion, data.reason, data.triggerSeq, data.attempt = 1, request.reason, request.sequence, request.pass
            data.locale = "unknown"
            if type(GetLocale) == "function" then
                local read, locale = pcall(GetLocale)
                if read and type(locale) == "string" then data.locale = locale end
            end
            emit("equipment_tooltip", data)
            gearSignatures[key], gearCount = signature, gearCount + 1
        end
    end
    if gearPending then
        gearPending.pass = gearPending.pass + 1
        if gearPending.pass > 3 then gearPending = nil; gearNext = now + 5 end
    else gearNext = now + 5 end
end
E.Reset()
