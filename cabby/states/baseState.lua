---@diagnostic disable: duplicate-set-field

---@class BaseState
local BaseState = { key = "BaseState" }

function BaseState.Init() end

---@return boolean isBusy true if this state has more work to do before continuing to child states
function BaseState.Go() return false end

function BaseState.BuildMenu()
    ImGui.Text("No menu exists yet for this page")
end

---@return boolean isEnabled
function BaseState.IsEnabled()
    print("warn: no IsEnabled override for this state")
    return false
end

---@param isEnabled boolean
function BaseState.SetEnabled(isEnabled)
    print("warn: no SetEnabled override for this state")
    return {}
end
