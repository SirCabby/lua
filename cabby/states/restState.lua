---@diagnostic disable: undefined-field
local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local Time = require("utils.Time.Time")

local ChelpDocs = require("cabby.commands.chelpDocs")
local Combat = require("cabby.combat")
local CommandQueue = require("cabby.commandQueue")
local Commands = require("cabby.commands.commands")
local Menu = require("cabby.ui.menu")
local RestStateConfig = require("cabby.configs.restStateConfig")
local RestStateMenu = require("cabby.ui.states.restStateMenu")
local SlashCmd = require("cabby.commands.slashcmd")
local Status = require("cabby.status")
local ToggleCommand = require("cabby.commands.toggleCommand")

---How long the character has to have been standing still before sitting down is worth it. A group
---that stops for a moment mid-run is not a rest, and sitting for it buys a stand-up on the next
---step and nothing else. It decides when an answer is worth acting on rather than how long to
---keep trying, which is what separates it from a give-up timer.
local settleMs = 2000

---How long to leave a posture command before sending it again. Sitting and standing take effect
---when the server says so, and repeating the command forty times a second in the meantime does
---nothing but spam.
local commandRetryMs = 1000

---Getting the pools back up, at the bottom of the chain.
---
---The job is one sentence -- sit while something is short, stand once nothing is -- and the whole
---design is *where* it sits rather than what it does. At the misc band it is the last thing asked,
---so it runs on exactly the frames nobody else wants: parked on an anchor, caught up behind
---whoever we follow, or standing around after a fight. Every state above it that has something to
---do takes the frame first, and the services stand the character up on their own when they need it
---(movement out of a sit, the casting service before a cast), so this state never has to argue for
---the character back.
---
---**Nothing is remembered about having sat down.** "Should I be sitting right now" is asked from
---the world every pass and answers both directions: sitting down when the answer turns yes, and
---standing up when it turns no -- because the pools came back, because a fight started, or because
---a cast is going out. That is also why it stands up out of a sit somebody else chose: there is no
---such thing here as *whose* sit it is, only whether sitting is right.
---
---What holds it back, in the order it reports them: being engaged (a character in a fight has a
---fight to be in), a cast in the air, and -- while the client says the fight is on and we are not
---in it -- the `in_combat` setting, plus melee being on. That last pair is the case worth naming:
---a caster that has not engaged would rather fill its bar than start something, and a character
---that walks into melee is a character that is about to be on its feet anyway.
---@class RestState : BaseState
local RestState = {
    key = "RestState",
    eventIds = {
        -- no registered phrase may be a prefix of another, and neither of these is one of the
        -- other: `resting` would fire on `restingcombat`, which is why the second is not called it
        resting = "resting",
        restCombat = "restcombat"
    },
    _ = {
        isInit = false,
        -- nil means "not seen moving", so a character that was already parked when the script
        -- started sits down on the first pass instead of paying the settle window for nothing
        lastMovingMs = nil,
        lastCommandMs = 0,
        isResting = false,
        holdReason = nil
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(RestState.key, str)
end

---------------- What we are waiting on --------------------

---@class RestPool
---@field key string
---@field label string
---@field pct number

---The pools worth sitting for, as they read right now.
---
---A class with no mana bar has no mana to wait on, and that is `MaxMana` of zero rather than a
---percentage of zero -- read the other way round, a warrior would sit forever waiting for mana it
---will never have.
---@return RestPool[] pools
function RestState.GetPools()
    local pools = {}

    ---@param key string
    ---@param label string
    ---@param pct number|nil
    ---@param max number|nil nil for a pool everybody has
    local function add(key, label, pct, max)
        if max ~= nil and max <= 0 then return end
        if pct == nil then return end
        pools[#pools+1] = { key = key, label = label, pct = pct }
    end

    add("health", "health", tonumber(mq.TLO.Me.PctHPs()))
    add("mana", "mana", tonumber(mq.TLO.Me.PctMana()), tonumber(mq.TLO.Me.MaxMana()) or 0)
    add("endurance", "stamina", tonumber(mq.TLO.Me.PctEndurance()), tonumber(mq.TLO.Me.MaxEndurance()) or 0)

    return pools
end

---@param pools RestPool[]
---@return RestPool|nil lowest the pool furthest from full, nil when none can be read
local function lowest(pools)
    local worst = nil
    for _, pool in ipairs(pools) do
        if worst == nil or pool.pct < worst.pct then
            worst = pool
        end
    end
    return worst
end

---@param pools RestPool[]
---@return boolean needsRest whether anything is low enough to sit down for
local function needsRest(pools)
    local sitBelow = RestStateConfig.GetSitBelowPct()
    for _, pool in ipairs(pools) do
        if pool.pct < sitBelow then return true end
    end
    return false
end

---@param pools RestPool[]
---@return boolean isRested whether everything has come back far enough to get up
local function isRested(pools)
    local standAt = RestStateConfig.GetStandAtPct()
    for _, pool in ipairs(pools) do
        if pool.pct < standAt then return false end
    end
    return true
end

---Reasons not to be sitting, in the order they are worth reporting.
---
---Asked once and read both ways: the same answer that stops us sitting down is what gets us up
---again, which is what keeps "should I be sitting" one question rather than two that can disagree.
---@return string|nil reason in words, nil when sitting is allowed
local function holdReason()
    if Combat.IsEngaged() then
        return "we are fighting something"
    end

    -- a cast we did not start, or one from a state that has been starving us since it began: either
    -- way, sitting down is not what the character should be doing with it in the air
    if mq.TLO.Me.Casting() ~= nil then
        return "a cast is going out"
    end

    if mq.TLO.Me.CombatState() == "COMBAT" then
        if not RestStateConfig.GetInCombat() then
            return "the fight is still on"
        end

        -- melee is about to want this character on its feet and inside the mob's reach, and a
        -- character sitting there is one taking full hits while it gets up
        if Status.IsMeleeEnabled() then
            return "the fight is on and melee is turned on"
        end
    end

    return nil
end

---Postures this state will not touch, in the words worth reporting them in.
local postureWords = {
    FEIGN = "feigning",
    DUCK = "ducking",
    MOUNT = "mounted",
    HOVER = "dead and not released",
    DEAD = "dead",
    BIND = "binding"
}

---------------- Posture --------------------

---@param now number
---@return boolean isBusy
local function sitDown(now)
    -- the command is throttled, the decision is not: we have decided to sit, so the frame ends
    -- here either way rather than letting something weaker start while we are getting down
    if now - RestState._.lastCommandMs < commandRetryMs then return true end
    RestState._.lastCommandMs = now

    DebugLog("Sitting down to rest")
    -- `/sit on` rather than `/sit`, which toggles: asked again while the server catches up, a
    -- toggle would stand us straight back up
    mq.cmd("/sit on")
    return true
end

---@param now number
---@param why string
---@return boolean isBusy
local function standUp(now, why)
    if now - RestState._.lastCommandMs < commandRetryMs then return true end
    RestState._.lastCommandMs = now

    DebugLog("Standing up: " .. why)
    mq.cmd("/stand")
    return true
end

---------------- Status --------------------

---@return string description of what this state is doing, for the page and /state
function RestState.Describe()
    if RestState._.isResting then
        local worst = lowest(RestState.GetPools())
        if worst == nil then return "resting" end
        return "resting (" .. worst.label .. " " .. tostring(math.floor(worst.pct)) .. "%)"
    end

    if RestState._.holdReason ~= nil then
        return "holding: " .. RestState._.holdReason
    end

    return "standing by"
end

---@return boolean isResting whether the character is sitting and this state wants it to stay that
---way, as of the last pass
function RestState.IsResting()
    return RestState._.isResting
end

---@return string|nil reason why it is not sitting, in words
function RestState.GetHoldReason()
    return RestState._.holdReason
end

---------------- Init --------------------

---@diagnostic disable-next-line: duplicate-set-field
function RestState.Init()
    if RestState._.isInit then return end

    RestStateConfig.Init()

    Menu.RegisterState(RestState)

    ToggleCommand.Register({
        key = RestState.key,
        phrase = RestState.eventIds.resting,
        summary = "Turns sitting to get health, mana and stamina back on or off",
        about = {
            "Off stands the character back up if it was resting, rather than leaving it parked",
            "on the ground."
        },
        get = RestStateConfig.IsEnabled,
        set = RestState.SetEnabled
    })

    ToggleCommand.Register({
        key = RestState.key,
        phrase = RestState.eventIds.restCombat,
        summary = "Turns resting during a fight on or off",
        about = {
            "Only ever covers a fight this character has not joined: being engaged stops it",
            "resting whatever this is set to, and so does having melee turned on."
        },
        get = RestStateConfig.GetInCombat,
        set = RestStateConfig.SetInCombat
    })

    local crestDocs = ChelpDocs.new(function() return {
        "(/crest) Report whether this character is resting, and what it is waiting on",
        " -- Usage: /crest"
    } end )
    local function Bind_CRest(...)
        local args = {...} or {}

        if #args > 0 and args[1]:lower() == "help" then
            crestDocs:Print()
            return
        end

        print("Rest: " .. RestState.Describe() .. (RestState.IsEnabled() and "" or " (disabled)"))
        print(" -- sits below " .. tostring(RestStateConfig.GetSitBelowPct()) .. "%, stands at " ..
            tostring(RestStateConfig.GetStandAtPct()) .. "%" ..
            (RestStateConfig.GetInCombat() and ", during a fight as well" or ", never during a fight"))
        for _, pool in ipairs(RestState.GetPools()) do
            print(" -- " .. pool.label .. ": " .. tostring(math.floor(pool.pct)) .. "%")
        end
    end
    Commands.RegisterSlashCommand(SlashCmd.new("crest", Bind_CRest, crestDocs))

    RestState.Reset()
    RestState._.isInit = true
end

function RestState.Reset()
    RestState._.lastMovingMs = nil
    RestState._.lastCommandMs = 0
    RestState._.isResting = false
    RestState._.holdReason = nil
end

---One pass: read what is short, read what is in the way, and put the character in the posture
---those two answer for.
---@return boolean isBusy
---@diagnostic disable-next-line: duplicate-set-field
function RestState.Go()
    local now = Time.current_time()
    if mq.TLO.Me.Moving() then
        RestState._.lastMovingMs = now
    end

    local posture = tostring(mq.TLO.Me.State() or "")
    local hold = holdReason()
    RestState._.holdReason = hold
    local pools = RestState.GetPools()

    if posture == "SIT" then
        if hold == nil and not isRested(pools) then
            RestState._.isResting = true
            -- filling up is what this character is doing right now, so the pass ends here. The
            -- next one starts at the top of the chain, which is what makes holding it safe
            return true
        end

        RestState._.isResting = false
        return standUp(now, hold or "rested")
    end

    RestState._.isResting = false

    -- Only a character on its feet is ours to sit down. Feigning, mounted, hovering dead, bound,
    -- ducking: each of those is somebody else's doing, and a posture we did not choose is not one
    -- to take away from them.
    if posture ~= "STAND" then
        RestState._.holdReason = hold or ("we are " .. (postureWords[posture] or posture:lower()))
        return false
    end

    if hold ~= nil then return false end
    if not needsRest(pools) then return false end

    -- the group stopping for a moment mid-run is not a rest
    if RestState._.lastMovingMs ~= nil and now - RestState._.lastMovingMs < settleMs then
        RestState._.holdReason = "we have only just stopped"
        return false
    end

    return sitDown(now)
end

---@return boolean isEnabled
---@diagnostic disable-next-line: duplicate-set-field
RestState.IsEnabled = function()
    return RestStateConfig.IsEnabled()
end

---Switching it off stops it deciding anything, and stands the character up if it is sitting on
---this state's account -- a bot left parked on the ground by a switch is a bot that looks broken.
---The stand goes through the command queue rather than being run here: this is also what a menu
---checkbox calls, and running a game command from inside a render callback is the crash hazard
---the movement service is built around.
---@diagnostic disable-next-line: duplicate-set-field
RestState.SetEnabled = function(isEnabled)
    local wasResting = RestState._.isResting
    RestStateConfig.SetEnabled(isEnabled)

    if not isEnabled then
        RestState.Reset()
        if wasResting and mq.TLO.Me.State() == "SIT" then
            CommandQueue.Push("/stand")
        end
    end
end

---@diagnostic disable-next-line: duplicate-set-field
function RestState.BuildMenu()
    RestStateMenu.BuildMenu(RestState)
end

return RestState
