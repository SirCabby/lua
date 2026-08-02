local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local Time = require("utils.Time.Time")

local ChelpDocs = require("cabby.commands.chelpDocs")
local Commands = require("cabby.commands.commands")
local Event = require("cabby.commands.event")
local GeneralConfig = require("cabby.configs.generalConfig")

---Taking the resurrection somebody just offered us.
---
---A rez arrives as one of two things, and which one depends on whether we are still hovering over
---our own corpse when it lands:
---
---**On our feet already** -- released to bind, or dragged back and standing there -- and the client
---puts up its confirmation box (`%1 wants to RESURRECT you. Do you wish this?`, eqstr 9046). Yes is
---the whole answer, and the server does the rest (`Client::OPRezzAnswer`, `zone/client_process.cpp`).
---
---**Still hovering dead**, and there is no box to answer: the offer is the `Resurrect` line on the
---respawn window, which the server puts there at death and always last
---(`Client::SendRespawnBinds`). Picking it *is* accepting -- `Client::HandleRespawnFromHover`
---answers the rez itself rather than asking us again -- so the row is selected and Respawn clicked.
---
---**The box is read before it is answered, every time.** `ConfirmationDialogBox` is the client's one
---confirmation box and it asks about everything: destroying an item, deleting a character, and -- the
---one that matters here -- `%1 wants to SACRIFICE you. You get NO experience back with Resurrection,
---even GM. Die & lose exp?` (eqstr 9054), which is a request to *kill* us and which says
---"Resurrection" while it asks. Only "wants to resurrect you" is answered Yes, and anything
---mentioning a sacrifice is the player's to answer whatever else it says.
---
---**The hover pick waits for evidence that a rez is really pending**, and that evidence is the
---client saying so ("You have been offered a resurrection."). The `Resurrect` row is on the respawn
---window from the moment we die, offer or no offer, and picking it with nothing behind it is not a
---harmless miss: `HandleRespawnFromHover` disables the respawn timer before it finds out there is no
---rez to give, so a blind click leaves the character hovering with the clock that would have
---released it switched off.
---
---What it holds is that offer, which is the one thing the world cannot answer: a respawn window with
---a rez waiting behind it and one without look exactly alike. It is dropped the moment we are alive
---again, so an offer can never carry into the next death.
---@class Rez
local Rez = {
    key = "Rez",
    eventIds = {
        rezOffered = "rezoffered"
    },
    _ = {
        isInit = false,
        ---whether the client has said a rez is waiting on this death; false when none is
        offered = false,
        lastLookMs = 0,
        ---what we last said we were doing, so it is said once rather than every look
        announced = nil
    }
}

local dialogWindow = "ConfirmationDialogBox"
local dialogText = "CD_TextOutput"
local dialogYes = "CD_Yes_Button"

local respawnWindow = "RespawnWnd"
local respawnList = "RW_OptionsList"
local respawnSelect = "RW_SelectButton"

---Columns the respawn list draws (`RW_OptionsList` in EQUI_RespawnWnd.xml): a narrow unnamed one,
---Name and Zone. Which of them an option's name lands in is the client's business, so all three are
---read rather than guessed at.
local respawnColumns = 3

---How long between looks, and so between commands. Reading two windows and answering them forty
---times a second is noise rather than speed, and half a second after it appeared is instantly as far
---as anybody watching is concerned. Nothing here is a deadline: the same look is taken again on the
---next one, and it is what decides all over again.
local lookPaceMs = 500

---@param str string
local function DebugLog(str)
    Debug.Log(Rez.key, str)
end

---Whether the client is dead. HOVER is dead and not yet released; DEAD is the beat before it, and
---the two are one death rather than two.
---@return boolean isDead
local function isDead()
    local state = tostring(mq.TLO.Me.State() or "")
    return state == "DEAD" or state == "HOVER"
end

---Whether the confirmation box on screen is one asking us to take a rez -- see the notes on this
---module for why the box is never answered on being open alone.
---@return boolean isRezOffer
local function dialogOffersRez()
    if mq.TLO.Window(dialogWindow).Open() ~= true then return false end

    local text = tostring(mq.TLO.Window(dialogWindow).Child(dialogText).Text() or ""):lower()
    if text:find("sacrifice", 1, true) ~= nil then return false end
    return text:find("wants to resurrect you", 1, true) ~= nil
end

---The `Resurrect` line on the respawn window, if it is showing one.
---@return number|nil row 1-based row of it, as `/notify ... listselect` counts them
local function resurrectRow()
    if mq.TLO.Window(respawnWindow).Open() ~= true then return nil end

    local list = mq.TLO.Window(respawnWindow).Child(respawnList)
    local rows = tonumber(list.Items()) or 0

    for row = 1, rows do
        for column = 1, respawnColumns do
            local text = tostring(list.List(row, column)() or ""):lower()
            if text:find("resurrect", 1, true) ~= nil then return row end
        end
    end

    return nil
end

---One line about what is being taken, said once. All of this happens while the player is looking at
---a corpse or a respawn window, where a character that took the rez and a character whose switch is
---off look exactly the same.
---@param what string|nil nil for "doing nothing about a rez", which says nothing
local function announce(what)
    if Rez._.announced == what then return end
    Rez._.announced = what

    if what ~= nil then
        print("(" .. GeneralConfig.eventIds.acceptRez .. ") " .. what)
    end
end

---Service contract: answer the rez that is on screen, or take the one we have been told is waiting.
function Rez.Pulse()
    if not GeneralConfig.GetAcceptRez() then
        -- turning the switch off is an order to stop now, not one that takes effect next death
        Rez._.offered = false
        announce(nil)
        return
    end

    -- Nothing is answered while the world is being taken down and put back up: a command typed into
    -- a loading screen is one nobody hears, and taking a rez is what starts one of those.
    local gameState = mq.TLO.EverQuest.GameState()
    if gameState ~= nil and gameState ~= "INGAME" then return end

    -- an offer belongs to the death it was made in, and this one is over
    local dead = isDead()
    if not dead then Rez._.offered = false end

    local now = Time.current_time()
    if now - Rez._.lastLookMs < lookPaceMs then return end
    Rez._.lastLookMs = now

    -- The box first, and on its own. Wherever it appears it is the whole answer, and clicking the
    -- respawn window in the same beat would be answering one offer twice.
    if dialogOffersRez() then
        -- the client asking is itself the offer, whether or not the line we listen for was printed
        if dead then Rez._.offered = true end
        announce("Accepting the resurrection")
        DebugLog("Answering the rez confirmation box")
        mq.cmd("/notify " .. dialogWindow .. " " .. dialogYes .. " leftmouseup")
        return
    end

    if not dead or not Rez._.offered then
        announce(nil)
        return
    end

    local row = resurrectRow()
    if row == nil then
        -- dead with an offer standing and no window to take it on yet, which is the beat between
        -- dying and hovering. Nothing to do but look again.
        DebugLog("A rez is waiting and the respawn window is not showing a Resurrect line yet")
        return
    end

    announce("Taking the resurrection from the respawn window")
    DebugLog("Picking the Resurrect line (row " .. tostring(row) .. ") on the respawn window")
    mq.cmd("/notify " .. respawnWindow .. " " .. respawnList .. " listselect " .. tostring(row))
    mq.cmd("/notify " .. respawnWindow .. " " .. respawnSelect .. " leftmouseup")
end

---@param stateMachine StateMachine
function Rez.Init(stateMachine)
    if Rez._.isInit then return end

    local ftkey = Global.tracing.open("Rez Setup")

    stateMachine:RegisterService(Rez)

    local offeredDocs = ChelpDocs.new(function() return {
        "(event: " .. Rez.eventIds.rezOffered .. ") Notices a resurrection offered while hovering dead",
        " -- The respawn window carries a Resurrect line from the moment we die, offer or not, so",
        "    this is the client's only way of saying there is a rez behind it worth taking",
        " -- What is done about it is the (" .. GeneralConfig.eventIds.acceptRez .. ") switch"
    } end )
    ---Recorded, not acted on: the pulse owns what an offer means and how long it lasts, and it is
    ---the one that knows whether we are still dead by the time it reads this.
    local function event_RezOffered()
        DebugLog("The client says a resurrection has been offered")
        Rez._.offered = true
    end
    Commands.RegisterEvent(Event.new(Rez.eventIds.rezOffered, "You have been offered a resurrection.",
        event_RezOffered, offeredDocs))

    -- Whatever the client is showing when this comes up is where the watching starts from. A script
    -- restarted while a box is already on screen still reads it before answering it, and an offer it
    -- never heard made is not one it knows about -- which is the safe way round for the hover pick.
    Rez._.offered = false

    Rez._.isInit = true
    Global.tracing.close(ftkey)
end

return Rez
