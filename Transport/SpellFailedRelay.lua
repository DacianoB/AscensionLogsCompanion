-- Transport/SpellFailedRelay.lua
-- LegacyPlayersV3-style SPELL_FAILED_* localization rewrite that carries
-- snapshot CI chunks through WoWCombatLog.txt on the back of SPELL_CAST_FAILED
-- events.
--
-- Scope-tightened: only active when LoggingCombat + in raid + in combat +
-- user hasn't disabled via config. Originals captured at init and restored
-- on scope exit. UIErrorsFrame hook suppresses sentinel strings from
-- leaking into the red-text overlay.
--
-- Landed-evidence gating (added 0.30.1): the queue head only advances when
-- the next SPELL_CAST_FAILED's failedType arg starts with CI_SENTINEL_PREFIX,
-- which proves the previously-applied chunk was the string the engine read
-- and therefore landed in WoWCombatLog.txt. If failedType is anything else
-- (uncovered Lua global, or a C-side string like "Not enough rage" /
-- "Not enough energy" that bypasses _G entirely), the same chunk stays at
-- the head and gets re-applied on the next event. Prevents the silent
-- chunk-loss class observed on bear druids in 2026-04-30-22.53.58.

local ALC = _G.ALC
local H = {}
ALC.Transport.SpellFailedRelay = H

local C = ALC.Core.Constants

-- Source of truth for the rewrite set lives in Core/Constants.lua
-- (C.RELAY_FAIL_GLOBALS). Ordered most-observed first to maximize the
-- chance any given SPELL_CAST_FAILED reads one of our values.
H.GLOBALS = C.RELAY_FAIL_GLOBALS

H.originals = nil   -- captured at init, { [globalName] = originalValue }
H.active = false
H.queue = nil       -- ring buffer of chunks
H.queueIdx = 1
H.pendingChunk = nil  -- chunk currently sitting in the rewritten globals; cleared on landed evidence

local function ensureOriginalsCaptured()
    if H.originals then return end
    H.originals = {}
    for _, g in ipairs(H.GLOBALS) do
        H.originals[g] = _G[g]
    end
end

local function applyChunk(chunk)
    for _, g in ipairs(H.GLOBALS) do
        local ok = pcall(function() setglobal(g, chunk) end)
        if not ok then
            ALC.Core.Logger.warn("Relay: setglobal failed for " .. g)
        end
    end
end

local function restoreAll()
    if not H.originals then return end
    for g, orig in pairs(H.originals) do
        pcall(function() setglobal(g, orig) end)
    end
end

function H.enqueue(chunk)
    if not H.queue then
        H.queue = ALC.Core.Queue.newRing(C.RELAY_QUEUE_MAX_CHUNKS)
    end
    local sizeBefore = H.queue.size
    ALC.Core.Queue.ringPush(H.queue, { chunk = chunk, pushed_at = time() })
    ALC.Core.Metrics.inc("chunks_queued")
    ALC.Core.Metrics.observe_payload_len(#chunk)
    if sizeBefore == H.queue.capacity then
        -- Push evicted oldest entry
        ALC.Core.Metrics.inc("chunks_dropped_overflow")
    end
end

function H.clearQueue()
    if H.queue then ALC.Core.Queue.ringClear(H.queue) end
    H.pendingChunk = nil
end

-- Scope check: should the relay be active right now?
local function shouldBeActive()
    if not _G.ALC_Config or not ALC_Config.hijack_enabled then return false end
    if not LoggingCombat or not LoggingCombat() then return false end
    if not UnitAffectingCombat("player") then return false end
    local _, instType = IsInInstance()
    -- raid = 25-raid, party = 5-man dungeons. Allow both so dungeon
    -- testing produces CI lines too.
    if instType ~= "raid" and instType ~= "party" then return false end
    return true
end

-- Called on every SPELL_CAST_FAILED sub-event in COMBAT_LOG_EVENT_UNFILTERED.
-- failedType is the localized fail-reason string the engine read for THIS
-- event (CLEU arg at C.RELAY_FAILEDTYPE_ARG_INDEX). If it starts with our
-- sentinel prefix, the previously-applied chunk made it into the log line
-- and the queue head can safely advance. Otherwise the chunk was eaten by
-- an uncovered Lua global or a C-side fail string, so we keep the same
-- head entry and re-apply it on the next event.
function H.onSpellCastFailed(failedType)
    if not H.active then return end
    if not H.queue or H.queue.size == 0 then
        H.pendingChunk = nil
        return
    end

    -- Evict stale chunks at the head
    local nowSec = time()
    local ttl = C.RELAY_CHUNK_TTL_S
    while H.queue.size > 0 do
        local head = ALC.Core.Queue.ringPeek(H.queue, 0)
        if head and (nowSec - head.pushed_at) > ttl then
            ALC.Core.Queue.ringAdvance(H.queue)
            ALC.Core.Metrics.inc("chunks_dropped_ttl")
            H.pendingChunk = nil
        else
            break
        end
    end
    if H.queue.size == 0 then return end

    -- Landed-evidence check: did the prior chunk make it into the log?
    local prefix = C.CI_SENTINEL_PREFIX
    local landed = H.pendingChunk
        and type(failedType) == "string"
        and failedType:sub(1, #prefix) == prefix

    if landed then
        ALC.Core.Queue.ringAdvance(H.queue)
        ALC.Core.Metrics.inc("chunks_landed")
        H.pendingChunk = nil
        if H.queue.size == 0 then return end
    elseif H.pendingChunk then
        -- Prior chunk was eaten (uncovered global or C-side fail string).
        -- Leave the head in place so the same chunk gets another shot.
        ALC.Core.Metrics.inc("chunks_re_applied")
    end

    -- Apply the (still-)current head; idempotent re-applies are cheap and
    -- keep the rewritten globals fresh in case anything else touched them.
    local entry = ALC.Core.Queue.ringPeek(H.queue, 0)
    if entry then
        applyChunk(entry.chunk)
        H.pendingChunk = entry.chunk
        ALC.Core.Metrics.mark_flush()
    end
end

-- Activate / deactivate based on scope changes
function H.reevaluate()
    local want = shouldBeActive()
    if want and not H.active then
        ensureOriginalsCaptured()
        H.active = true
        ALC.Core.Metrics.inc("hijack_activations")
        ALC.Core.Logger.debug("Relay activated")
    elseif not want and H.active then
        restoreAll()
        H.active = false
        H.pendingChunk = nil
        ALC.Core.Metrics.inc("hijack_deactivations")
        ALC.Core.Logger.debug("Relay deactivated")
    end
end

-- UIErrorsFrame hook: silent-drop any message starting with our sentinel
local function installUIErrorSuppressor()
    if UIErrorsFrame and not UIErrorsFrame._alc_hooked then
        local orig = UIErrorsFrame.AddMessage
        UIErrorsFrame.AddMessage = function(self, msg, ...)
            if type(msg) == "string" and msg:sub(1, #C.CI_SENTINEL_PREFIX) == C.CI_SENTINEL_PREFIX then
                return
            end
            return orig(self, msg, ...)
        end
        UIErrorsFrame._alc_hooked = true
    end
end

function H.start()
    installUIErrorSuppressor()

    ALC.RegisterEvent("PLAYER_REGEN_DISABLED", H.reevaluate)
    ALC.RegisterEvent("PLAYER_REGEN_ENABLED", function()
        H.reevaluate()
        -- Do NOT clear the queue here. Short pulls (5-10s of trash) routinely
        -- end with undrained chunks; clearing would drop them. Instead let
        -- undrained chunks roll into the next combat, where TTL eviction
        -- (RELAY_CHUNK_TTL_S) lazily evicts stale entries at the head and
        -- the 400-chunk ring cap bounds growth. lastPeerEnqueued dedup
        -- prevents re-enqueueing the same capture.
    end)
    ALC.RegisterEvent("ZONE_CHANGED_NEW_AREA", H.reevaluate)
    ALC.RegisterEvent("PLAYER_ENTERING_WORLD", H.reevaluate)
    ALC.RegisterEvent("PLAYER_LOGOUT", function() restoreAll() end)

    -- Hook into combat log event for SPELL_CAST_FAILED triggering. Pull
    -- failedType from the documented CLEU arg index so the gating check
    -- can compare it against CI_SENTINEL_PREFIX.
    ALC.RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", function(event, ...)
        local _, subEvent = ...
        if subEvent == "SPELL_CAST_FAILED" then
            local failedType = select(C.RELAY_FAILEDTYPE_ARG_INDEX, ...)
            H.onSpellCastFailed(failedType)
        end
    end)
end

-- User kill switch. Note: the SavedVariable key stays `hijack_enabled` to
-- preserve user configs across the rename; only the module surface was
-- renamed to "Relay" in 0.30.1.
function H.disable()
    _G.ALC_Config.hijack_enabled = false
    H.reevaluate()
end
