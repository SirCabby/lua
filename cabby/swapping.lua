---@diagnostic disable: undefined-field
local Debug = require("utils.Debug.Debug")
local StringUtils = require("utils.StringUtils.StringUtils")
local Swapping = require("utils.Swapping.Swapping")

local ChelpDocs = require("cabby.commands.chelpDocs")
local Commands = require("cabby.commands.commands")
local SlashCmd = require("cabby.commands.slashcmd")
local UserInput = require("cabby.utils.userinput")

---Cabby side wiring for the reusable swapping service in `utils/Swapping`.
---
---Callers drive it by requiring `utils.Swapping.Swapping` directly. Two things happen here that
---cannot happen in the service itself:
---
---**It goes on the per-frame pulse**, which is the whole reason wearing something for a moment is
---a service and not four lines inside a state: the gear has to come back off on the frames the
---state that asked for it is starved, and at `buff - 1` the pet state is starved by nearly
---everything.
---
---**What is owed is written into the config file.** The service knows what it has moved and puts
---it back on its own; what it cannot survive is not running -- a `/lua stop`, a crash or a
---reload in the second between a focus item going on and the summon landing would otherwise leave
---the player's own gear in a bag with nothing anywhere that knows where it belongs. So the
---obligation is persisted the moment it exists and picked up again on the next run, and picking it
---up is safe because every restore move is still conditional on the slot holding what we left
---there: a player who has already sorted it out by hand is left alone.
---@class CabbySwapping
local CabbySwapping = {
    key = "Swapping",
    _ = {
        isInit = false
    }
}

---Where the standing obligation is written. Not a setting and nothing anybody edits -- it is one
---record of "these slots are not the way their owner left them", and it is in the config file for
---the one reason config files are good for: it is still there after a reload.
local configKey = "SwappingHold"

---@param str string
local function DebugLog(str)
    Debug.Log(CabbySwapping.key, str)
end

---@param obligation table|nil
local function persist(obligation)
    local configRoot = Global.configStore:GetConfigRoot()

    if obligation == nil then
        if configRoot[configKey] == nil then return end
        configRoot[configKey] = nil
    else
        configRoot[configKey] = obligation
    end

    Global.configStore:SaveConfig()
    DebugLog("Wrote down the swap obligation: " .. (obligation == nil and "nothing owed" or
        (tostring(#obligation.moves) .. " slot(s)")))
end

---Read a `/cswap wear` line: everything after the verb is the item name, in the order it was
---typed. Item names run to several words and MQ hands slash arguments over already split.
---@param args table
---@return string|nil name
local function ReadItemName(args)
    local words = {}
    for index = 2, #args do words[#words+1] = args[index] end
    if #words < 1 then return nil end
    return StringUtils.Join(words, " ")
end

---@param stateMachine StateMachine
function CabbySwapping.Init(stateMachine)
    if CabbySwapping._.isInit then return end

    local ftkey = Global.tracing.open("Swapping Setup")

    Swapping.Init({ onHoldChanged = persist })
    stateMachine:RegisterService(Swapping)

    -- anything an earlier run was still holding when it stopped. Released on adoption: whatever
    -- it was worn for is over one way or the other, so the only thing left to do with it is take
    -- it off
    local owed = Global.configStore:GetConfigRoot()[configKey]
    if owed ~= nil then
        if Swapping.Adopt(owed) then
            print("(cswap) Putting back gear an earlier run had swapped in")
        else
            -- an unreadable record is not something to keep trying to act on
            persist(nil)
        end
    end

    local cswapDocs = ChelpDocs.new(function() return {
        "(/cswap) Report what gear this script has swapped in, and put it back",
        " -- Usage: /cswap",
        " -- Usage (put it back now): /cswap off",
        " -- Usage (wear something until told otherwise): /cswap wear <item name>",
        " -- Usage (stop owing it back, leaving it where it is): /cswap forget",
        " -- What is owed survives a reload: it is written to the config file, and a slot you",
        "    have since filled yourself is left alone."
    } end )

    local function Bind_CSwap(...)
        local args = {...} or {}

        if #args > 0 and args[1]:lower() == "help" then
            cswapDocs:Print()
            return
        end

        if #args < 1 then
            print("Swapping: " .. Swapping.Describe() .. " [" .. Swapping.GetStatus() .. "]")
            local reason = Swapping.GetReason()
            if reason ~= nil then
                print(" -- " .. reason)
            end
            local owner = Swapping.GetOwner()
            if owner ~= nil then
                print(" -- for: " .. owner)
            end

            local hold = Swapping.GetHold()
            if hold ~= nil then
                for _, move in ipairs(hold.moves) do
                    if not move.preexisting and not move.discharged then
                        print(" -- " .. tostring(move.slotName) .. ": " ..
                            tostring(move.wantName or move.wantId) .. " in place of " ..
                            tostring(move.displacedName or "nothing") ..
                            (move.problem ~= nil and (" -- " .. move.problem) or ""))
                    end
                end
            end
            return
        end

        if #args == 1 and UserInput.IsFalse(args[1]) then
            if Swapping.Release() then
                print("(cswap) Putting it back")
            else
                print("(cswap) Nothing is swapped in")
            end
            return
        end

        if args[1]:lower() == "forget" then
            if Swapping.Forget() then
                print("(cswap) Dropped: the gear stays where it is and nothing is owed")
            else
                print("(cswap) Nothing was owed")
            end
            return
        end

        if args[1]:lower() == "wear" then
            local name = ReadItemName(args)
            if name == nil then
                print("(cswap) Nothing named to wear. Usage: /cswap wear <item name>")
                return
            end

            -- no keepWhile: a swap made by hand stands until it is asked to come off, which is
            -- what somebody typing this means by it
            local id, refused = Swapping.Wear({ { name = name } }, {
                owner = CabbySwapping.key,
                label = name,
                onDone = function(status, reason)
                    print("(cswap) " .. name .. ": " .. tostring(status) .. " -- " .. tostring(reason))
                end
            })

            if id == nil then
                print("(cswap) Refused: " .. tostring(refused))
            end
            return
        end

        print("(cswap) Unknown option [" .. tostring(args[1]) .. "]. /cswap help for usage")
    end
    Commands.RegisterSlashCommand(SlashCmd.new("cswap", Bind_CSwap, cswapDocs))

    CabbySwapping._.isInit = true
    Global.tracing.close(ftkey)
end

return CabbySwapping
