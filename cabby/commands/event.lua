---@class Event
---@field id string
---@field phrase string
---@field eventFunction function
---@field helpFunction function
---@field reregister boolean reregister this event on event updates for last order preservation
local Event = {}

Event.__index = Event
setmetatable(Event, {
    __call = function (cls, ...)
        return cls.new(...)
    end
})

---@param id string
---@param phrase string
---@param eventFunction function
---@param helpFunction function
---@param reregister boolean? reregister this event on event updates for last order preservation
---@return Event
function Event.new(id, phrase, eventFunction, helpFunction, reregister)
    local self = setmetatable({}, Event)

    self.id = id
    self.phrase = phrase
    self.eventFunction = eventFunction
    self.helpFunction = helpFunction
    self.reregister = reregister or false

    return self
end

return Event
