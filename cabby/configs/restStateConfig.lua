local Debug = require("utils.Debug.Debug")
local TableUtils = require("utils.TableUtils.TableUtils")

---When this character sits down to get its pools back, and when it gets up again.
---
---Two numbers for the sit itself. "Sit until full" is both of them at 100 -- sit whenever something
---is short, get up when nothing is -- but the pair is what lets a character stop waiting out the
---last few percent of a bar it does not need, and the gap between them is room to say "sit for
---anything under 80, and once you are down there you may as well fill up".
---
---The one combination that cannot be allowed is standing at less than we sit at: it would sit
---down, read itself as rested on the very next pass, stand back up, and do it again forty times a
---second. The setters keep the pair in order rather than the state having to check.
---
---**A third number decides when sitting is worth starting *again*, and it is a different question
---from the first.** A bar does not read steadily at the top of its range: a server tick can show
---health a point or two above where it really is and the next one puts it back. With only the pair
---above, a character that stands at 100 reads 98 a moment later, sits for it, reads 100 again and
---stands -- a sit and a stand per tick, over a percent that was never really lost. `resume_below_pct`
---is the far edge of a band the pools have to genuinely fall out of before sitting is worth it
---again: reaching `stand_at_pct` latches the character *topped up*, and only a pool below this
---un-latches it. 97 by default, so the wobble at the top of the bar is inside the band and a real
---loss is not.
---
---Never above `stand_at_pct`, which would un-latch on the same reading that stood the character up
---and leave no band at all. Set to the same number it is off, which is the behaviour that predates
---it.
---@class RestStateConfig : BaseConfig
local RestStateConfig = {
    key = "RestState",
    _ = {
        isInit = false
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(RestStateConfig.key, str)
end

local function getConfigSection()
    return Global.configStore:GetConfigRoot()[RestStateConfig.key]
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
        DebugLog("RestStateConfig Section was not set, updating...")
        Global.configStore:GetConfigRoot()[RestStateConfig.key] = {}
        taint = true
    end

    local configRoot = getConfigSection()

    if configRoot.enabled == nil then
        configRoot.enabled = true
        taint = true
    end

    if configRoot.sit_below_pct == nil then
        -- anything short of full is worth sitting for: standing up costs nothing, and a bar that
        -- is nearly full is the one that fills fastest
        configRoot.sit_below_pct = 100
        taint = true
    end

    if configRoot.stand_at_pct == nil then
        configRoot.stand_at_pct = 100
        taint = true
    end

    if configRoot.resume_below_pct == nil then
        -- a hair under full: enough of a band to swallow a tick that reads high, small enough that
        -- health actually lost is still worth sitting down for
        configRoot.resume_below_pct = 97
        taint = true
    end

    if configRoot.in_combat == nil then
        -- on: a character that has not engaged anything has nothing else to be doing with the
        -- fight, and the state holds itself back the moment that stops being true
        configRoot.in_combat = true
        taint = true
    end

    -- a config edited by hand can hold the one pair that oscillates; fix it here rather than
    -- letting the state read it
    if configRoot.stand_at_pct < configRoot.sit_below_pct then
        configRoot.stand_at_pct = configRoot.sit_below_pct
        taint = true
    end

    -- and the resume point above the stand point is the same fault one step along: the reading
    -- that stands the character up would un-latch it in the same breath
    if configRoot.resume_below_pct > configRoot.stand_at_pct then
        configRoot.resume_below_pct = configRoot.stand_at_pct
        taint = true
    end

    if taint then
        Global.configStore:SaveConfig()
    end
end

---@diagnostic disable-next-line: duplicate-set-field
function RestStateConfig.Init()
    if not RestStateConfig._.isInit then
        local ftkey = Global.tracing.open("RestStateConfig Setup")

        initAndValidate()

        RestStateConfig._.isInit = true
        Global.tracing.close(ftkey)
    end
end

---------------- Config Management --------------------

---@return boolean isEnabled
function RestStateConfig.IsEnabled()
    return getConfigSection().enabled == true
end

---@param enable boolean
function RestStateConfig.SetEnabled(enable)
    getConfigSection().enabled = enable == true
    Global.configStore:SaveConfig()
    print("RestState is Enabled: [" .. tostring(enable) .. "]")
end

---@return number pct sit down when any pool this character has is below this
function RestStateConfig.GetSitBelowPct()
    return getConfigSection().sit_below_pct
end

---@param pct number
function RestStateConfig.SetSitBelowPct(pct)
    local configRoot = getConfigSection()
    configRoot.sit_below_pct = clamp(pct, 1, 100)
    if configRoot.stand_at_pct < configRoot.sit_below_pct then
        configRoot.stand_at_pct = configRoot.sit_below_pct
    end
    Global.configStore:SaveConfig()
end

---@return number pct get up once every pool is at or above this
function RestStateConfig.GetStandAtPct()
    return getConfigSection().stand_at_pct
end

---@param pct number
function RestStateConfig.SetStandAtPct(pct)
    local configRoot = getConfigSection()
    configRoot.stand_at_pct = clamp(pct, configRoot.sit_below_pct, 100)
    if configRoot.resume_below_pct > configRoot.stand_at_pct then
        configRoot.resume_below_pct = configRoot.stand_at_pct
    end
    Global.configStore:SaveConfig()
end

---Where sitting becomes worth doing again after the character has been stood up for being full.
---
---Reaching `stand_at_pct` latches it *topped up* and nothing sits it back down until a pool reads
---below this, so the band between the two is the room a bar has to wobble in without buying a
---posture change. See the note at the top of this file for why that band has to exist at all.
---@return number pct sit again once a pool this character has is below this
function RestStateConfig.GetResumeBelowPct()
    local configRoot = getConfigSection()
    return math.min(configRoot.resume_below_pct, configRoot.stand_at_pct)
end

---@param pct number
function RestStateConfig.SetResumeBelowPct(pct)
    local configRoot = getConfigSection()
    configRoot.resume_below_pct = clamp(pct, 1, configRoot.stand_at_pct)
    Global.configStore:SaveConfig()
end

---Whether sitting is allowed while the client says we are in a fight. It never covers a fight
---*this* character is in -- being engaged holds the state back whatever this says.
---@return boolean inCombat
function RestStateConfig.GetInCombat()
    return getConfigSection().in_combat == true
end

---@param enable boolean
function RestStateConfig.SetInCombat(enable)
    getConfigSection().in_combat = enable == true
    Global.configStore:SaveConfig()
    print("RestState rests during a fight: [" .. tostring(enable) .. "]")
end

---@diagnostic disable-next-line: duplicate-set-field
function RestStateConfig.Print()
    TableUtils.Print(getConfigSection())
end

return RestStateConfig
