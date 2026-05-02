-- Capture/EpochTalentScan.lua
-- Vanilla 3-tab talent reader for Project Epoch (Kezan / Gurubashi). Epoch
-- is closer to vanilla 1.12 mechanically than to retail 3.3.5: no CAO,
-- no mystic enchants, plain GetTalentInfo trees per class.
--
-- Validated 2026-04-28 via ALC_Epoch_Probe on a level-60 Warrior on Kezan
-- and on a Warlock peer-inspect target. Findings (see
-- addons/alc-multi-server-design.md §B and §D):
--
--   * GetNumTalentTabs() returns 3 (the inspect-arg variant returns 0;
--     don't use it).
--   * GetTalentTabInfo(tab, true, false, group) honors the talent group
--     argument on inspect targets; the no-group variant defaults to slot 1,
--     which is wrong for any target whose active spec lives in slot 2.
--   * GetTalentInfo(tab, idx, true, false, group) same — slot 1 default.
--   * GetActiveTalentGroup(isInspect) returns the inspected unit's currently
--     active slot (1 or 2). Validated 2026-05-02 by inspect + spec-swap on
--     Kezan: roundtrip /dump GetActiveTalentGroup("target") returned 1 then
--     2 across the swap.
--   * INSPECT_TALENT_READY fires reliably ~+0.22s after NotifyInspect.
--
-- Snapshot shape (stamped onto ci.talents by InspectLoop.finalizeInspect /
-- LocalScan.buildLocalCI):
--   { talent_groups = {
--       [1] = { tabs = { [1..3] = { name, points, talents } } },
--       [2] = { tabs = { [1..3] = { name, points, talents } } },
--     },
--     active_group = 1 or 2 or nil,
--   }
-- where each `talents` is keyed by the GAME talent index (the `i` in the
-- GetTalentInfo loop) so the backend can join directly against
-- talents_epoch.talent_index without index-translation. Only ranks > 0 are
-- emitted; zero-rank slots stay nil so JSON.stringify keeps the table sparse.
--
-- Why both groups: Project Epoch's "multi-spec" system saves two builds in
-- the standard talent-group slots. Pre-v5 captures only read slot 1 by
-- default — see Themeatman / Saws on Kezan for the smoking-gun case
-- (slot 1 = static "off" build; raid play happens in slot 2). Capturing
-- both groups + tagging active-via-API removes the per-target guesswork.

local ALC = _G.ALC
local E = {}
ALC.Capture.EpochTalentScan = E

-- Read inspected (or own-player) vanilla talents into the rich snapshot
-- shape. Pass "player" for the local player or any inspectable unit token
-- (e.g. "target") for a peer. Returns nil if the API surface isn't
-- available, otherwise { talent_groups = { [1]={...}, [2]={...} },
-- active_group = N }.
function E.readInspectedTalents(unit)
    if type(_G.GetNumTalentTabs) ~= "function"
       or type(_G.GetTalentTabInfo) ~= "function"
       or type(_G.GetTalentInfo) ~= "function"
       or type(_G.GetNumTalents) ~= "function" then
        return nil
    end

    -- Don't pass the inspect arg to GetNumTalentTabs; on Epoch it returns 0.
    -- Iterate with (tab, isInspect, false, group) for each tab's data.
    local isInspect = (unit ~= "player")
    local nTabs = GetNumTalentTabs() or 3

    local groups = {}
    for group = 1, 2 do
        local tabs = {}
        for tab = 1, nTabs do
            local name, _, points = GetTalentTabInfo(tab, isInspect, false, group)
            local nTalents = GetNumTalents(tab) or 0
            local talents = {}
            for i = 1, nTalents do
                local tname, _, _, _, rank, maxRank =
                    GetTalentInfo(tab, i, isInspect, false, group)
                if rank and rank > 0 then
                    talents[i] = {
                        name = tname,
                        rank = rank,
                        max  = maxRank,
                    }
                end
            end
            tabs[tab] = {
                name    = name,
                points  = tonumber(points) or 0,
                talents = talents,
            }
        end
        groups[group] = { tabs = tabs }
    end

    -- Trust GetActiveTalentGroup for both self and peer on Epoch — confirmed
    -- working post-fresh-inspect for inspect targets. Defensive pcall in case
    -- a future Epoch patch breaks the inspect-side variant; backend has a
    -- "more total points" fallback when active_group is nil.
    local activeGroup
    if type(GetActiveTalentGroup) == "function" then
        local ok, g = pcall(GetActiveTalentGroup, isInspect, false)
        if ok and (g == 1 or g == 2) then
            activeGroup = g
        end
    end

    return {
        talent_groups = groups,
        active_group  = activeGroup,
    }
end
