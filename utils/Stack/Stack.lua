
---@class Stack
---@field stack table
local Stack = { author = "judged", debug = false }

function Stack:new()
    local stack = {}
    setmetatable(stack, self)
    self.__index = self
    stack.stack = {}
    return stack
end

local function Debug(str)
    if Stack.debug then print(str) end
end

---@param obj any
---@return Stack - self
function Stack:push(obj)
    Debug("Pushed to top of stack: " .. tostring(obj))
    table.insert(self.stack, obj)
    return self
end

---@param index? number 
---@return any
function Stack:pop(index)
    index = index or #self.stack
    Debug("Popped from top of stack: " .. tostring(self.stack[index]))
    return table.remove(self.stack, index)
end

---@return any 
function Stack:peek()
    Debug("Peeked from top of stack: " .. tostring(self.stack[#self.stack]))
    return self.stack[#self.stack]
end

return Stack
