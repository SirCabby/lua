---@class Command : CommandType
---@field eventFunction function
---@field phrasePatternOverrides table?
---@field registeredEvents table?
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

return Command
