local TableUtils = require("utils.TableUtils.TableUtils")

local EditAction = require("cabby.ui.actions.editAction")

---@class AbilityAction : EditAction
local AbilityAction = {
    actionType = "ability"
}
AbilityAction.__index = EditAction

setmetatable(AbilityAction, {
    __call = function (cls, ...)
        return cls.new(...)
    end
})

AbilityAction.new = function(liveAction)
    local self = setmetatable(TableUtils.DeepClone(liveAction) or {}, AbilityAction)

    self.enabled = true
    self.actionType = "ability"
    self.lua = ""
    self.name = liveAction.name
    self.liveAction = liveAction

    return self
end

return AbilityAction
