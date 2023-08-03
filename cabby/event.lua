---@class Event
---@field id string
---@field phrase string
---@field eventFunction function
---@field helpFunction function
local Event = {}

---@param id string
---@param phrase string
---@param eventFunction function
---@param helpFunction function
---@return Event
function Event.new(id, phrase, eventFunction, helpFunction)
    local result = {}

    result.id = id
    result.phrase = phrase
    result.eventFunction = eventFunction
    result.helpFunction = helpFunction

    return result
end

return Event
