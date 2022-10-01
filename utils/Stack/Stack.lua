
---@class Stack
---@field stack table
local Stack = {}

function Stack:new()
    local stack = {}
    setmetatable(stack, self)
    self.__index = self
    stack.stack = {}
    return stack
end

---@param obj any
---@return Stack - self
function Stack:push(obj)
    table.insert(self.stack, obj)
    return self
end

---@param index? number 
---@return any
function Stack:pop(index)
    index = index or #self.stack
    return table.remove(self.stack, index)
end

---@return any 
function Stack:peek()
    return self.stack[#self.stack]
end

return Stack
