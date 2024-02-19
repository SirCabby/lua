---@diagnostic disable: undefined-field
local mq = require("mq")

local Timer = require("utils.Time.Timer")

local Status = require("cabby.status")

---@class Skill : ActionType
local Skill = {}
Skill.__index = Skill

setmetatable(Skill, {
    __call = function (cls, ...)
        return cls.new(...)
    end
})

---@param name string
---@return Skill
Skill.new = function(name)
    local self = setmetatable({}, Skill)

---@diagnostic disable-next-line: inject-field
    self._ = {
        name = name,
        timer = Timer.new(500)
    }

    return self
end

---@return string name
function Skill:Name()
    return self._.name
end

---@return boolean
function Skill:Damage()
    return self._.damage
end

---@return boolean
function Skill:Facing()
    return self._.facing
end

---@return boolean
function Skill:Fear()
    return self._.fear
end

---@return boolean
function Skill:Primary()
    return self._.primary
end

---@return boolean
function Skill:Secondary()
    return self._.secondary
end

---@return boolean
function Skill:Push()
    return self._.push
end

---@return boolean
function Skill:Stun()
    return self._.stun
end

---@return boolean
function Skill:Targeted()
    return self._.targeted
end

---@return boolean
function Skill:Hate()
    return self._.hate
end

---@return string
function Skill:ActionType()
    return "ability"
end

---@return boolean
function Skill:HasAction()
    if self:Name() == "none" then return true end
    local skillValue = mq.TLO.Me.Skill(self:Name())()
    return type(skillValue) == "number" and skillValue > 0
end

---@return boolean
function Skill:IsReady()
    if self:Name() == "none" then return true end
    if self:Targeted() and (mq.TLO.Target.ID() < 1 or mq.TLO.Target.Distance() > 14) then return false end
    if self:Facing() and not Status.IsFacingTarget() then return false end

    return mq.TLO.Me.AbilityReady(self:Name())() and self._.timer:timer_expired()
end

function Skill:DoAction()
    if self:Name() == "none" then return end

    ---@type Timer
    self._.timer = self._.timer

    mq.cmd('/doability "' .. self:Name() .. '"')
    self._.timer:reset()
end

return Skill
