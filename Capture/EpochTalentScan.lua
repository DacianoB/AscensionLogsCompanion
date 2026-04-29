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
--   * GetTalentTabInfo(tab, true) on an inspect target returns
--     (name, icon, pointsSpent) matching the target's actual spec.
--   * GetTalentInfo(tab, idx, true) returns (name, _, _, _, rank, maxRank).
--   * INSPECT_TALENT_READY fires reliably ~+0.22s after NotifyInspect.
--
-- Snapshot shape (stamped onto ci.talents by InspectLoop.finalizeInspect):
--   { tabs = {
--       [1] = { name = "Arms", points = 31, talents = {
--                 { name = "Improved Heroic Strike", rank = 3, max = 3 },
--                 ... } },
--       [2] = { name = "Fury",  points = 5,  talents = { ... } },
--       [3] = { name = "Protection", points = 15, talents = { ... } },
--     }
--   }
-- Only ranks > 0 are emitted; the backend rebuilds the full tree if needed.

local ALC = _G.ALC
local E = {}
ALC.Capture.EpochTalentScan = E

-- Read inspected (or own-player) vanilla talents into the rich snapshot
-- shape. Pass "player" for the local player or any inspectable unit token
-- (e.g. "target") for a peer. Returns nil if the API surface isn't
-- available, otherwise { tabs = { [1..3] = { name, points, talents } } }.
function E.readInspectedTalents(unit)
    if type(_G.GetNumTalentTabs) ~= "function"
       or type(_G.GetTalentTabInfo) ~= "function"
       or type(_G.GetTalentInfo) ~= "function"
       or type(_G.GetNumTalents) ~= "function" then
        return nil
    end

    -- Don't pass the inspect arg to GetNumTalentTabs; on Epoch it returns 0.
    -- Iterate with (tab, true) for each tab's data when reading a peer.
    local isInspect = (unit ~= "player")
    local nTabs = GetNumTalentTabs() or 3

    local tabs = {}
    for tab = 1, nTabs do
        local name, _, points = GetTalentTabInfo(tab, isInspect)
        local talents = {}
        local nTalents = GetNumTalents(tab) or 0
        for i = 1, nTalents do
            local tname, _, _, _, rank, maxRank = GetTalentInfo(tab, i, isInspect)
            if rank and rank > 0 then
                talents[#talents + 1] = {
                    name = tname,
                    rank = rank,
                    max  = maxRank,
                }
            end
        end
        tabs[tab] = {
            name    = name,
            points  = points,
            talents = talents,
        }
    end

    return { tabs = tabs }
end
