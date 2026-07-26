---What a command expects after its phrase. Optional: a command that declares nothing is one
---that takes no arguments, or one whose arguments nothing but the user knows about.
---@class CommandArgs
---@field required boolean true when the command can do nothing at all without arguments
---@field hint string what the arguments are, shown wherever the command is offered
---@field default string? a starting point worth offering, e.g. "${Target.ID}"

---@class Command : CommandBase
---@field eventFunction function
---@field wrappedEventFunction function?
---@field phrasePatternOverrides table?
---@field registeredEvents table?
---@field argsSpec CommandArgs?
---@field actsOnSpeaker boolean?
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

---Mark a command that acts on whoever spoke it: "follow me", "move to me". Issuing one of
---these to yourself asks you to follow yourself, so the local channel is refused for it -- in
---the button editor, and by Commands.Dispatch if it is asked anyway.
---@return Command self so it can be chained onto Command.new
function Command:ActsOnSpeaker()
    self.actsOnSpeaker = true
    return self
end

return Command
