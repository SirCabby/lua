local Debug = require("utils.Debug.Debug")

---@class Stack
---@field stack table
local Stack = { author = "judged", key = "Stack" }

function Stack:new()
    local stack = {}
    setmetatable(stack, self)
    self.__index = self
    stack.stack = {}
    Debug:new()
    return stack
end

local function DebugLog(str)
    Debug:Log(Stack.key, str)
end

---@param obj any
---@return Stack - self
function Stack:push(obj)
    DebugLog("Pushed to top of stack: " .. tostring(obj))
    table.insert(self.stack, obj)
    return self
end

---@param index? number 
---@return any
function Stack:pop(index)
    index = index or #self.stack
    DebugLog("Popped from top of stack: " .. tostring(self.stack[index]))
    return table.remove(self.stack, index)
end

---@return any 
function Stack:peek()
    DebugLog("Peeked from top of stack: " .. tostring(self.stack[#self.stack]))
    return self.stack[#self.stack]
end

return Stack
