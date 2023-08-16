---@class Command
---@field id string
---@field phrase string
---@field eventFunction function
---@field helpFunction function
---@field registeredEvents array
local Command = {}

Command.__index = Command
setmetatable(Command, {
    __call = function (cls, ...)
        return cls.new(...)
    end
})

---@param phrase string
---@param eventFunction function
---@param helpFunction function
---@param phrasePatternOverrides array?
---@return Command
function Command.new(phrase, eventFunction, helpFunction, phrasePatternOverrides)
    local self = setmetatable({}, Command)

    self.phrase = phrase
    self.eventFunction = eventFunction
    self.helpFunction = helpFunction
    self.phrasePatternOverrides = phrasePatternOverrides

    return self
end

return Command
