---@diagnostic disable: undefined-field
local Debug = require("utils.Debug.Debug")

---@class Stack
local Stack = { author = "judged", key = "Stack" }

Stack.__index = Stack
setmetatable(Stack, {
    __call = function (cls, ...)
        return cls.new(...)
    end
})

function Stack.new()
    local self = setmetatable({}, Stack)

    self._ = {}
    self._.stack = {}

    return self
end

local function DebugLog(str)
    Debug.Log(Stack.key, str)
end

---@param obj any
---@return Stack self fluent for fast pushing
function Stack:Push(obj)
    if obj == nil then obj = "nil" end
    DebugLog("Pushed to top of stack: " .. tostring(obj))
    table.insert(self._.stack, obj)
    return self
end

function Stack:Pop(index)
    index = index or #self._.stack
    local popped = table.remove(self._.stack, index)
    DebugLog("Popped from stack at index [" .. tostring(index) .. "]: " .. tostring(popped))
    return popped
end

function Stack:Peek()
    local peeked = self._.stack[#self._.stack]
    DebugLog("Peeked from top of stack: " .. tostring(peeked))
    return peeked
end

return Stack
