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
---**On our feet already** -- released to bind, standing in another zone entirely, or dragged back
---and standing there -- and the client puts up its confirmation box. Yes is the whole answer, and
---the server does the rest (`Client::OPRezzAnswer`, `zone/client_process.cpp`).
---
---**Still hovering dead**, and there is no box to answer: the offer is the `Resurrect` line on the
---respawn window, which the server puts there at death and always last
---(`Client::SendRespawnBinds`). Picking it *is* accepting -- `Client::HandleRespawnFromHover`
---answers the rez itself rather than asking us again -- so the row is selected and Respawn clicked.
---
---**The box the rez actually arrives as does not say "resurrect" anywhere.** It is
---`%1 wants to cast %2 (%3 percent) upon you. Do you wish this?` (eqstr 9047) -- the client names
---the spell and the experience it hands back, and leaves the word to the spell. So what settles it
---is the *spell*, read out of the spell data: a rez is a spell carrying `SPA_RESURRECT`, which is
---the same reading `cabby.actions.rezzes` makes of our own book, asked here of somebody else's
---spell. Nothing is inferred from the name -- `Resuscitate` and `Reviviscence` are rezzes and say so
---nowhere in theirs, and `Sacrifice` carries an effect of its own (95) rather than this one.
---
---**Every box is read before it is answered.** `ConfirmationDialogBox` is the client's one
---confirmation box and it asks about everything: destroying an item, deleting a character, joining a
---guild, and any other spell somebody wants to put on us, which arrives in exactly the wording
---above. A box offering a spell that is not a rez is left alone, as is one that does not offer a
---spell at all. Two are refused by name because they talk about a resurrection while asking
---something else:
---
--- * `%1 wants to SACRIFICE you. You get NO experience back with Resurrection, even GM. Die & lose
---   exp?` (eqstr 9054) -- a request to *kill* us, which says "Resurrection" while it asks
--- * `%1 is attempting to return you to your corpse. If you accept this, you will still be able to
---   get a resurrection later. Do you wish this?` (eqstr 3563) -- a corpse summon, which is a
---   different offer with a different cost and the player's to weigh
---
---A box saying "resurrect" plainly is still taken (eqstr 9046 is that box, and other clients use
---it), and one left alone while saying it is said out loud once -- that case is exactly what this
---module being broken looks like from the outside, and it should never be silent again.
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
        announced = nil,
        ---the last box we said we were leaving alone, for the same reason
        declined = nil
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

---The boxes that talk about a resurrection while asking about something else -- see the notes on
---this module. Lowercase, matched as plain text.
local notOurBox = {
    "sacrifice",
    "return you to your corpse"
}

---`SPA_RESURRECT` (81) and `SPA_POP_RESURRECT` (155): what makes a spell a rez, in the data. The
---first is the one `cabby.actions.rezzes` chooses our own rezzes by, and the second is here because
---recognizing one costs nothing while missing one costs the character its rez.
local rezEffects = { 81, 155 }

---The window text as it reads, with any markup taken out of it and the spacing evened up. The
---client hands back the STML source rather than the words, and a tag sitting inside the sentence
---would otherwise be a phrase that never matches.
---@param raw string|nil
---@return string text
local function plainText(raw)
    local text = tostring(raw or ""):gsub("<[^<>]*>", " ")
    text = text:gsub("%s+", " ")
    return (text:match("^%s*(.-)%s*$"))
end

---The spell named in `%1 wants to cast %2 (%3 percent) upon you. Do you wish this?` (eqstr 9047).
---@param text string the box text as it reads
---@param lower string the same, lowercased -- same length, so either can be cut at the same place
---@return string|nil name nil when the box is not that one
local function spellOfferedInDialog(text, lower)
    local _, castEnd = lower:find("wants to cast ", 1, true)
    if castEnd == nil then return nil end

    -- what the client puts after the name: the experience the spell hands back
    local tailStart = lower:find("%([^()]*percent[^()]*%)%s*upon you", castEnd + 1)
    if tailStart == nil then return nil end

    local name = text:sub(castEnd + 1, tailStart - 1):match("^%s*(.-)%s*$")
    if name == nil or name == "" then return nil end
    return name
end

---Whether a spell the client has named is a resurrection. Asked of the spell data rather than of
---the name, which is not evidence of anything -- see the notes on this module.
---@param name string
---@return boolean isRez
local function isRezSpell(name)
    local spell = mq.TLO.Spell(name)
    -- a name the client's own spell table does not know is one we can say nothing about
    if tonumber(spell.ID()) == nil then return false end

    for _, spa in ipairs(rezEffects) do
        if spell.HasSPA(spa)() == true then return true end
    end
    return false
end

---Said once per box. A box that talks about a resurrection and is left alone is exactly what this
---module failing looks like from the outside, so it says which box it saw rather than going quiet.
---@param text string
local function noteDeclined(text)
    if Rez._.declined == text then return end
    Rez._.declined = text
    print("(" .. GeneralConfig.eventIds.acceptRez .. ") Leaving this box for you to answer: " .. text)
end

---Whether the confirmation box on screen is one asking us to take a rez -- see the notes on this
---module for why the box is never answered on being open alone.
---@return boolean isRezOffer
local function dialogOffersRez()
    if mq.TLO.Window(dialogWindow).Open() ~= true then
        -- the box is gone, so the next one is said out loud even if it says the same thing
        Rez._.declined = nil
        return false
    end

    local text = plainText(mq.TLO.Window(dialogWindow).Child(dialogText).Text())
    local lower = text:lower()

    for _, phrase in ipairs(notOurBox) do
        if lower:find(phrase, 1, true) ~= nil then
            if lower:find("resurrect", 1, true) ~= nil then noteDeclined(text) end
            return false
        end
    end

    -- the box a rez really arrives as, which names the spell and never the word
    local offered = spellOfferedInDialog(text, lower)
    if offered ~= nil then
        if isRezSpell(offered) then
            Rez._.declined = nil
            DebugLog("The box offers [" .. offered .. "], which the spell data says is a rez")
            return true
        end

        -- somebody's ordinary spell, waiting on the player to answer it. Not said out loud: a box
        -- about a spell that is not a rez is none of our business and needs no explaining
        DebugLog("The box offers [" .. offered .. "], which is not a rez -- leaving it")
        return false
    end

    if lower:find("resurrect", 1, true) ~= nil then
        Rez._.declined = nil
        DebugLog("The box says it is a rez: " .. text)
        return true
    end

    return false
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
