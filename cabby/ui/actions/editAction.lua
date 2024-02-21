local TableUtils = require("utils.TableUtils.TableUtils")

local Action = require("cabby.actions.action")
local Actions = require("cabby.actions.actions")
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

    if liveAction.actionType == nil then
        self.actionType = ActionType.Edit
        self.editing = true
    else
        self.actionType = liveAction.actionType
    end

    self.liveAction = liveAction
    self.name = liveAction.name
    self.enabled = liveAction.enabled
    self.lua = liveAction.lua
    self.luaEnabled = liveAction.luaEnabled
    self.end_type = liveAction.end_type
    self.end_threshold = liveAction.end_threshold

    return self
end

---@param actionType string
function EditAction:SwitchType(actionType)
    self.actionType = actionType

    if Actions.Get(self.actionType, self.name):EndCost() > 0 then
        self.end_type = self.liveAction.end_type or Action.valueTypes.Minimum.value
        if self.end_type == Action.valueTypes.Minimum.value then
            self.end_threshold = nil
        end
    else
        self.end_type = nil
    end
end

function EditAction:ResetMetaFields()
    self.name = nil
    self.lua = nil
    self.luaEnabled = false
    self.endurance = nil
    self.end_type = nil
    self.end_threshold = nil
end

function EditAction:CancelEdit()
    self.editing = false

    self.name = self.liveAction.name
    self.enabled = self.liveAction.enabled
    self.actionType = self.liveAction.actionType
    self.lua = self.liveAction.lua
    self.luaEnabled = self.liveAction.luaEnabled
    self.end_type = self.liveAction.end_type
    self.end_threshold = self.liveAction.end_threshold
end

function EditAction:SaveEdit()
    self.editing = false

    self.liveAction.name = self.name
    self.liveAction.enabled = self.enabled
    self.liveAction.actionType = self.actionType
    self.liveAction.lua = self.lua
    self.liveAction.luaEnabled = self.luaEnabled
    self.liveAction.end_type = self.end_type
    self.liveAction.end_threshold = self.end_threshold

    Global.configStore:SaveConfig()
end

return EditAction
