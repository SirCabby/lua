local TableUtils = require("utils.TableUtils.TableUtils")

local BaseAction = require("cabby.actions.baseAction")

---@class AbilityAction : BaseAction
local AbilityAction = {
    actionType = "ability"
}
AbilityAction.__index = BaseAction

setmetatable(AbilityAction, {
    __call = function (cls, ...)
        return cls.new(...)
    end
})

AbilityAction.new = function(liveAction)
    local self = setmetatable(TableUtils.DeepClone(liveAction) or {}, AbilityAction)

    self.actionType = "ability"
    self.range = 14
    self.requiresTarget = true
    self.facingTarget = true
    self.LoS = true
    self.liveAction = liveAction

    return self
end

return AbilityAction
