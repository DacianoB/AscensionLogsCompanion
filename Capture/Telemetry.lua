-- Capture/Telemetry.lua
-- Low-frequency encounter telemetry for future analysis tooling.
--
-- This stream is separate from combatant-info (CI) snapshots. CI describes a
-- player's build/equipment; telemetry describes where visible players were and
-- which hostile NPCs were active during logged combat.

local ALC = _G.ALC
local T = {}
ALC.Capture.Telemetry = T

local C = ALC.Core.Constants

T.snapshotCounter = 0
T.monsters = {}
T.started = false
T.accum = 0
T.lastSkipReason = "not_started"
T.lastSnapshotAt = nil
T.lastSnapshotId = nil

local function nowMs()
    return time() * 1000
end

local function toBase36(n)
    if n == 0 then return "0" end
    local digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    local out = ""
    local x = n
    while x > 0 do
        local r = x - math.floor(x / 36) * 36
        out = digits:sub(r + 1, r + 1) .. out
        x = math.floor(x / 36)
    end
    return out
end

local function round4(n)
    if type(n) ~= "number" then return nil end
    return math.floor(n * 10000 + 0.5) / 10000
end

local function instanceInfo()
    if type(_G.GetInstanceInfo) ~= "function" then return nil end
    local name, instType, diffIdx, diffName, maxPlayers,
          playerDiff, isDynamic, mapId = GetInstanceInfo()
    return {
        name = name,
        instance_type = instType,
        difficulty_index = diffIdx,
        difficulty_name = diffName,
        max_players = maxPlayers,
        player_difficulty = playerDiff,
        is_dynamic = isDynamic and true or false,
        map_id = mapId,
    }
end

local function mapInfo()
    local instName, instType, diffIdx, diffName, maxPlayers,
          playerDiff, isDynamic, instanceMapId = nil
    if type(_G.GetInstanceInfo) == "function" then
        instName, instType, diffIdx, diffName, maxPlayers,
            playerDiff, isDynamic, instanceMapId = GetInstanceInfo()
    end

    local out = {
        instance_map_id = instanceMapId,
        instance_name = instName,
        instance_type = instType,
        difficulty_index = diffIdx,
        difficulty_name = diffName,
        max_players = maxPlayers,
        player_difficulty = playerDiff,
        is_dynamic = isDynamic and true or false,
        zone_text = (type(GetZoneText) == "function") and GetZoneText() or nil,
        subzone_text = (type(GetSubZoneText) == "function") and GetSubZoneText() or nil,
    }
    if type(GetCurrentMapAreaID) == "function" then
        out.world_map_area_id = GetCurrentMapAreaID()
        out.map_area_id = out.world_map_area_id -- legacy alias
    end
    if type(GetMapInfo) == "function" then
        out.map_file = GetMapInfo()
    end
    if type(GetCurrentMapDungeonLevel) == "function" then
        out.dungeon_level = GetCurrentMapDungeonLevel()
    end
    if type(GetCurrentMapContinent) == "function" then
        out.continent = GetCurrentMapContinent()
        out.map_continent = out.continent -- legacy alias
    end
    if type(GetCurrentMapZone) == "function" then
        out.zone = GetCurrentMapZone()
        out.map_zone = out.zone -- legacy alias
    end
    return out
end

local function withCurrentZoneMap(fn)
    local canAdjust = type(SetMapToCurrentZone) == "function"
        and not (_G.WorldMapFrame and WorldMapFrame:IsShown())
    local oldContinent, oldZone
    if canAdjust then
        if type(GetCurrentMapContinent) == "function" then
            oldContinent = GetCurrentMapContinent()
        end
        if type(GetCurrentMapZone) == "function" then
            oldZone = GetCurrentMapZone()
        end
        pcall(SetMapToCurrentZone)
    end

    local a, b, c = fn()

    if canAdjust and oldContinent and oldContinent > 0
       and type(SetMapZoom) == "function" then
        pcall(SetMapZoom, oldContinent, oldZone or 0)
    end
    return a, b, c
end

local function readPosition(unit)
    if not UnitExists(unit) then return nil end
    local out = nil

    if _G.C_Map
       and type(C_Map.GetBestMapForUnit) == "function"
       and type(C_Map.GetPlayerMapPosition) == "function" then
        local okMap, mapId = pcall(C_Map.GetBestMapForUnit, unit)
        if okMap and mapId then
            local okPos, vec = pcall(C_Map.GetPlayerMapPosition, mapId, unit)
            if okPos and vec then
                local x = (type(vec.GetXY) == "function") and select(1, vec:GetXY()) or vec.x
                local y = (type(vec.GetXY) == "function") and select(2, vec:GetXY()) or vec.y
                if x and y and (x ~= 0 or y ~= 0) then
                    out = out or {}
                    out.map_id = mapId
                    out.map_x = round4(x)
                    out.map_y = round4(y)
                    out.map_position_source = "C_Map"
                end
            end
        end
    end

    if not out and type(GetPlayerMapPosition) == "function" then
        local ok, x, y = pcall(GetPlayerMapPosition, unit)
        if ok and x and y and (x ~= 0 or y ~= 0) then
            out = out or {}
            out.map_x = round4(x)
            out.map_y = round4(y)
            out.map_position_source = "GetPlayerMapPosition"
        end
    end

    if type(UnitPosition) == "function" then
        local ok, y, x, z, instanceId = pcall(UnitPosition, unit)
        if ok and x and y and (x ~= 0 or y ~= 0) then
            out = out or {}
            out.world_x = round4(x)
            out.world_y = round4(y)
            out.world_z = round4(z)
            out.world_instance_id = instanceId
            out.world_position_source = "UnitPosition"
        end
    end

    return out
end

local function unitPower(unit)
    if type(UnitPowerType) ~= "function" then return nil end
    local powerType, powerToken = UnitPowerType(unit)
    local cur = type(UnitPower) == "function" and UnitPower(unit) or nil
    local max = type(UnitPowerMax) == "function" and UnitPowerMax(unit) or nil
    return {
        type = powerType,
        token = powerToken,
        current = cur,
        max = max,
    }
end

local function unitSummary(unit, roster)
    if not UnitExists(unit) then return nil end
    local _, classToken = UnitClass(unit)
    local health = type(UnitHealth) == "function" and UnitHealth(unit) or nil
    local maxHealth = type(UnitHealthMax) == "function" and UnitHealthMax(unit) or nil
    local targetUnit = unit .. "target"
    local targetGuid = UnitExists(targetUnit) and UnitGUID(targetUnit) or nil
    local pos = readPosition(unit)

    local out = {
        unit = unit,
        guid = UnitGUID(unit),
        name = UnitName(unit),
        class = classToken,
        level = UnitLevel(unit),
        subgroup = roster and roster.subgroup or nil,
        zone = roster and roster.zone or nil,
        online = roster and roster.online,
        dead = (UnitIsDeadOrGhost and UnitIsDeadOrGhost(unit)) and true or false,
        connected = (UnitIsConnected and UnitIsConnected(unit)) and true or false,
        health = health,
        max_health = maxHealth,
        power = unitPower(unit),
        target_guid = targetGuid,
        target_name = targetGuid and UnitName(targetUnit) or nil,
    }

    if pos then
        out.map_x = pos.map_x
        out.map_y = pos.map_y
    end
    return out
end

local function collectUnits()
    local units = {}
    local targetCounts = {}
    local positioned = 0

    local function add(unit, roster)
        local info = unitSummary(unit, roster)
        if not info then return end
        units[#units + 1] = info
        if info.map_x and info.map_y then positioned = positioned + 1 end
        if info.target_guid then
            targetCounts[info.target_guid] = (targetCounts[info.target_guid] or 0) + 1
        end
    end

    local raidN = (GetNumRaidMembers and GetNumRaidMembers()) or 0
    if raidN > 0 then
        for i = 1, raidN do
            local roster = nil
            if type(GetRaidRosterInfo) == "function" then
                local name, _rank, subgroup, level, _className, classFile, zone, online, isDead =
                    GetRaidRosterInfo(i)
                roster = {
                    name = name,
                    subgroup = subgroup,
                    level = level,
                    class = classFile,
                    zone = zone,
                    online = online and true or false,
                    dead = isDead and true or false,
                }
            end
            add("raid" .. i, roster)
        end
    else
        add("player", { subgroup = 1, online = true })
        local partyN = (GetNumPartyMembers and GetNumPartyMembers()) or 0
        for i = 1, partyN do
            add("party" .. i, { subgroup = 1, online = true })
        end
    end

    return units, targetCounts, positioned
end

local function band(v, mask)
    if not v or not mask then return 0 end
    if _G.bit and bit.band then return bit.band(v, mask) end
    if _G.bit32 and bit32.band then return bit32.band(v, mask) end
    return 0
end

local function isHostileNpc(flags)
    if not flags then return false end
    local hostile = _G.COMBATLOG_OBJECT_REACTION_HOSTILE
    local npcControl = _G.COMBATLOG_OBJECT_CONTROL_NPC
    local npcType = _G.COMBATLOG_OBJECT_TYPE_NPC
    if not hostile then return false end
    if band(flags, hostile) == 0 then return false end
    if npcControl and band(flags, npcControl) ~= 0 then return true end
    if npcType and band(flags, npcType) ~= 0 then return true end
    return false
end

local function extractNpcId(guid)
    if type(guid) ~= "string" then return nil end
    local retail = guid:match("^Creature%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
    if retail then return tonumber(retail) end
    local hex = guid:match("^0xF130(%x%x%x%x%x%x)")
    if hex then return tonumber(hex, 16) end
    return nil
end

local function touchMonster(guid, name, flags, role, subEvent)
    if not guid then return nil end
    local now = nowMs()
    local m = T.monsters[guid]
    if not m then
        m = {
            guid = guid,
            npc_id = extractNpcId(guid),
            name = name,
            flags = flags,
            first_seen_at = now,
            last_seen_at = now,
            source_events = 0,
            dest_events = 0,
            casts = 0,
            damage_done = 0,
            damage_taken = 0,
            healing_done = 0,
            death_at = nil,
        }
        T.monsters[guid] = m
        if ALC.Core.Metrics then ALC.Core.Metrics.inc("telemetry_monsters_seen") end
    end

    m.name = name or m.name
    m.flags = flags or m.flags
    m.last_seen_at = now
    m.last_event = subEvent
    if role == "source" then
        m.source_events = (m.source_events or 0) + 1
    elseif role == "dest" then
        m.dest_events = (m.dest_events or 0) + 1
    end
    return m
end

local function eventAmount(subEvent, ...)
    if subEvent == "SWING_DAMAGE" then
        return select(9, ...)
    elseif subEvent == "RANGE_DAMAGE"
        or subEvent == "SPELL_DAMAGE"
        or subEvent == "SPELL_PERIODIC_DAMAGE"
        or subEvent == "SPELL_BUILDING_DAMAGE" then
        return select(12, ...)
    elseif subEvent == "ENVIRONMENTAL_DAMAGE" then
        return select(10, ...)
    elseif subEvent == "SPELL_HEAL"
        or subEvent == "SPELL_PERIODIC_HEAL" then
        return select(12, ...)
    end
    return nil
end

local function spellInfo(subEvent, ...)
    if subEvent:sub(1, 5) == "SWING" or subEvent:sub(1, 13) == "ENVIRONMENTAL" then
        return nil, nil
    end
    return select(9, ...), select(10, ...)
end

local function onCombatLog(event, ...)
    if not (_G.ALC_Config and ALC_Config.telemetry_enabled) then return end
    local _ts, subEvent, sourceGUID, sourceName, sourceFlags,
          destGUID, destName, destFlags = ...

    if subEvent == "UNIT_DIED" then
        if isHostileNpc(destFlags) then
            local m = touchMonster(destGUID, destName, destFlags, "dest", subEvent)
            if m then m.death_at = nowMs() end
        end
        return
    end

    local sourceMonster = isHostileNpc(sourceFlags)
    local destMonster = isHostileNpc(destFlags)
    if not sourceMonster and not destMonster then return end

    local spellId, spellName = spellInfo(subEvent, ...)
    local amount = eventAmount(subEvent, ...)

    if sourceMonster then
        local m = touchMonster(sourceGUID, sourceName, sourceFlags, "source", subEvent)
        if m then
            if subEvent:find("_CAST_", 1, false) then
                m.casts = (m.casts or 0) + 1
            end
            if spellId then
                m.last_spell_id = spellId
                m.last_spell_name = spellName
            end
            if subEvent:find("_DAMAGE", 1, false) and type(amount) == "number" then
                m.damage_done = (m.damage_done or 0) + amount
            elseif subEvent:find("_HEAL", 1, false) and type(amount) == "number" then
                m.healing_done = (m.healing_done or 0) + amount
            end
        end
    end

    if destMonster then
        local m = touchMonster(destGUID, destName, destFlags, "dest", subEvent)
        if m and subEvent:find("_DAMAGE", 1, false) and type(amount) == "number" then
            m.damage_taken = (m.damage_taken or 0) + amount
        end
    end
end

local function visibleMonsterFields(guid)
    local candidates = { "target", "focus", "mouseover", "pettarget" }
    local raidN = (GetNumRaidMembers and GetNumRaidMembers()) or 0
    if raidN > 0 then
        for i = 1, raidN do candidates[#candidates + 1] = "raid" .. i .. "target" end
    else
        for i = 1, ((GetNumPartyMembers and GetNumPartyMembers()) or 0) do
            candidates[#candidates + 1] = "party" .. i .. "target"
        end
    end

    for _, unit in ipairs(candidates) do
        if UnitExists(unit) and UnitGUID(unit) == guid then
            return {
                unit = unit,
                health = type(UnitHealth) == "function" and UnitHealth(unit) or nil,
                max_health = type(UnitHealthMax) == "function" and UnitHealthMax(unit) or nil,
                level = UnitLevel(unit),
                classification = UnitClassification and UnitClassification(unit) or nil,
                creature_type = UnitCreatureType and UnitCreatureType(unit) or nil,
            }
        end
    end
    return nil
end

local function collectMonsters(targetCounts)
    local out = {}
    local now = nowMs()
    local activeWindow = (C.TELEMETRY_MONSTER_ACTIVE_WINDOW_S or 12) * 1000
    local pruneAfter = (C.TELEMETRY_MONSTER_PRUNE_AFTER_S or 60) * 1000

    for guid, m in pairs(T.monsters) do
        local age = now - (m.last_seen_at or now)
        if age > pruneAfter then
            T.monsters[guid] = nil
        elseif age <= activeWindow or (m.death_at and now - m.death_at <= activeWindow) then
            local entry = {
                guid = guid,
                npc_id = m.npc_id,
                name = m.name,
                flags = m.flags,
                first_seen_at = m.first_seen_at,
                last_seen_at = m.last_seen_at,
                death_at = m.death_at,
                source_events = m.source_events,
                dest_events = m.dest_events,
                casts = m.casts,
                damage_done = m.damage_done,
                damage_taken = m.damage_taken,
                healing_done = m.healing_done,
                last_event = m.last_event,
                last_spell_id = m.last_spell_id,
                last_spell_name = m.last_spell_name,
                targeted_by_count = targetCounts and targetCounts[guid] or 0,
            }
            local visible = visibleMonsterFields(guid)
            if visible then entry.visible = visible end
            out[#out + 1] = entry
        end
    end
    return out
end

local function relayQueueSize()
    local relay = ALC.Transport and ALC.Transport.SpellFailedRelay
    if not relay or not relay.queue then return 0 end
    return relay.queue.size or 0
end

local function shouldSnapshot()
    if not _G.ALC_Config then T.lastSkipReason = "no_config"; return false end
    if not ALC_Config.telemetry_enabled then T.lastSkipReason = "disabled"; return false end
    if not ALC_Config.is_logger then T.lastSkipReason = "not_logger"; return false end
    if not ALC_Config.hijack_enabled then T.lastSkipReason = "relay_disabled"; return false end
    if not LoggingCombat or not LoggingCombat() then T.lastSkipReason = "combatlog_off"; return false end
    if not UnitAffectingCombat("player") then T.lastSkipReason = "not_in_combat"; return false end
    local _, instType = IsInInstance()
    if instType ~= "raid" and instType ~= "party" then T.lastSkipReason = "not_instance"; return false end
    if relayQueueSize() >= (C.TELEMETRY_QUEUE_SKIP_AT_CHUNKS or 300) then
        T.lastSkipReason = "relay_queue_full"
        if ALC.Core.Metrics then ALC.Core.Metrics.inc("telemetry_snapshots_skipped") end
        return false
    end
    T.lastSkipReason = nil
    return true
end

local function buildChunk(sessionId, snapshotId, seq, total, b64payload)
    return string.format("[[ALC_TS_v1_%s_%s_%d/%d]]%s",
        sessionId, snapshotId, seq, total, b64payload)
end

local function enqueuePayload(payload, sessionId, snapshotId)
    local compressed = ALC.Core.Serialize.serializePayload(payload)
    if not compressed then return false end
    local b64 = ALC.Core.Base64.encode(compressed)
    if not b64 then return false end

    local maxBody = C.CHUNK_PAYLOAD_MAX_BYTES
    local total = math.ceil(#b64 / maxBody)
    if total < 1 then total = 1 end
    for seq = 1, total do
        local startIdx = (seq - 1) * maxBody + 1
        local endIdx = math.min(startIdx + maxBody - 1, #b64)
        ALC.Transport.SpellFailedRelay.enqueue(
            buildChunk(sessionId, snapshotId, seq, total, b64:sub(startIdx, endIdx))
        )
    end
    return true
end

function T.snapshot(reason)
    if not shouldSnapshot() then return false end
    local sessionId = _G.ALC_LocalState and ALC_LocalState.session_id
    if not sessionId then return false end

    T.snapshotCounter = (T.snapshotCounter or 0) + 1
    local snapshotId = toBase36(T.snapshotCounter)

    local units, targetCounts, positioned = withCurrentZoneMap(collectUnits)
    local tracker = ALC.Capture.EncounterTracker
    local payload = {
        schema_version = C.TELEMETRY_SCHEMA_VERSION,
        addon_version = C.VERSION,
        stream = "telemetry",
        event_type = "encounter_snapshot",
        session_id = sessionId,
        snapshot_id = snapshotId,
        captured_at = nowMs(),
        captured_by_guid = UnitGUID("player"),
        server = ALC.Profile or "unknown",
        reason = reason or "interval",
        encounter = {
            in_combat = UnitAffectingCombat("player") and true or false,
            boss = tracker and tracker.getCurrentBoss and tracker.getCurrentBoss() or nil,
            pull_id = tracker and tracker.getCurrentPullId and tracker.getCurrentPullId() or nil,
        },
        instance = instanceInfo(),
        map = mapInfo(),
        units = units,
        monsters = collectMonsters(targetCounts),
    }

    if enqueuePayload(payload, sessionId, snapshotId) then
        T.lastSnapshotAt = time()
        T.lastSnapshotId = snapshotId
        if ALC.Core.Metrics then
            ALC.Core.Metrics.inc("telemetry_snapshots_queued")
            ALC.Core.Metrics.inc("telemetry_units_positioned", positioned or 0)
        end
        ALC.Core.Logger.debug("Telemetry enqueued: snapshot " .. snapshotId
            .. " units=" .. tostring(units and #units or 0)
            .. " monsters=" .. tostring(payload.monsters and #payload.monsters or 0))
        return true
    end
    return false
end

local function onCombatStart()
    T.monsters = {}
    T.accum = 0
    T.snapshot("combat_start")
end

function T.start()
    if T.started then return end
    T.started = true

    ALC.RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", onCombatLog)
    ALC.RegisterEvent("PLAYER_REGEN_DISABLED", onCombatStart)

    ALC.frame:HookScript("OnUpdate", function(_self, elapsed)
        if not UnitAffectingCombat("player") then
            T.accum = 0
            return
        end
        T.accum = (T.accum or 0) + elapsed
        if T.accum >= (C.TELEMETRY_INTERVAL_S or 2.0) then
            T.accum = 0
            T.snapshot("interval")
        end
    end)
end

function T.forceSnapshot()
    return T.snapshot("manual")
end

function T.probe(logger)
    local log = logger or ALC.Core.Logger.info
    local inInstance, instType = IsInInstance()
    log("Telemetry module: started=" .. tostring(T.started)
        .. " enabled=" .. tostring(_G.ALC_Config and ALC_Config.telemetry_enabled)
        .. " is_logger=" .. tostring(_G.ALC_Config and ALC_Config.is_logger))
    log("Scope: /combatlog=" .. tostring(LoggingCombat and LoggingCombat())
        .. " combat=" .. tostring(UnitAffectingCombat("player"))
        .. " instance=" .. tostring(inInstance) .. "/" .. tostring(instType)
        .. " queue=" .. tostring(relayQueueSize()))
    log("Last: snapshot=" .. tostring(T.lastSnapshotId or "(none)")
        .. " skip=" .. tostring(T.lastSkipReason or "(none)"))

    local pos = withCurrentZoneMap(function() return readPosition("player") end)
    if pos then
        log("Player position: map=(" .. tostring(pos.map_x) .. "," .. tostring(pos.map_y)
            .. ") source=" .. tostring(pos.map_position_source)
            .. " world=(" .. tostring(pos.world_x) .. "," .. tostring(pos.world_y)
            .. "," .. tostring(pos.world_z) .. ") world_source=" .. tostring(pos.world_position_source))
    else
        log("Player position: unavailable from GetPlayerMapPosition/C_Map/UnitPosition")
    end

    local n = 0
    for _ in pairs(T.monsters or {}) do n = n + 1 end
    log("Tracked hostile NPCs in memory: " .. tostring(n))
end
