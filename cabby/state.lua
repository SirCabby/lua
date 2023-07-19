
---@class State
local State = {}

---@meta State
function State:Init() end
---@return boolean hasAction true if there's action to take, false to sleep
function State:Check() end
---To be called when the state is allowed to perform action. May be resuming from a prior interrupt.
function State:Go() end
