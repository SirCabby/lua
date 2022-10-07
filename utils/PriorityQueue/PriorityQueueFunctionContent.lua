---@class FunctionContent
---@field identity string
---@field Call function
local FunctionContent = { author = "judged" }

---Optional content to use in PriorityQueueJob that enables printing of function content
---@param identity string Printable identity of this work
---@param func fun(...) : boolean Function to store in queue, returns boolean true if is complete, false to reset visibility
---@return FunctionContent
function FunctionContent:new(identity, func)
    local functionContent = {}
    setmetatable(functionContent, self)
    self.__index = self
    functionContent.identity = identity
    functionContent.Call = func

    return functionContent
end

return FunctionContent
