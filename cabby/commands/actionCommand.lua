local Debug = require("utils.Debug.Debug")
local StringUtils = require("utils.StringUtils.StringUtils")

local Action = require("cabby.actions.action")
local ChelpDocs = require("cabby.commands.chelpDocs")
local Command = require("cabby.commands.command")
local Commands = require("cabby.commands.commands")
local UserInput = require("cabby.utils.userinput")

---Registers a comm command over a state's configured action slots: `action off firestorm`,
---`healaction on complete heal`, or a name on its own to flip whatever that slot is now.
---
---Every state with an action list wants exactly this command, and wants it to work the same way,
---so it is a factory rather than something each state writes again. Like `ToggleCommand` it holds
---no state of its own: the switch it flips is `Action.IsEnabled/SetEnabled` on the live slot,
---which is what the Enabled checkbox on the state's page writes, so a chat order, a hotbar button
---and the checkbox cannot disagree.
---
---What makes it bindable rather than something you have to know the spelling of is `choices`:
---the slots this character has configured *right now*, each of the three ways it can be switched.
---A bar of `action` buttons would say nothing about which is which, so a choice also carries the
---name to give a button that runs it.
---@class ActionCommand
local ActionCommand = { key = "ActionCommand" }

---@class ActionCommandSpec
---@field phrase string what to say, e.g. "action" or "healaction"
---@field summary string one line about what these actions are, for the first line of its help
---@field where string where the slots are configured, named as the user sees it ("Melee State
---page, Tanking and Melee tabs")
---@field getActionLists fun(): table array of { label = string, actions = Action[] }
---@field key string? Debug toggle key to log under, defaults to this module's

---@param words table
---@param index number first word to take
---@return string text those words back as one string
local function JoinFrom(words, index)
    local rest = {}
    for wordIndex = index, #words do
        rest[#rest+1] = words[wordIndex]
    end
    return StringUtils.Join(rest, " ")
end

---Read what an order is asking for. The switch comes first because the name cannot: action names
---run to several words ("Firestorm of Fists Rk. II"), so everything after the switch is name. A
---name with no switch in front of it flips whatever that slot is now, which is what a hotbar
---button wants to be.
---@param args string everything said after the phrase
---@return string? switch "on", "off" or "toggle"; nil when the order names nothing to switch
---@return string? name what to match against the configured slots
function ActionCommand.ReadOrder(args)
    local words = StringUtils.Split(StringUtils.TrimFront(args or ""))
    if #words < 1 then return nil, nil end

    local first = words[1]:lower()
    local switch
    if first == "toggle" or first == "flip" then
        switch = "toggle"
    elseif UserInput.IsTrue(first) then
        switch = "on"
    elseif UserInput.IsFalse(first) then
        switch = "off"
    end

    if switch ~= nil then
        -- a switch and nothing else says what to do without saying what to do it to
        if #words < 2 then return nil, nil end
        return switch, JoinFrom(words, 2)
    end

    return "toggle", JoinFrom(words, 1)
end

---Which configured slots an order is about. An exact name wins outright; failing that, any slot
---whose name contains what was said, so a button can be bound with `off firestorm` rather than
---the whole of "Firestorm of Fists Rk. II".
---@param actionLists table
---@param name string
---@return table matches array of { label = string, action = Action }
function ActionCommand.FindSlots(actionLists, name)
    name = name:lower()
    local exact, partial = {}, {}

    for _, list in ipairs(actionLists) do
        for _, action in ipairs(list.actions) do
            local actionName = tostring(action.name or ""):lower()
            if actionName == name then
                exact[#exact+1] = { label = list.label, action = action }
            elseif actionName:find(name, 1, true) ~= nil then
                partial[#partial+1] = { label = list.label, action = action }
            end
        end
    end

    if #exact > 0 then return exact end
    return partial
end

---@param spec ActionCommandSpec
function ActionCommand.Register(spec)
    local docs = ChelpDocs.new(function()
        local lines = {
            "(" .. spec.phrase .. ") " .. spec.summary,
            " -- Usage: " .. spec.phrase .. " <on | off | toggle> <part of the action's name>",
            " -- Or: " .. spec.phrase .. " <part of the action's name>, to flip whatever it is now",
            " -- Enough of the name to pick the action out is enough, and case does not",
            "    matter. Every slot the name matches is switched together.",
            " -- Configured slots (" .. spec.where .. "):"
        }

        local anyConfigured = false
        for _, list in ipairs(spec.getActionLists()) do
            for _, action in ipairs(list.actions) do
                anyConfigured = true
                lines[#lines+1] = "    " .. list.label .. ": " .. tostring(action.name) ..
                    " [" .. (Action.IsEnabled(action) and "on" or "off") .. "]"
            end
        end
        if not anyConfigured then
            lines[#lines+1] = "    <none configured yet>"
        end

        return lines
    end )

    local function handler(_, speaker, args)
        if not Commands.GetCommandOwners(spec.phrase):HasPermission(speaker) then
            Debug.Log(spec.key or ActionCommand.key, "Ignoring [" .. spec.phrase .. "] speaker [" .. speaker .. "]")
            return
        end

        local switch, name = ActionCommand.ReadOrder(args)
        if switch == nil or name == nil then
            print("(" .. spec.phrase .. ") Nothing named to switch. Usage: " .. spec.phrase ..
                " <on | off | toggle> <part of the action's name>")
            return
        end

        local matches = ActionCommand.FindSlots(spec.getActionLists(), name)
        if #matches < 1 then
            print("(" .. spec.phrase .. ") No configured action matches [" .. name .. "]. /chelp " ..
                spec.phrase .. " lists them.")
            return
        end

        -- one value for all of them, taken from the first, so a name fragment that catches more
        -- than one slot leaves those slots agreeing rather than in opposite states
        local value = switch == "on"
        if switch == "toggle" then
            value = not Action.IsEnabled(matches[1].action)
        end

        for _, match in ipairs(matches) do
            Action.SetEnabled(match.action, value)
            print("(" .. spec.phrase .. ") " .. match.label .. ": " .. tostring(match.action.name) ..
                " [" .. (value and "on" or "off") .. "]")
        end
    end

    ---What the button editor offers as arguments: every slot this character has configured, each
    ---of the three ways it can be switched. Read when it is offered rather than built once, so a
    ---slot added or renamed on the state's page is offered here on the next frame. Slots still
    ---being filled in have no name to switch by and are left out.
    ---@return table choices
    local function ArgChoices()
        -- `suffix` is for the button's name, not for the command: a button that flips a
        -- discipline wants to be called after the discipline, and one that only ever turns it on
        -- or off wants to say which
        local switches = {
            { args = "toggle", group = "Toggle", suffix = "" },
            { args = "on", group = "Turn on", suffix = " on" },
            { args = "off", group = "Turn off", suffix = " off" }
        }

        local choices = {}
        for _, switch in ipairs(switches) do
            for _, list in ipairs(spec.getActionLists()) do
                for _, action in ipairs(list.actions) do
                    local name = tostring(action.name or "")
                    if name ~= "" and name:lower() ~= "none" then
                        choices[#choices+1] = {
                            label = list.label .. ": " .. name,
                            args = switch.args .. " " .. name,
                            group = switch.group,
                            name = name .. switch.suffix
                        }
                    end
                end
            end
        end
        return choices
    end

    ---What a button carrying this command shows: the state of the slots it names, when they have
    ---one between them.
    ---@param args string
    ---@return boolean? state
    local function ReadState(args)
        local _, name = ActionCommand.ReadOrder(args)
        if name == nil then return nil end

        local matches = ActionCommand.FindSlots(spec.getActionLists(), name)
        if #matches < 1 then return nil end

        local state = Action.IsEnabled(matches[1].action)
        for _, match in ipairs(matches) do
            -- slots that do not agree have no one state to show
            if Action.IsEnabled(match.action) ~= state then return nil end
        end
        return state
    end

    Commands.RegisterCommEvent(Command.new(spec.phrase, handler, docs)
        :WithArgs({
            required = true,
            hint = "on, off or toggle, then part of the action's name",
            choices = ArgChoices
        })
        :WithState(ReadState))
end

return ActionCommand
