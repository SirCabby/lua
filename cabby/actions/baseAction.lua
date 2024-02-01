local TableUtils = require("utils.TableUtils.TableUtils")

---@class BaseAction
---@field name string
---@field enabled boolean
---@field actionType string
---@field range number
---@field requiresTarget boolean
---@field facingTarget boolean
---@field LoS boolean
---@field lua string Raw lua to evaluate
----- not saved to config
---@field liveAction table Table reference of unedited action
---@field editing boolean
local BaseAction = {
    actionType = "none"
}
BaseAction.__index = BaseAction

setmetatable(BaseAction, {
    __call = function (cls, ...)
        return cls.new(...)
    end
})

---@param liveAction table Table reference of unedited action
---@return BaseAction
BaseAction.new = function(liveAction)
    local self = setmetatable(TableUtils.DeepClone(liveAction) or {}, BaseAction)

    self.liveAction = liveAction

    return self
end

---@param actionType BaseAction
function BaseAction:SwitchType(actionType)
    return actionType.new(self.liveAction)
end

function BaseAction:CancelEdit()
    self.editing = false

    self.name = self.liveAction.name
    self.enabled = self.liveAction.enabled
    self.actionType = self.liveAction.actionType
    self.range = self.liveAction.range
    self.requiresTarget = self.liveAction.requiresTarget
    self.facingTarget = self.liveAction.facingTarget
    self.LoS = self.liveAction.LoS
    self.lua = self.liveAction.lua
end

function BaseAction:SaveEdit()
    self.editing = false

    self.liveAction.name = self.name
    self.liveAction.enabled = self.enabled
    self.liveAction.actionType = self.actionType
    self.liveAction.range = self.range
    self.liveAction.requiresTarget = self.requiresTarget
    self.liveAction.facingTarget = self.facingTarget
    self.liveAction.LoS = self.LoS
    self.liveAction.lua = self.lua

    Global.configStore:SaveConfig()
end

return BaseAction
