---@diagnostic disable: undefined-field
local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local Giving = require("utils.Giving.Giving")
local StringUtils = require("utils.StringUtils.StringUtils")

local ChelpDocs = require("cabby.commands.chelpDocs")
local Commands = require("cabby.commands.commands")
local SlashCmd = require("cabby.commands.slashcmd")
local UserInput = require("cabby.utils.userinput")

---Cabby side wiring for the reusable giving service in `utils/Giving`.
---
---Callers drive it by requiring `utils.Giving.Giving` directly; all this module does is put the
---service on the state machine's per-frame pulse -- which is the whole reason handing an item
---over is a service and not four lines inside a state, since the sequence has to keep making
---progress on the frames a state is starved -- and expose `/cgive` for handing something over by
---hand, and for looking at (or killing) whatever is being handed over now.
---@class CabbyGiving
local CabbyGiving = {
    key = "Giving",
    _ = {
        isInit = false
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(CabbyGiving.key, str)
end

---Read a `/cgive` line: everything that is not an option is part of the item name.
---
---Item names run to several words and MQ hands slash arguments over already split on spaces, so
---the name cannot be a single argument. The one option is recognized by shape --
---`targetid|1234` -- and everything else, in the order it was typed, is the name.
---@param args table
---@return table request { name, targetId } or { error }
local function ReadGiveOrder(args)
    local request = {}
    local words = {}

    for _, arg in ipairs(args) do
        local key, value = arg:lower():match("^(%a+)|(.+)$")

        if key == "targetid" then
            request.targetId = tonumber(value)
            if request.targetId == nil then
                return { error = "[" .. arg .. "] is not a spawn id" }
            end
        else
            words[#words+1] = arg
        end
    end

    if #words < 1 then return { error = "nothing named to give" } end

    request.name = StringUtils.Join(words, " ")
    return request
end

---@param stateMachine StateMachine
function CabbyGiving.Init(stateMachine)
    if CabbyGiving._.isInit then return end

    local ftkey = Global.tracing.open("Giving Setup")

    Giving.Init()
    stateMachine:RegisterService(Giving)

    local cgiveDocs = ChelpDocs.new(function() return {
        "(/cgive) Hand an item to a spawn through the giving service",
        " -- Usage: /cgive <item name> [targetid|<#>]",
        " -- Usage (what giving is doing now): /cgive",
        " -- Usage (cancel the hand-off in progress): /cgive off",
        " -- Example: /cgive Summoned: Fist of Flame targetid|${Me.Pet.ID}",
        " -- Without targetid it goes to whatever is targeted now",
        " -- The name is everything that is not the option above, so it needs no quotes"
    } end )

    local function Bind_CGive(...)
        local args = {...} or {}

        if #args > 0 and args[1]:lower() == "help" then
            cgiveDocs:Print()
            return
        end

        if #args < 1 then
            print("Giving: " .. Giving.Describe() .. " [" .. Giving.GetStatus() .. "]")
            local reason = Giving.GetReason()
            if reason ~= nil then
                print(" -- " .. reason)
            end
            local owner = Giving.GetOwner()
            if owner ~= nil then
                print(" -- requested by: " .. owner)
            end
            return
        end

        if #args == 1 and UserInput.IsFalse(args[1]) then
            if Giving.Interrupt() then
                print("(cgive) Cancelling " .. Giving.Describe())
            else
                print("(cgive) Nothing is being handed over")
            end
            return
        end

        local request = ReadGiveOrder(args)
        if request.error ~= nil then
            print("(cgive) " .. request.error .. ". Usage: /cgive <item name> [targetid|<#>]")
            return
        end

        local spawnId = request.targetId or tonumber(mq.TLO.Target.ID())
        if spawnId == nil or spawnId < 1 then
            print("(cgive) Nobody to give it to. Target them, or say targetid|<spawn id>")
            return
        end

        DebugLog("Hand give requested: " .. request.name .. " to " .. tostring(spawnId))

        local id, refused = Giving.Hand({ name = request.name }, {
            owner = CabbyGiving.key,
            spawnId = spawnId,
            onDone = function(status, reason)
                print("(cgive) " .. request.name .. ": " .. tostring(status) .. " -- " .. tostring(reason))
            end
        })

        if id == nil then
            print("(cgive) Refused: " .. tostring(refused))
        end
    end
    Commands.RegisterSlashCommand(SlashCmd.new("cgive", Bind_CGive, cgiveDocs))

    CabbyGiving._.isInit = true
    Global.tracing.close(ftkey)
end

return CabbyGiving
