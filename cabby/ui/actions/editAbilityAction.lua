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

---@param liveAction Action
---@return AbilityAction
AbilityAction.new = function(liveAction)
    local self = setmetatable(TableUtils.DeepClone(liveAction) or {}, AbilityAction)

    if liveAction.luaEnabled == nil then liveAction.luaEnabled = false end

    self.enabled = true
    self.actionType = "ability"
    self.lua = liveAction.lua
    self.name = liveAction.name
    self.liveAction = liveAction
    self.luaEnabled = liveAction.luaEnabled

---@diagnostic disable-next-line: return-type-mismatch
    return self
end

return AbilityAction
