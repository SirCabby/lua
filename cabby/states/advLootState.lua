---@diagnostic disable: undefined-field
local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local Time = require("utils.Time.Time")

local AdvLootStateConfig = require("cabby.configs.advLootStateConfig")
local AdvLootStateMenu = require("cabby.ui.states.advLootStateMenu")
local ChelpDocs = require("cabby.commands.chelpDocs")
local Commands = require("cabby.commands.commands")
local Menu = require("cabby.ui.menu")
local SlashCmd = require("cabby.commands.slashcmd")
local ToggleCommand = require("cabby.commands.toggleCommand")

---The akk-stack loot window (`lootwnd.asi`), a real SIDL window MacroQuest can read and click.
---This is the only loot surface that exists here: the RoF2 client has no native advanced loot,
---this MacroQuest build compiles its AdvLoot TLO out, and the server never fills the client's
---master-looter role -- the window is where the whole system lives.
local advLootWindow = "AdvLootWnd"

---How many rows the window draws (NAME_ROWS in lootwnd.cpp). Drops beyond these queue up
---server-side and surface as rows clear.
local advLootRows = 12

---How often the window is re-read. The walk over it is a few dozen child reads at the top of a
---chain that runs forty times a second, so the answer is cached and re-read a few times a second
---instead -- plenty for a window people answer in whole seconds.
local scanIntervalMs = 250

---How long an answer of ours has to have been out before the next one is given. The click removes
---the row from the window at once, but the server's tally messages are in flight around it and
---can redraw a beat behind; a vote is irrevocable and a second one is answered with "You have
---already rolled". An evidence window on our own last command, not a give-up: nothing stops being
---tried, the next answer just waits for the last one to settle.
local answerSettleMs = 500

---Loot etiquette for the akk-stack advloot system: whoever controls the loot deals with the
---items, and everybody else answers **Pass** to every roll nobody has answered, so no roll ever
---waits on this character.
---
---**The window is the world here, and it already knows everything.** Who controls the loot (the
---group's delegated looter, or its leader -- the server decides and the window is told), whether
---a row is rolling or free-for-all, and whether we have already answered are all readable off the
---window's own controls, so this state asks nothing about the group at all:
---
---- a row is *showing* while its `ADLW_Name<r>` label is visible with text in it;
---- it is *rolling* while its `ADLW_Loot<r>` button says **Need** (free-for-all relabels the row's
---  buttons Loot/Give/Sell -- and that last one is why the mode is checked at all: the Pass
---  button of a rolling row *is the Sell button* of a free-for-all row);
---- it is *unanswered* while that button is still visible -- the window hides a row's vote
---  buttons the moment a vote goes out, and a vote is irrevocable;
---- it is *ours to deal with* while `ADLW_Roll<r>` (the controller-only Lock/Unlock button) is
---  visible, and this state passes only on a row whose controller button it can positively see
---  hidden -- an unreadable row is treated as ours, because the failure mode of passing wrongly
---  is the whole group passing, which strands the item on the corpse.
---
---**Only Pass is ever clicked** (`/notify` on `ADLW_Never<r>`, only while the row reads as a
---roll). Everything else on the window is somebody's decision or a permanent one: Give hands the
---item to whatever we happen to have targeted, the four Always buttons write per-item preferences
---into the database, Deny opts out of the coin split, and Need/Greed are wants this state does
---not have. An item the player already answered is never touched -- the pending test is the vote
---buttons still showing -- and rolls have no deadline of their own (the corpse's decay clock
---free-for-alls whatever is still locked near the end), so nothing here races a timer.
---
---**Every answer comes from a look taken this pass.** The window compacts rows upward whenever
---one clears, so a row number even a quarter second old can name a different item by now; the
---scan and the click it decides on happen in the same frame, and the passes in between hand
---their turn straight down.
---
---Where it sits does the rest (`Priorities.loot`): below the fighting bands, so nothing is
---answered ahead of a swing mid-fight, and above follow and rest, so a stack of rolls is cleared
---promptly once the fighting is over.
---@class AdvLootState : BaseState
local AdvLootState = {
    key = "AdvLootState",
    eventIds = {
        advloot = "advloot"
    },
    _ = {
        isInit = false,
        lastScanMs = 0,
        lastAnswerMs = 0,
        -- what the last look found, for the passes between looks, the page and /cadvloot: the
        -- first roll waiting on us and how many wait in all, how many rows are showing at all,
        -- who controls the loot in the words the page shows, and what is being done
        firstPending = nil,
        pendingCount = 0,
        showingCount = 0,
        looterLabel = "unknown",
        standing = "standing by"
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(AdvLootState.key, str)
end

---------------- The look --------------------

---@param name string a control's screen id, e.g. "ADLW_Name0"
---@return any child a window TLO for it
local function control(name)
    return mq.TLO.Window(advLootWindow).Child(name)
end

---@param kind string "Name", "Loot", "Never", "Roll"
---@param row number 0-based row on the window
---@return any child
local function rowControl(kind, row)
    return control("ADLW_" .. kind .. tostring(row))
end

---One look at the window: who controls the loot, and what still waits on a pass from us.
local function scan()
    AdvLootState._.firstPending = nil
    AdvLootState._.pendingCount = 0
    AdvLootState._.showingCount = 0

    -- the window is created the first time something drops (or /advloot is typed); until then
    -- there is nothing to read and nothing to do. Open() nil is "no such window", false is only
    -- "hidden" -- and hidden is fine, the controls underneath keep their own state either way
    if mq.TLO.Window(advLootWindow).Open() == nil then
        AdvLootState._.looterLabel = "unknown"
        AdvLootState._.standing = "no loot window yet -- nothing has dropped"
        return
    end

    local weControl = false
    for row = 0, advLootRows - 1 do
        local name = rowControl("Name", row).Text()
        if name ~= nil and name ~= "" and rowControl("Name", row).Open() == true then
            AdvLootState._.showingCount = AdvLootState._.showingCount + 1

            local controllerButton = rowControl("Roll", row).Open()
            if controllerButton == true then
                weControl = true
            end

            -- pending our pass: a roll (not free-for-all), unanswered, and positively not ours
            -- to deal with. Anything unreadable fails toward "ours", never toward passing
            if rowControl("Loot", row).Text() == "Need"
                and rowControl("Loot", row).Open() == true
                and controllerButton == false then
                AdvLootState._.pendingCount = AdvLootState._.pendingCount + 1
                if AdvLootState._.firstPending == nil then
                    AdvLootState._.firstPending = { row = row, name = name }
                end
            end
        end
    end

    -- who deals with the items, in the words the page shows: the controller-only buttons are the
    -- window saying it is us; the looter label is it saying who else (blank for the leader, who
    -- gets a combo box there instead -- then the name is one the chain of controls cannot say)
    local looterName = control("ADLW_LooterName").Text()
    if weControl then
        AdvLootState._.looterLabel = (mq.TLO.Me.CleanName() or "us") .. " (me)"
    elseif looterName ~= nil and looterName ~= "" and control("ADLW_LooterName").Open() == true then
        AdvLootState._.looterLabel = looterName
    else
        AdvLootState._.looterLabel = "unknown"
    end

    if AdvLootState._.firstPending ~= nil then
        AdvLootState._.standing = "passing on " .. AdvLootState._.firstPending.name ..
            (AdvLootState._.pendingCount > 1
                and (" (" .. tostring(AdvLootState._.pendingCount) .. " waiting)") or "")
    elseif weControl and AdvLootState._.showingCount > 0 then
        AdvLootState._.standing = "we control the loot -- the items are ours to deal with"
    else
        AdvLootState._.standing = "nothing is waiting on us"
    end
end

---------------- Status --------------------

---@return string description of what this state is doing, for the page and /cadvloot
function AdvLootState.Describe()
    return AdvLootState._.standing
end

---@return string looterLabel who controls the loot, in the words the page shows
function AdvLootState.GetLooterLabel()
    return AdvLootState._.looterLabel
end

---@return number pendingCount rolls still waiting on a pass of ours, as of the last look
function AdvLootState.GetPendingCount()
    return AdvLootState._.pendingCount
end

---@return number showingCount rows showing on the window at all, as of the last look
function AdvLootState.GetShowingCount()
    return AdvLootState._.showingCount
end

---------------- Init --------------------

---@diagnostic disable-next-line: duplicate-set-field
function AdvLootState.Init()
    if AdvLootState._.isInit then return end

    AdvLootStateConfig.Init()

    Menu.RegisterState(AdvLootState)

    ToggleCommand.Register({
        key = AdvLootState.key,
        phrase = AdvLootState.eventIds.advloot,
        summary = "Turns passing on loot rolls for whoever controls the loot on or off",
        about = {
            "With somebody else controlling the group's loot (the delegated looter, or the",
            "leader), every roll nobody has answered is answered Pass, so the looter alone deals",
            "with the items and no roll waits on this character. The looter itself, rolls already",
            "answered by hand, and free-for-all loot are all left alone."
        },
        get = AdvLootStateConfig.IsEnabled,
        set = AdvLootState.SetEnabled
    })

    local cadvlootDocs = ChelpDocs.new(function() return {
        "(/cadvloot) Report how the loot window is being handled",
        " -- Usage: /cadvloot",
        " -- With somebody else controlling the group's loot, this character answers Pass to",
        "    every roll nobody has answered, so the looter alone deals with the items.",
        " -- The looter itself, rolls already answered by hand, and free-for-all loot are",
        "    left alone. (advloot off) stops it answering at all."
    } end )
    local function Bind_CAdvLoot(...)
        local args = {...} or {}

        if #args > 0 and args[1]:lower() == "help" then
            cadvlootDocs:Print()
            return
        end

        -- report from a look taken now: disabled, this state gets no passes, and a report from
        -- whenever it last did would be an answer about a different world
        AdvLootState._.lastScanMs = Time.current_time()
        scan()

        print("AdvLoot: " .. AdvLootState.Describe() .. (AdvLootState.IsEnabled() and "" or " (disabled)"))
        print(" -- loot controller: " .. AdvLootState._.looterLabel)
        print(" -- rolls waiting on us: " .. tostring(AdvLootState._.pendingCount))
        print(" -- rows showing: " .. tostring(AdvLootState._.showingCount))
    end
    Commands.RegisterSlashCommand(SlashCmd.new("cadvloot", Bind_CAdvLoot, cadvlootDocs))

    AdvLootState.Reset()
    AdvLootState._.isInit = true
end

function AdvLootState.Reset()
    AdvLootState._.lastScanMs = 0
    AdvLootState._.lastAnswerMs = 0
    AdvLootState._.firstPending = nil
    AdvLootState._.pendingCount = 0
    AdvLootState._.showingCount = 0
    AdvLootState._.looterLabel = "unknown"
    AdvLootState._.standing = "standing by"
end

---One pass: a fresh look a few times a second, and at most one answer per settle window, decided
---out of the look just taken -- never out of a cached one, since the window compacts rows upward
---as they clear.
---@return boolean isBusy
---@diagnostic disable-next-line: duplicate-set-field
function AdvLootState.Go()
    local now = Time.current_time()

    if now - AdvLootState._.lastScanMs < scanIntervalMs then
        return false
    end
    AdvLootState._.lastScanMs = now
    scan()

    local pending = AdvLootState._.firstPending
    if pending == nil then return false end

    -- our last answer may still be settling; a vote is irrevocable, so nothing is clicked while
    -- the world could still be redrawing the one before
    if now - AdvLootState._.lastAnswerMs < answerSettleMs then return false end

    DebugLog("Passing on " .. pending.name .. " (row " .. tostring(pending.row) .. ")")
    -- the row's Pass button, which the same look just saw as a roll -- on a free-for-all row
    -- this very button is Sell, which is why the click never outlives the frame that read it
    mq.cmd("/notify " .. advLootWindow .. " ADLW_Never" .. tostring(pending.row) .. " leftmouseup")
    AdvLootState._.lastAnswerMs = now
    -- the answer was this frame's work; the next pass starts again from the top of the chain
    return true
end

---@return boolean isEnabled
---@diagnostic disable-next-line: duplicate-set-field
AdvLootState.IsEnabled = function()
    return AdvLootStateConfig.IsEnabled()
end

---Switching it off stops it answering anything; answers already given stand, since a vote is
---irrevocable anyway. Nothing is in flight to call off, so unlike resting there is no posture to
---put back -- the reset just clears what the last look found.
---@param isEnabled boolean
---@diagnostic disable-next-line: duplicate-set-field
AdvLootState.SetEnabled = function(isEnabled)
    AdvLootStateConfig.SetEnabled(isEnabled)

    if not isEnabled then
        AdvLootState.Reset()
    end
end

---@diagnostic disable-next-line: duplicate-set-field
function AdvLootState.BuildMenu()
    AdvLootStateMenu.BuildMenu(AdvLootState)
end

return AdvLootState
