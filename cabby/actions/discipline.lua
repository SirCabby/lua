---@diagnostic disable: undefined-field
local mq = require("mq")

local Timer = require("utils.Time.Timer")

---@class Discipline : ActionType
local Discipline = {}
Discipline.__index = Discipline

setmetatable(Discipline, {
    __call = function (cls, ...)
        return cls.new(...)
    end
})

---@param name string
---@return Discipline
Discipline.new = function(name)
    local self = setmetatable({}, Discipline)

---@diagnostic disable-next-line: inject-field
    self._ = {
        name = name,
        timer = Timer.new(500)
    }

    return self
end

---@return string name
function Discipline:Name()
    return self._.name
end

---@return string
function Discipline:ActionType()
    return "discipline"
end

---@return boolean
function Discipline:HasAction()
    return mq.TLO.Me.CombatAbility(self:Name()).ID() == nil
end

---@return boolean
function Discipline:IsReady()
    ---@type Timer
    self._.timer = self._.timer
    return mq.TLO.Me.CombatAbilityReady(self:Name())() and self._.timer:timer_expired()
end

function Discipline:DoAction()
    ---@type Timer
    self._.timer = self._.timer

    mq.cmd("/disc " .. self:Name())
    self._.timer:reset()
end

return Discipline
