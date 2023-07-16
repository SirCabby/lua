local Debug = require("utils.Debug.Debug")

---@class Stack
local Stack = { author = "judged", key = "Stack" }

---@meta Stack
---@param obj any nil will be converted to string "nil"
---@return Stack - self
function Stack:Push(obj) end
---@param index? number 
---@return any
function Stack:Pop(index) end
---@return any 
function Stack:Peek() end

function Stack:new()
    local stack = { _stack = {} }
    Debug:new()

    local function DebugLog(str)
        Debug:Log(Stack.key, str)
    end

    function stack:Push(obj)
        if obj == nil then obj = "nil" end
        DebugLog("Pushed to top of stack: " .. tostring(obj))
        table.insert(stack._stack, obj)
        return stack
    end

    function stack:Pop(index)
        index = index or #stack._stack
        local popped = table.remove(stack._stack, index)
        DebugLog("Popped from stack at index [" .. tostring(index) .. "]: " .. tostring(popped))
        return popped
    end

    function stack:Peek()
        local peeked = stack._stack[#stack._stack]
        DebugLog("Peeked from top of stack: " .. tostring(peeked))
        return peeked
    end

    return stack
end

return Stack
