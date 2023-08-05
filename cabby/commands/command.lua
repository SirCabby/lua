---@class Command
---@field id string
---@field phrase string
---@field eventFunction function
---@field helpFunction function
---@field registeredEvents array
local Command = {}

---@param id string
---@param phrase string
---@param eventFunction function
---@param helpFunction function
---@param phrasePatternOverrides array?
---@return Command
function Command.new(id, phrase, eventFunction, helpFunction, phrasePatternOverrides)
    local result = {}

    result.id = id
    result.phrase = phrase
    result.eventFunction = eventFunction
    result.helpFunction = helpFunction
    result.phrasePatternOverrides = phrasePatternOverrides

    return result
end

return Command
