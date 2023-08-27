---@diagnostic disable: duplicate-set-field

---@class State
local State = { key = "State" }

function State.Init() end

---@return boolean isBusy true if this state has more work to do before continuing to child states
function State.Go() return false end

function State.BuildMenu()
    ImGui.Text("No menu exists yet for this page")
end
