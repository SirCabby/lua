local TableUtils = require("utils.TableUtils.TableUtils")

---@class EditAction
----- Saved to config
---@field name string
---@field enabled boolean
---@field actionType string
---@field lua string Raw lua to evaluate
----- not saved to config
---@field liveAction table Table reference of unedited action
---@field editing boolean
local EditAction = {
    actionType = "none"
}
EditAction.__index = EditAction

setmetatable(EditAction, {
    __call = function (cls, ...)
        return cls.new(...)
    end
})

---@param liveAction table Table reference of unedited action
---@return EditAction
EditAction.new = function(liveAction)
    local self = setmetatable(TableUtils.DeepClone(liveAction) or {}, EditAction)

    if liveAction.enabled == nil then liveAction.enabled = true end

    self.actionType = "none"
    self.liveAction = liveAction
    self.name = liveAction.name
    self.enabled = liveAction.enabled
    self.lua = liveAction.lua

    return self
end

---@param actionType EditAction
function EditAction:SwitchType(actionType)
    local result = actionType.new(self.liveAction)
    result.editing = self.editing
    return result
end

function EditAction:CancelEdit()
    self.editing = false

    self.name = self.liveAction.name
    self.enabled = self.liveAction.enabled
    self.actionType = self.liveAction.actionType
    self.lua = self.liveAction.lua
end

function EditAction:SaveEdit()
    self.editing = false

    self.liveAction.name = self.name
    self.liveAction.enabled = self.enabled
    self.liveAction.actionType = self.actionType
    self.liveAction.lua = self.lua

    Global.configStore:SaveConfig()
end

return EditAction
