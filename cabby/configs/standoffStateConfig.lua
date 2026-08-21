local Debug = require("utils.Debug.Debug")
local TableUtils = require("utils.TableUtils.TableUtils")

---Whether this character stands out of a rooted mob's reach.
---
---**A switch and nothing else, deliberately.** How much room to keep was a number here once and it
---was the wrong shape for the question: reach is a property of the *mob* -- its body measured against
---ours, sixteen units for a rat and forty for a dragon -- so a number set per character is right for
---one mob and wrong for every other, and wrong in the direction that leaves somebody standing in a
---dragon. It is read off each mob instead (`Mobs.Reach`), which costs nothing, needs no upkeep, and
---is the same reading the tank's hold is derived from, so the two halves stay on opposite sides of
---the reach without either being told about the other.
---@class StandoffStateConfig : BaseConfig
local StandoffStateConfig = {
    key = "StandoffState",
    _ = {
        isInit = false
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(StandoffStateConfig.key, str)
end

local function getConfigSection()
    return Global.configStore:GetConfigRoot()[StandoffStateConfig.key]
end

local function initAndValidate()
    local taint = false
    if getConfigSection() == nil then
        DebugLog("StandoffStateConfig Section was not set, updating...")
        Global.configStore:GetConfigRoot()[StandoffStateConfig.key] = {}
        taint = true
    end

    local configRoot = getConfigSection()

    if configRoot.enabled == nil then
        -- On, for the same reason the follow's combat relax is: it only ever bites on a character
        -- with nothing else to do in the fight -- anything with a job in it is busy at a band above
        -- this one -- and only on a mob that reads as rooted, which is a rare enough fight that
        -- the character is standing still the rest of the time either way.
        configRoot.enabled = true
        taint = true
    end

    -- A fixed room-to-keep lived here and was removed at the user's direction: how far out of a
    -- mob's reach to stand is the mob's answer and it is free to ask, so a number set per character
    -- was one more thing to keep right and one more way to be wrong about a mob nobody sized it for.
    -- Dropped rather than left ignored, so nothing carries a setting nothing reads.
    if configRoot.distance ~= nil then
        configRoot.distance = nil
        taint = true
    end

    if taint then
        Global.configStore:SaveConfig()
    end
end

---@diagnostic disable-next-line: duplicate-set-field
function StandoffStateConfig.Init()
    if not StandoffStateConfig._.isInit then
        local ftkey = Global.tracing.open("StandoffStateConfig Setup")

        initAndValidate()

        StandoffStateConfig._.isInit = true
        Global.tracing.close(ftkey)
    end
end

---------------- Config Management --------------------

---@return boolean isEnabled
function StandoffStateConfig.IsEnabled()
    return getConfigSection().enabled == true
end

---@param enable boolean
function StandoffStateConfig.SetEnabled(enable)
    getConfigSection().enabled = enable == true
    Global.configStore:SaveConfig()
    print("StandoffState is Enabled: [" .. tostring(enable) .. "]")
end

---@diagnostic disable-next-line: duplicate-set-field
function StandoffStateConfig.Print()
    TableUtils.Print(getConfigSection())
end

return StandoffStateConfig
