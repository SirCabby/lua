local Debug = require("utils.Debug.Debug")
local StringUtils = require("utils.StringUtils.StringUtils")

local ChelpDocs = require("cabby.commands.chelpDocs")
local Command = require("cabby.commands.command")
local Commands = require("cabby.commands.commands")
local UserInput = require("cabby.utils.userinput")

---Registers a comm command over a single on/off setting: `stick off`, `tanking on`, or the
---phrase with nothing after it to flip whatever it is now.
---
---Each of these settings is already a checkbox in the menu, and this holds no state of its own:
---it reads and writes the same config the checkbox does, so a hotbar button, a chat order and
---the checkbox can never disagree about what is on. That is the whole point of registering them
---as comm commands rather than adding a second kind of hotbar button -- the button editor offers
---every registered command already, and `<<phrase>> toggle` is offered to it as the default
---arguments, so binding one is a pick with no typing.
---
---Saying what changed is left to `set`, because that is where this codebase already prints it
---(`MeleeStateConfig.SetStick` and friends). Printing here as well would report every flip twice
---and still leave the UI checkbox as the one path that says nothing.
---@class ToggleCommand
local ToggleCommand = { key = "ToggleCommand" }

---@class ToggleCommandSpec
---@field phrase string what to say; one word, since anything after it is read as on/off
---@field summary string what the setting does, for the first line of its help
---@field get fun(): boolean reads the setting
---@field set fun(value: boolean) writes it, and reports what it did
---@field about table? extra help lines worth having before flipping it
---@field key string? Debug toggle key to log under, defaults to this module's

---@param word string lowercased, "" when nothing was said after the phrase
---@param current boolean
---@return boolean? value nil when the word cannot be read as on or off
local function ReadSwitch(word, current)
    -- nothing after the phrase means flip it: what makes a hotbar button a toggle button.
    -- Checked before UserInput, which reads "" as false.
    if word == "" or word == "toggle" or word == "flip" then return not current end
    if UserInput.IsTrue(word) then return true end
    if UserInput.IsFalse(word) then return false end
    return nil
end

---@param spec ToggleCommandSpec
function ToggleCommand.Register(spec)
    local docs = ChelpDocs.new(function()
        local lines = {
            "(" .. spec.phrase .. ") " .. spec.summary,
            " -- Usage: " .. spec.phrase .. " <on | off | toggle>",
            " -- " .. spec.phrase .. " with nothing after it flips whatever it is now"
        }
        for _, line in ipairs(spec.about or {}) do
            lines[#lines+1] = " -- " .. line
        end
        -- read when the help is asked for, so it also answers "what is it right now", both in
        -- chat and in the docs pane of the hotbar button editor
        lines[#lines+1] = " -- Currently: " .. (spec.get() == true and "on" or "off")
        return lines
    end)

    local function handler(_, speaker, args)
        if not Commands.GetCommandOwners(spec.phrase):HasPermission(speaker) then
            Debug.Log(spec.key or ToggleCommand.key, "Ignoring [" .. spec.phrase .. "] speaker [" .. speaker .. "]")
            return
        end

        local words = StringUtils.Split(StringUtils.TrimFront(args or ""))
        local word = (words[1] or ""):lower()

        if word == "help" then
            docs:Print()
            return
        end

        -- One word at most, and it has to read as on or off. Anything else is a typo, or a chat
        -- line that merely began with our phrase ("stick with me"), and flipping a setting is the
        -- wrong guess either way. One line about it rather than the whole help, which is a
        -- /chelp away: this fires on ordinary chatter, not only on mistakes.
        local value = ReadSwitch(word, spec.get() == true)
        if value == nil or #words > 1 then
            print("(" .. spec.phrase .. ") Usage: " .. spec.phrase .. " <on | off | toggle>, or " ..
                spec.phrase .. " on its own to flip it")
            return
        end

        spec.set(value)
    end

    Commands.RegisterCommEvent(Command.new(spec.phrase, handler, docs)
        :WithArgs({
            required = false,
            hint = "on, off, or toggle",
            default = "toggle",
            choices = function() return {
                { label = "Toggle", args = "toggle" },
                { label = "Turn on", args = "on" },
                { label = "Turn off", args = "off" }
            } end
        })
        -- the arguments are ignored on purpose: what a hotbar button shows is the setting, so a
        -- `stick off` button and a `stick toggle` button both read as "stick is on" while it is
        :WithState(function() return spec.get() == true end))
end

return ToggleCommand
