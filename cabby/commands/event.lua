---@class Event : CommandBase
---@field id string
---@field eventFunction function
---@field wrappedEventFunction function?
---@field reregister boolean reregister this event on event updates for last order preservation
local Event = {}

Event.__index = Event
setmetatable(Event, {
    __call = function (cls, ...)
        return cls.new(...)
    end
})

---@param id string
---@param command string
---@param eventFunction function
---@param docs ChelpDocs
---@param reregister boolean? reregister this event on event updates for last order preservation
---@return Event
function Event.new(id, command, eventFunction, docs, reregister)
    local self = setmetatable({}, Event)

    self.id = id
    self.command = command
    self.eventFunction = eventFunction
    self.docs = docs
    self.reregister = reregister or false

    return self
end

return Event
