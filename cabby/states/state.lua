
---@class State
local State = {}

function State.Init() end

---@return boolean isBusy true if this state has more work to do before continuing to child states
function State.Go() return false end
