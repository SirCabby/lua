---What a command expects after its phrase. Optional: a command that declares nothing is one
---that takes no arguments, or one whose arguments nothing but the user knows about.
---
---`choices` is the difference between a command a user can bind and one they have to know the
---spelling of. `action` can switch any configured action slot, which as free text means typing
---part of a discipline's name from memory; declared as choices it is a pick from the slots this
---character actually has. They are read when they are offered, not registered once, so they follow
---whatever is configured right now.
---@class CommandArgs
---@field required boolean true when the command can do nothing at all without arguments
---@field hint string what the arguments are, shown wherever the command is offered
---@field default string? a starting point worth offering, e.g. "${Target.ID}"
---@field choices fun(): table? arguments this command can be given, as an array of
---{ label = string, args = string, group = string?, name = string? }; `group` sections a long list,
---and entries sharing one must be adjacent. `name` is what to call a button that runs this choice,
---for when the command's own name is not the useful one -- a button switching a discipline wants to
---be called after the discipline, not after `action`

---@class Command : CommandBase
---@field eventFunction function
---@field wrappedEventFunction function?
---@field phrasePatternOverrides table?
---@field registeredEvents table?
---@field argsSpec CommandArgs?
---@field actsOnSpeaker boolean?
---@field stateReader fun(args: string): boolean?
local Command = {}

Command.__index = Command
setmetatable(Command, {
    __call = function (cls, ...)
        return cls.new(...)
    end
})

---@param command string
---@param eventFunction function
---@param docs ChelpDocs
---@param phrasePatternOverrides table?
---@return Command
function Command.new(command, eventFunction, docs, phrasePatternOverrides)
    local self = setmetatable({}, Command)

    self.command = command
    self.eventFunction = eventFunction
    self.docs = docs
    self.phrasePatternOverrides = phrasePatternOverrides

    return self
end

---Declare what this command expects after its phrase. Anything that offers commands to a user
---(the hotbar button editor) can then ask for those arguments up front, instead of handing back
---a line that looks finished and silently does nothing -- `attack` with no spawn id is not a
---command, it is a no-op waiting to be confusing.
---@param argsSpec CommandArgs
---@return Command self so it can be chained onto Command.new
function Command:WithArgs(argsSpec)
    self.argsSpec = argsSpec
    return self
end

---Declare that this command flips something whose state can be read back. Anything that
---*presents* the command can then present it as that state: a hotbar button carrying
---`stick toggle` is drawn as the stick setting itself, lit while it is on. Without this a button
---is only text, and a toggle you cannot see the state of is half a button.
---
---The reader is handed the arguments exactly as the handler would receive them, and answers for
---the character it runs on. It returns nil when there is no single answer to give -- arguments
---naming nothing it recognizes, or several things that are not all in the same state -- and the
---caller shows nothing rather than guessing.
---@param reader fun(args: string): boolean?
---@return Command self so it can be chained onto Command.new
function Command:WithState(reader)
    self.stateReader = reader
    return self
end

---Mark a command that acts on whoever spoke it: "follow me", "move to me". Issuing one of
---these to yourself asks you to follow yourself, so the local channel is refused for it -- in
---the button editor, and by Commands.Dispatch if it is asked anyway.
---@return Command self so it can be chained onto Command.new
function Command:ActsOnSpeaker()
    self.actsOnSpeaker = true
    return self
end

return Command
