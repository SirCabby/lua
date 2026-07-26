local Actions = require("cabby.actions.actions")

--- Pretends to be what is stored in action config stores
---@class Action
---@field name string
---@field actionType string
---@field enabled boolean
---@field luaEnabled boolean
---@field lua string
--- Specialty fields
---@field end_type string
---@field end_threshold number
local Action = {
    valueTypes = {
        Raw = { value = "raw", display = "Raw" },
        Percent = { value = "percent", display = "Percent" },
        Minimum = { value = "minimum", display = "Minimum" }
    }
}

---A slot that has never been switched off is on: `enabled` is absent from actions saved before
---the switch existed, and from one that was just added.
---@param action Action
---@return boolean isEnabled
function Action.IsEnabled(action)
    return action.enabled ~= false
end

---Switch a slot on or off. This is the running config, not something staged for a Save: the
---switch is how an action is taken out of the rotation mid-fight, from the menu checkbox or from
---a hotbar button, so it is written where the state machine reads it and persisted at once.
---@param action Action
---@param enabled boolean
function Action.SetEnabled(action, enabled)
    action.enabled = enabled == true
    Global.configStore:SaveConfig()
end

---@param action Action
---@return boolean isLuaReady Returns true to continue executing action, false to abort action
function Action.GetLuaResult(action)
    if not action.luaEnabled then return true end
    local succeeded, result = pcall(function() return loadstring(action.lua:sub(3, -3))() end) -- Unescape [[]]
    if not succeeded then
        print("Failed to read lua on action [" .. action.actionType .. ": " .. action.name .. "]")
        result = false
    end
    return result
end

---@param action Action
---@return ActionType? actionType
function Action.GetActionType(action)
    return Actions.Get(action.actionType, action.name)
end

return Action
