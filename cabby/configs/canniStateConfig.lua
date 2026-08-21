local Debug = require("utils.Debug.Debug")
local TableUtils = require("utils.TableUtils.TableUtils")

local ActionType = require("cabby.actions.actionType")

---What this character trades health for mana with, and the two numbers it is kept between.
---
---The list is the same shape as every other action list -- tried in order, first one ready wins --
---and holds the whole family without knowing they are a family: a shaman's cannibalize line and
---its AA, the modulation rods a magician summons, a manastone, a necromancer's Death Bloom. They
---are one job because the trade is one trade, and which of them a character owns is read from the
---client rather than declared here.
---
---**The numbers bound it from both ends.** Below `min_hp_pct` there is no health to spend, and
---above `max_mana_pct` there is nothing worth spending it on -- so the job runs in the band between
---them and stops on its own at either edge. That is what makes a state this far up the chain safe:
---it cannot starve the rotation below it for longer than it takes to fill the bar.
---
---**The health end is two numbers rather than one, and it has to be.** `min_hp_pct` is where
---trading stops and `resume_hp_pct` is where it starts again, and a single number in their place
---oscillates -- necessarily, because the trade is what moves health across the line it is being
---judged against. One number means: trade to the floor, sit, take one regen tick back over it,
---stand up and trade that tick away, sit again. A tick per stand, and the sitting bonus that makes
---medding worth anything never gets a chance to apply. The gap between the two is what turns that
---into a burst of trading and then a proper rest. `RestStateConfig` carries the same pair for the
---same reason.
---
---**Only the first of the pair is about safety.** `min_hp_pct` is the number that decides whether a
---bad pull kills the character and is asked whatever else is true; the gap above it exists to make a
---*sit* worth sitting through, so the state skips it wherever there is no sit to protect -- in a
---fight, on its feet. There is no setting for that, because there is nothing to choose: waiting out
---a number the character will not reach until the fight is over is not caution, it is mana not taken
---at the moment it is being spent, and the floor is still underneath it either way.
---
---None of them is a give-up timer in disguise. All are re-read from the world every pass, and the
---moment health comes back or mana drops the answer changes with it.
---@class CanniStateConfig : BaseConfig
local CanniStateConfig = {
    key = "CanniState",
    _ = {
        isInit = false
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(CanniStateConfig.key, str)
end

local function getConfigSection()
    return Global.configStore:GetConfigRoot()[CanniStateConfig.key]
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
        DebugLog("CanniStateConfig Section was not set, updating...")
        Global.configStore:GetConfigRoot()[CanniStateConfig.key] = {}
        taint = true
    end

    local configRoot = getConfigSection()

    if configRoot.enabled == nil then
        -- on, like the rest of the state switches and unlike melee's: the list starts empty, so a
        -- character that has nothing configured does nothing at all and the switch costs it
        -- nothing. What it buys is that a shaman which has just been given a canni slot uses it
        configRoot.enabled = true
        taint = true
    end

    if configRoot.min_hp_pct == nil then
        -- Where trading stops, asked before a use rather than after it -- the trade is meant to
        -- hurt, and a floor read as "and where would that leave me" refuses a shaman's own AA at
        -- every setting anybody would pick, since it takes a third of the bar in one click. High
        -- on purpose all the same: this is the number that decides whether a bad pull kills the
        -- character, the mana is worth nothing to a corpse, and being wrong the other way costs a
        -- few seconds of medding. What each use actually costs is on the page beside it, read off
        -- the spell, so this is set by somebody who can see the size of what they are allowing
        configRoot.min_hp_pct = 85
        taint = true
    end

    if configRoot.resume_hp_pct == nil then
        -- Near full, because the whole point of the gap is to be worth sitting through: this is the
        -- number that decides whether the character gets the out-of-combat regen bonus at all, and
        -- a bonus that applies for one tick between two stands is not a bonus. It is deliberately
        -- not 100 -- the last few percent of a health bar are the slowest to come back, and waiting
        -- for them would trade the thrash for a character that meds forever and never cannis again.
        -- Safe to set high, because it is only ever waited out where a rest is actually possible:
        -- standing in a fight the floor is the only line, and this is not consulted at all
        configRoot.resume_hp_pct = 95
        taint = true
    end

    if configRoot.max_mana_pct == nil then
        -- Not "when the bar is empty": a caster that waits until it is out has already stopped
        -- casting, and the whole value of the trade is that it happens in the gaps before that.
        -- Not near full either, which spends health on mana that would have regenerated anyway
        configRoot.max_mana_pct = 70
        taint = true
    end

    if configRoot.in_combat == nil then
        -- On, and this is the case the band was argued for: a fight is when mana is actually being
        -- spent, and a healer that runs dry halfway through one is the failure this job prevents.
        -- Off is for a character whose health is needed for something else -- a tank, or anyone
        -- being hit -- and the floor is the finer answer to the same worry
        configRoot.in_combat = true
        taint = true
    end

    if configRoot.actions == nil then
        configRoot.actions = {}
        taint = true
    end

    -- a config edited by hand can hold the one pair that oscillates, and here it would do worse
    -- than oscillate: the state latches on the way down and unlatches on the way up, so a resume
    -- point *under* the floor is a latch that can never clear. Fixed here rather than left for the
    -- state to read
    if configRoot.resume_hp_pct < configRoot.min_hp_pct then
        configRoot.resume_hp_pct = configRoot.min_hp_pct
        taint = true
    end

    for i = #configRoot.actions, 1, -1 do
        local action = configRoot.actions[i]
        if action.actionType == nil or action.actionType == ActionType.Edit then
            table.remove(configRoot.actions, i)
            taint = true
        end
    end

    if taint then
        Global.configStore:SaveConfig()
    end
end

---@diagnostic disable-next-line: duplicate-set-field
function CanniStateConfig.Init()
    if not CanniStateConfig._.isInit then
        local ftkey = Global.tracing.open("CanniStateConfig Setup")

        initAndValidate()

        CanniStateConfig._.isInit = true
        Global.tracing.close(ftkey)
    end
end

---------------- Config Management --------------------

---@return boolean isEnabled
function CanniStateConfig.IsEnabled()
    return getConfigSection().enabled == true
end

---@param enable boolean
function CanniStateConfig.SetEnabled(enable)
    getConfigSection().enabled = enable == true
    Global.configStore:SaveConfig()
    print("CanniState is Enabled: [" .. tostring(enable) .. "]")
end

---Health to keep. Nothing is traded below it -- which is where trading *stops*, not a cap on what
---one use may cost: a trade takes what it takes, and the page says how much that is for each slot.
---Trading does not start again the moment it is back above this either; see `GetResumeHpPct`.
---@return number pct
function CanniStateConfig.GetMinHpPct()
    return getConfigSection().min_hp_pct
end

---@param pct number
function CanniStateConfig.SetMinHpPct(pct)
    local configRoot = getConfigSection()
    configRoot.min_hp_pct = clamp(pct, 1, 99)
    if configRoot.resume_hp_pct < configRoot.min_hp_pct then
        configRoot.resume_hp_pct = configRoot.min_hp_pct
    end
    Global.configStore:SaveConfig()
end

---Health to come back to before trading starts again, once it has been taken below the floor.
---
---The other half of the floor, and the half that makes sitting worth anything -- which is also why
---the state stops consulting it in a fight it is standing up in, where nothing is sitting and there
---is nothing for it to be worth. Never below the floor, whatever is stored: read that way round the
---latch in the state could never clear, so a hand-edited config is answered here rather than
---wedging the job.
---@return number pct
function CanniStateConfig.GetResumeHpPct()
    local configRoot = getConfigSection()
    return math.max(configRoot.resume_hp_pct, configRoot.min_hp_pct)
end

---@param pct number
function CanniStateConfig.SetResumeHpPct(pct)
    local configRoot = getConfigSection()
    configRoot.resume_hp_pct = clamp(pct, configRoot.min_hp_pct, 100)
    Global.configStore:SaveConfig()
end

---Mana to stop at. Nothing is converted at or above it, which is what ends the job rather than a
---timer or a count.
---@return number pct
function CanniStateConfig.GetMaxManaPct()
    return getConfigSection().max_mana_pct
end

---@param pct number
function CanniStateConfig.SetMaxManaPct(pct)
    getConfigSection().max_mana_pct = clamp(pct, 1, 100)
    Global.configStore:SaveConfig()
end

---Whether to trade during a fight. Read against the *group's* fight rather than our own
---engagement, since the character this matters most to is a healer that never engages anything.
---@return boolean inCombat
function CanniStateConfig.GetInCombat()
    return getConfigSection().in_combat == true
end

---@param inCombat boolean
function CanniStateConfig.SetInCombat(inCombat)
    getConfigSection().in_combat = inCombat == true
    Global.configStore:SaveConfig()
    print("CanniState during a fight is: [" .. tostring(inCombat) .. "]")
end

---@return table actions the list, in the order it is tried
function CanniStateConfig.GetActions()
    return getConfigSection().actions
end

---@return table actionLists in the shape the shared `action` command and the menu both read
function CanniStateConfig.GetActionLists()
    return { { label = "Canni", actions = CanniStateConfig.GetActions() } }
end

---@diagnostic disable-next-line: duplicate-set-field
function CanniStateConfig.Print()
    TableUtils.Print(getConfigSection())
end

return CanniStateConfig
