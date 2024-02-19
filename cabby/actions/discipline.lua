---@diagnostic disable: undefined-field
local mq = require("mq")

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
        name = name
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
    return mq.TLO.Me.CombatAbilityReady(self:Name())
end

function Discipline:DoAction()
    mq.cmd("/disc " .. self:Name())
end

return Discipline
