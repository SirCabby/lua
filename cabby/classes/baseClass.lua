local Debug = require("utils.Debug.Debug")

local FleeState = require("cabby.states.fleeState")
local FollowState = require("cabby.states.followState")
local MeleeState = require("cabby.states.meleeState")
local Priorities = require("cabby.classes.priorities")
local RestState = require("cabby.states.restState")

---One entry in a class profile: a state singleton and where it sits in the priority chain.
---@class ClassStateEntry
---@field state BaseState
---@field priority integer see `cabby.classes.priorities`; bigger is weaker

---What a class *is*, as data rather than as imperative Init code.
---@class ClassProfile
---@field key string the class name, e.g. "Warrior"
---@field shortName string the EQ short name the client reports, e.g. "WAR"
---@field states? ClassStateEntry[] what this class runs on top of the common states
---@field unimplemented? string[] what this class can do that cabby cannot do for it yet

---@class BaseClass
---@field key string
---@field shortName string
---@field Init fun(stateMachine: StateMachine)
---@field GetStates fun(): ClassStateEntry[] the assembled chain, strongest first
---@field GetUnimplemented fun(): string[]
local BaseClass = { key = "BaseClass" }

---The states every class registers, whatever it is.
---
---Four jobs have nothing to do with what the character can do, so no class should have to
---remember to ask for them. Following is the first -- a wizard follows the same way a warrior
---does; and FollowState is also the anchor and click-to-zone state, all three at the follow band
---because they are one state and one `Go()`. Resting is the second: sitting to get health, mana
---and stamina back is worth doing for every class that has any of them, and the state reads which
---of those this character actually has rather than being told.
---
---Fleeing is the third, and it is here for the same reason and one more: it is not a job at all but
---the *absence* of every job below it, so what it holds back is the same list whatever the
---character is. It sits at the passive band, above everything except an order given to this
---character, and it is the one state handed the state machine at Init, because holding the chain
---back is a gate and a gate has to be registered with the machine that consults it.
---
---Meleeing is the fourth, and it is the one whose band has to be argued for. Anyone can swing a
---weapon, so everyone gets the state -- but at `dps + 5`, one step weaker than the `dps` band the
---melee classes declare it at themselves. The gap is what keeps a caster's chain honest: the
---melee state reports busy for as long as it is engaged, so everything below it is starved for
---the whole fight, and a spell rotation sitting at `dps - 1` has to stay above it. At `dps + 5` a
---caster casts when it can and swings with the frames the rotation passes on, which is the right
---way round; at `dps` it would be a wizard that fights like a warrior.
---
---Registering it is not the same as doing it. `MeleeStateConfig` is alone among the state configs
---in never defaulting `enabled`, so the state stays off until it is switched on -- what a caster
---gains here is the option and the Melee State page, not a new habit.
---
---A class that wants one of these somewhere else in its chain declares it itself: a profile
---entry naming the same state wins over the common one, priority and all. That is exactly how the
---melee classes keep their melee at `dps`.
---@return ClassStateEntry[]
local function CommonStates()
    return {
        -- first of all, deliberately: travel mode is nothing but taking the frame away from the
        -- states under it, so it has to be above them
        { state = FleeState, priority = Priorities.passive },
        { state = MeleeState, priority = Priorities.dps + 5 },
        { state = FollowState, priority = Priorities.follow },
        -- last of all, deliberately: resting is what a character does with the frames nothing
        -- else wants, and everything above it gets first refusal every pass
        { state = RestState, priority = Priorities.misc }
    }
end

---"FollowState" -> "Follow", matching what /state and the menu call it
---@param state BaseState
---@return string
local function StateName(state)
    local key = tostring(state.key)
    if key:sub(-5) == "State" and #key > 5 then
        return key:sub(1, -6)
    end
    return key
end

---@param profile ClassProfile
---@param entry any
---@param index integer
local function ValidateEntry(profile, entry, index)
    local where = profile.key .. " profile, states[" .. tostring(index) .. "]"
    if type(entry) ~= "table" then
        error(where .. " is not a table")
    end
    if type(entry.state) ~= "table" or entry.state.Go == nil then
        error(where .. " does not name a state")
    end
    if type(entry.priority) ~= "number" then
        error(where .. " (" .. StateName(entry.state) .. ") has no priority; use a band from cabby.classes.priorities")
    end
end

---Merge the class's own states with the common ones and sort them into the order the state
---machine will walk them in.
---@param profile ClassProfile
---@return ClassStateEntry[]
local function BuildChain(profile)
    local chain = {}
    local declared = {}

    local function add(entry)
        declared[entry.state] = true
        -- table.sort is not stable, so carry the declaration order as the tie-break: two states
        -- sharing a band stay in the order they were written in
        chain[#chain+1] = { state = entry.state, priority = entry.priority, order = #chain + 1 }
    end

    for index, entry in ipairs(profile.states or {}) do
        ValidateEntry(profile, entry, index)
        add(entry)
    end

    for _, entry in ipairs(CommonStates()) do
        if not declared[entry.state] then
            add(entry)
        end
    end

    table.sort(chain, function(a, b)
        if a.priority == b.priority then
            return a.order < b.order
        end
        return a.priority < b.priority
    end)

    return chain
end

---Say what this character will and will not do, at startup, once.
---
---Every class has a module now, so a class cabby cannot really play no longer announces itself
---by crashing on `class.Init`. It has to say so instead: a shell that quietly follows the group
---around and never casts is worse than a loud failure, not better.
---@param profile ClassProfile
---@param chain ClassStateEntry[]
local function Announce(profile, chain)
    local names = {}
    for _, entry in ipairs(chain) do
        names[#names+1] = StateName(entry.state)
    end
    print("Cabby " .. profile.key .. ": " .. table.concat(names, ", "))

    local unimplemented = profile.unimplemented or {}
    if #unimplemented > 0 then
        print("Cabby " .. profile.key .. " cannot do these yet:")
        for _, line in ipairs(unimplemented) do
            print("  -- " .. line)
        end
    end
end

---Build a class module out of a profile.
---
---The returned table is what `cabby.setup` calls `Init(stateMachine)` on. Init walks the
---assembled chain in priority order, initializing each state and registering it -- which is
---all any class ever did by hand, minus the chance of registering two states in the wrong
---order.
---@param profile ClassProfile
---@return BaseClass
function BaseClass.new(profile)
    if type(profile) ~= "table" then error("BaseClass.new needs a class profile") end
    if type(profile.key) ~= "string" or profile.key == "" then error("class profile has no key") end
    if type(profile.shortName) ~= "string" or profile.shortName == "" then
        error(profile.key .. " profile has no shortName")
    end

    local chain = BuildChain(profile)
    local isInit = false

    ---@type BaseClass
    local class = {
        key = profile.key,
        shortName = profile.shortName
    }

    ---@param stateMachine StateMachine
    class.Init = function(stateMachine)
        if isInit then return end
        if stateMachine == nil then error(profile.key .. ".Init needs the state machine") end

        for _, entry in ipairs(chain) do
            Debug.Log(BaseClass.key, "Registering " .. StateName(entry.state) .. " at priority " .. tostring(entry.priority))
            -- a state has to know its own band to ask anything that arbitrates by priority for
            -- something -- a cast, above all -- and only the profile knows what that band is
            entry.state.priority = entry.priority
            -- the state machine goes to any state that asks for it. Only flee does, and only
            -- because what it does is hold the rest of the chain back -- which is a gate, and a
            -- gate has to be registered with the machine that consults it
            entry.state.Init(stateMachine)
            -- the priority goes to the state machine as well as deciding the order here: a
            -- priority gate (casting, so far) needs to know what it is starving
            stateMachine:Register(entry.state, entry.priority)
        end

        Announce(profile, chain)
        isInit = true
    end

    class.GetStates = function() return chain end

    class.GetUnimplemented = function() return profile.unimplemented or {} end

    return class
end

return BaseClass
