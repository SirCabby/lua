local TableUtils = require("utils.TableUtils.TableUtils")

local ActionType = require("cabby.actions.actionType")

---@class EditAction : Action
---@field liveAction Action Table reference of unedited action
---@field editing boolean
local EditAction = {}
EditAction.__index = EditAction

setmetatable(EditAction, {
    __call = function (cls, ...)
        return cls.new(...)
    end
})

---@param liveAction Action Table reference of unedited action
---@return EditAction
EditAction.new = function(liveAction)
    local self = setmetatable(TableUtils.DeepClone(liveAction) or {}, EditAction)

    if liveAction.enabled == nil then liveAction.enabled = true end
    if liveAction.luaEnabled == nil then liveAction.luaEnabled = false end

    self.actionType = ActionType.Edit
    self.liveAction = liveAction
    self.name = liveAction.name
    self.enabled = liveAction.enabled
    self.lua = liveAction.lua
    self.luaEnabled = liveAction.luaEnabled

    return self
end

---@param actionType string
function EditAction:SwitchType(actionType)
    self.actionType = actionType
end

function EditAction:ResetMetaFields()
    self.name = nil
    self.lua = nil
    self.luaEnabled = false
end

function EditAction:CancelEdit()
    self.editing = false

    self.name = self.liveAction.name
    self.enabled = self.liveAction.enabled
    self.actionType = self.liveAction.actionType
    self.lua = self.liveAction.lua
    self.luaEnabled = self.liveAction.luaEnabled
end

function EditAction:SaveEdit()
    self.editing = false

    self.liveAction.name = self.name
    self.liveAction.enabled = self.enabled
    self.liveAction.actionType = self.actionType
    self.liveAction.lua = self.lua
    self.liveAction.luaEnabled = self.luaEnabled

    Global.configStore:SaveConfig()
end

return EditAction
