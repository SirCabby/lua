---@diagnostic disable: undefined-field
local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local Movement = require("utils.Movement.Movement")
local Time = require("utils.Time.Time")

local ChelpDocs = require("cabby.commands.chelpDocs")
local Combat = require("cabby.combat")
local CommandQueue = require("cabby.commandQueue")
local Commands = require("cabby.commands.commands")
local Menu = require("cabby.ui.menu")
local RestStateConfig = require("cabby.configs.restStateConfig")
local RestStateMenu = require("cabby.ui.states.restStateMenu")
local SlashCmd = require("cabby.commands.slashcmd")
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

---How long a posture command of ours stays credited to us. The server answers a `/sit` or a
---`/stand` inside a ping; one that has not shown up by now did not take, and holding on to it any
---longer means crediting this state with the next posture change the *person playing* makes.
local commandAckMs = 2000

---How long a stand this state did not order holds it off sitting down again. Something else put
---the character on its feet -- the person playing it, or a service that needed it standing to cast
---or to move -- and answering that with a `/sit` on the next frame is how a script ends up
---wrestling its owner. It is a debounce and not a give-up: nothing stops being tried, it just
---stops being answered instantly.
local standGraceMs = 5000

---How long the reason we got up has to have stayed gone before sitting back down is worth it.
---
---The grace above covers a stand somebody else ordered; this covers the ones this state orders
---itself. Without it there is no hysteresis in that direction at all: the command throttle is the
---only thing in the way, so a hold that comes and goes is answered with a `/stand` and a `/sit` a
---second apart, over and over, for as long as it keeps flickering. Which reason it was does not
---matter -- any of them is read from the world afresh each pass and so any of them can blink, and
---none of them is worth a posture change that lasts a second.
---A debounce and not a give-up, like the rest of the windows in here: resting resumes on its own
---once the reason has actually stayed away.
local holdSettleMs = 5000

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
---**"Should I be sitting right now" is asked from the world every pass**, and answers both
---directions: sitting down when the answer turns yes, and standing up when it turns no -- because
---the pools came back, because a fight started, or because a cast is going out.
---
---**The one thing it remembers is whose sit this is**, because it is the one thing the world will
---not tell it. A sit this state did not sit down belongs to somebody else and is left alone: the
---reason for it is not readable from here, and the commonest reason -- the spellbook open on a
---spell being memorized -- is one that standing up destroys. The same courtesy runs the other way,
---so a stand this state did not order buys a moment's grace before it sits back down. Answering
---the person playing the character on the very next frame is wrestling, not resting.
---
---What holds it back, in the order it reports them: a sit that is not ours, an open spellbook,
---having only just been stood up, being engaged (a character in a fight has a fight to be in), a
---cast in the air, the movement service driving, and -- while the client says the fight is on and
---we are not in it -- the `in_combat` setting. That last one is the case worth naming: a caster
---that has not engaged would rather fill its bar than start something, which is why it is a
---setting rather than a rule.
---
---Movement is the one to read twice, because a *parked* task is not a hold. A follow order stands
---for as long as the group is together, and if that counted as being moved this state would never
---sit down at all while anyone was following anybody -- which is most of the time, and the whole
---case it was written for.
---
---**Both directions are debounced**, and they have to be. Every one of those reasons is read from
---the world afresh each pass, so any of them can blink -- and a posture change is the most
---expensive answer there is to a question whose answer changes back a second later.
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
        -- "sit" or "stand": which of the two we sent last, so a posture that turns up can be told
        -- apart from one somebody else asked for
        lastCommandKind = nil,
        lastPosture = nil,
        sitIsOurs = false,
        lastStandNotOursMs = nil,
        -- when something last held us off sitting, so a reason that flickers cannot be answered
        -- with a posture change per flicker. nil means "nothing has held us back yet"
        lastHoldMs = nil,
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

    -- The movement service is driving. A `/sit` under a move is answered with a `/stand` on the
    -- service's next pulse, which is an argument this state cannot win and should not be having --
    -- and the frames it happens on are exactly the ones it gets, because a follow hands the frame
    -- back the moment it is nearly caught up while the task is still closing the last few units.
    -- A task that is *parked* is not driving, and is precisely when resting is the right answer.
    if Movement.IsActive() and not Movement.IsParked() then
        return "we are being moved"
    end

    -- The client's own combat flag, which is a fight *somewhere* rather than a fight we are in --
    -- the one above is the fight we are in. `in_combat` is the user's answer to whether that is
    -- worth staying on our feet for, and it is the only thing that reads it: this used to stand up
    -- as well whenever melee happened to be switched on, which quietly overrode that setting for
    -- every character with a melee page. It bought nothing either -- the melee state does not act
    -- on anything but an engagement, and an engagement is the hold above -- and it cost a `/stand`
    -- every time the flag came on and a `/sit` every time it went off again.
    if mq.TLO.Me.CombatState() == "COMBAT" and not RestStateConfig.GetInCombat() then
        return "the fight is still on"
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

---Whether the spellbook is open, which is somebody in the middle of something that needs them
---sitting. Standing closes it and throws away the memorize going on inside it, which is the whole
---reason this state asks.
---@return boolean isOpen
local function spellbookIsOpen()
    return mq.TLO.Window("SpellBookWnd").Open() == true
end

---@param now number
---@param kind string "sit" or "stand"
---@return boolean isOutstanding whether a command of that kind is still waiting on the server
local function isOutstanding(now, kind)
    return RestState._.lastCommandKind == kind and now - RestState._.lastCommandMs < commandAckMs
end

---Work out whose posture this is.
---
---There is no TLO for "the user pressed the sit key", so ownership is inferred from what we asked
---for: a sit that turns up while our own `/sit` is outstanding is ours, and every other one is
---not. Ownership is remembered, but it is confirmed against the world every pass -- the moment the
---character is not sitting, the sit is not ours any more -- so it cannot go stale in the way a
---remembered *mode* would.
---@param now number
---@param posture string
local function observePosture(now, posture)
    if posture == "SIT" then
        if not RestState._.sitIsOurs and isOutstanding(now, "sit") then
            DebugLog("The sit that just landed is ours")
            RestState._.sitIsOurs = true
        end
    else
        -- Getting up is only ours if we asked for it. Anything else -- somebody standing by hand,
        -- the movement service getting under way, the casting service standing up to cast -- ends
        -- the rest and buys the grace window before we sit down again.
        if RestState._.lastPosture == "SIT" and not isOutstanding(now, "stand") then
            DebugLog("Stood up by something that was not us")
            RestState._.lastStandNotOursMs = now
        end
        RestState._.sitIsOurs = false
    end

    RestState._.lastPosture = posture
end

---@param now number
---@return boolean isBusy
local function sitDown(now)
    -- the command is throttled, the decision is not: we have decided to sit, so the frame ends
    -- here either way rather than letting something weaker start while we are getting down
    if now - RestState._.lastCommandMs < commandRetryMs then return true end
    RestState._.lastCommandMs = now
    RestState._.lastCommandKind = "sit"

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
    RestState._.lastCommandKind = "stand"

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
            "resting whatever this is set to."
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
    RestState._.lastCommandKind = nil
    RestState._.lastPosture = nil
    RestState._.sitIsOurs = false
    RestState._.lastStandNotOursMs = nil
    RestState._.lastHoldMs = nil
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
    observePosture(now, posture)

    local hold = holdReason()
    RestState._.holdReason = hold
    if hold ~= nil then RestState._.lastHoldMs = now end
    local pools = RestState.GetPools()

    if posture == "SIT" then
        RestState._.isResting = false

        -- A sit we did not sit down is not ours to end. Somebody sat for a reason, and which
        -- reason is not something this state can read, so it stays out of the way rather than
        -- guessing. Standing up is what this state would have to do to disagree, and there is
        -- nothing it wants the character on its feet for that is worth taking a decision off the
        -- person playing it.
        if not RestState._.sitIsOurs then
            RestState._.holdReason = "you sat down yourself"
            return false
        end

        -- Ours or not, standing closes the spellbook and loses the spell being memorized with it.
        -- Everything that genuinely needs the character upright -- casting, movement, melee --
        -- stands it up itself; this state only ever stands it up because sitting has stopped being
        -- worthwhile, which never justifies that.
        if spellbookIsOpen() then
            RestState._.holdReason = "your spellbook is open"
            return false
        end

        if hold == nil and not isRested(pools) then
            RestState._.isResting = true
            -- filling up is what this character is doing right now, so the pass ends here. The
            -- next one starts at the top of the chain, which is what makes holding it safe
            return true
        end

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

    -- Whatever got us up has to have stayed gone. A reason read from the world can blink -- the
    -- client's combat flag around a fight we are standing next to is the one that started this --
    -- and sitting the moment it clears is how a `/stand` and a `/sit` end up a second apart for
    -- as long as the flicker lasts.
    if RestState._.lastHoldMs ~= nil then
        if now - RestState._.lastHoldMs < holdSettleMs then
            RestState._.holdReason = "the reason we got up has only just gone"
            return false
        end
        RestState._.lastHoldMs = nil
    end

    -- Somebody put this character on its feet. Whoever it was had a reason -- and if the reason
    -- was "I want to be standing", sitting them straight back down is an argument they cannot win
    -- and we cannot hear. Wait it out; resting resumes on its own if nothing else happens.
    if RestState._.lastStandNotOursMs ~= nil then
        if now - RestState._.lastStandNotOursMs < standGraceMs then
            RestState._.holdReason = "we were only just stood up"
            return false
        end
        RestState._.lastStandNotOursMs = nil
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
            -- the queue runs it a frame or two from now, and the pass that sees it land has to
            -- know the stand was ours -- otherwise switching resting off and back on again pays
            -- the grace window meant for somebody else's stand
            RestState._.lastCommandMs = Time.current_time()
            RestState._.lastCommandKind = "stand"
        end
    end
end

---@diagnostic disable-next-line: duplicate-set-field
function RestState.BuildMenu()
    RestStateMenu.BuildMenu(RestState)
end

return RestState
