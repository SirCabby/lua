---@class Event
---@field id string
---@field phrase string
---@field eventFunction function
---@field helpFunction function
---@field reregister boolean reregister this event on event updates for last order preservation
local Event = {}

---@param id string
---@param phrase string
---@param eventFunction function
---@param helpFunction function
---@param reregister boolean? reregister this event on event updates for last order preservation
---@return Event
function Event.new(id, phrase, eventFunction, helpFunction, reregister)
    local result = {}

    result.id = id
    result.phrase = phrase
    result.eventFunction = eventFunction
    result.helpFunction = helpFunction
    result.reregister = reregister or false

    return result
end

return Event
