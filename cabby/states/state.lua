---@diagnostic disable: duplicate-set-field

---@class State
local State = { key = "State" }

function State.Init() end

---@return boolean isBusy true if this state has more work to do before continuing to child states
function State.Go() return false end

function State.BuildMenu()
    ImGui.Text("No menu exists yet for this page")
end

---@return boolean isEnabled
function State.IsEnabled()
    print("warn: no IsEnabled override for this state")
    return false
end

---@param isEnabled boolean
function State.SetEnabled(isEnabled)
    print("warn: no SetEnabled override for this state")
    return {}
end
