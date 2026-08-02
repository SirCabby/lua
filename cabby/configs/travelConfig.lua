local Debug = require("utils.Debug.Debug")
local TableUtils = require("utils.TableUtils.TableUtils")

---How much room this character keeps behind whoever it is following.
---
---One number would be the whole setting if a group only ever did one thing. It does two: it walks
---somewhere, and it fights. Walking wants everyone together -- a straggler is the one who misses
---the zone line and the one who pulls the next room -- and a fight wants the opposite of that from
---anybody whose job is not to be stood in it. So there are two distances and a switch between
---them, and what picks one is the fight itself (`cabby.travel`), never the class: a character with
---something to do in melee never reaches the follow band anyway, because the state doing it is
---above follow in the chain and holds the frame.
---
---The relaxed distance buys two different things at once, and the second is the one that is easy
---to miss. A caster stood at melee range is in every ae and every rampage for no reason. And a
---follower that keeps closing to melee range is a follower *moving*, which is a busy follow band
----- so buffing and resting, which sit below it, get no frames for as long as the fight walks
---around. Standing still while the group fights hands those frames back.
---
---The distances live here rather than in the follow state's own section because `cabby.travel`
---owns the following, and travel mode drives that same core from the flee state -- a service
---reading a state's config would be the same mistake as a state reading another state's.
---@class TravelConfig : BaseConfig
local TravelConfig = {
    key = "Travel",
    _ = {
        isInit = false
    }
}

-- Range the settings are allowed in. The floor is a follow that still has somewhere to stand
-- rather than one that walks into the back of whoever it follows; the ceiling is well inside
-- spell range, since a follower is only useful while it is close enough to do its job.
local minDistance = 5
local maxDistance = 200

---@param str string
local function DebugLog(str)
    Debug.Log(TravelConfig.key, str)
end

local function getConfigSection()
    return Global.configStore:GetConfigRoot()[TravelConfig.key]
end

---@param value number
---@param low number
---@param high number
---@return number
local function clamp(value, low, high)
    return math.max(math.min(math.floor(tonumber(value) or low), high), low)
end

local function initAndValidate()
    local taint = false
    if getConfigSection() == nil then
        DebugLog("TravelConfig Section was not set, updating...")
        Global.configStore:GetConfigRoot()[TravelConfig.key] = {}
        taint = true
    end

    local configRoot = getConfigSection()

    if configRoot.follow_distance == nil then
        -- Tight spacing by preference (2026-07): about melee range, close enough to feel like a
        -- group -- but not so near that a parked follower is stood on whoever it is following.
        configRoot.follow_distance = 13
        taint = true
    end

    if configRoot.combat_relax == nil then
        -- On, because it only ever bites on a character that has nothing else to do with the
        -- fight: anything with a job in it is busy at a band above follow and never reaches here.
        configRoot.combat_relax = true
        taint = true
    end

    if configRoot.combat_follow_distance == nil then
        -- Outside the melee ring and everything that swings in it, and still well inside the range
        -- of anything a caster would be casting from back there.
        configRoot.combat_follow_distance = 40
        taint = true
    end

    -- A config edited by hand can hold the one pair that makes no sense: standing *closer* while
    -- the group fights is not a relaxed distance, and the switch beside it would be lying. Fixed
    -- here rather than left for the core to second-guess every pass.
    if configRoot.combat_follow_distance < configRoot.follow_distance then
        configRoot.combat_follow_distance = configRoot.follow_distance
        taint = true
    end

    if taint then
        Global.configStore:SaveConfig()
    end
end

---@diagnostic disable-next-line: duplicate-set-field
function TravelConfig.Init()
    if not TravelConfig._.isInit then
        local ftkey = Global.tracing.open("TravelConfig Setup")

        initAndValidate()

        TravelConfig._.isInit = true
        Global.tracing.close(ftkey)
    end
end

---------------- Config Management --------------------

---@return number distance how close a follow closes to its target when nothing is happening
function TravelConfig.GetFollowDistance()
    return getConfigSection().follow_distance
end

---@param distance number
function TravelConfig.SetFollowDistance(distance)
    local configRoot = getConfigSection()
    configRoot.follow_distance = clamp(distance, minDistance, maxDistance)
    if configRoot.combat_follow_distance < configRoot.follow_distance then
        configRoot.combat_follow_distance = configRoot.follow_distance
    end
    Global.configStore:SaveConfig()
end

---Whether a fight around this character moves the follow out to the distance below.
---
---Off is "hold the same spacing whatever is happening", which is the right answer for a character
---that has to stay on top of whoever it follows -- and for anyone who would rather manage the
---spacing by hand than have it change under them.
---@return boolean relax
function TravelConfig.GetCombatRelax()
    return getConfigSection().combat_relax == true
end

---@param relax boolean
function TravelConfig.SetCombatRelax(relax)
    getConfigSection().combat_relax = relax == true
    Global.configStore:SaveConfig()
    print("Follow relaxes while the group fights: [" .. tostring(relax == true) .. "]")
end

---@return number distance how close a follow closes to its target while there is a fight on
function TravelConfig.GetCombatFollowDistance()
    return getConfigSection().combat_follow_distance
end

---@param distance number
function TravelConfig.SetCombatFollowDistance(distance)
    local configRoot = getConfigSection()
    configRoot.combat_follow_distance = clamp(distance, configRoot.follow_distance, maxDistance)
    Global.configStore:SaveConfig()
end

---@return number min the closest either distance may be set to
function TravelConfig.GetMinDistance()
    return minDistance
end

---@return number max the furthest either distance may be set to
function TravelConfig.GetMaxDistance()
    return maxDistance
end

---@diagnostic disable-next-line: duplicate-set-field
function TravelConfig.Print()
    TableUtils.Print(getConfigSection())
end

return TravelConfig
