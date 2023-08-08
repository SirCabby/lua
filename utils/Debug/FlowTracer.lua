---@diagnostic disable: undefined-field
local Stack = require("utils.Stack.Stack")
local StopWatch = require("utils.Time.StopWatch")

---@class FlowTracer
local FlowTracer = { author = "judged", key = "FlowTracer" }
FlowTracer.__index = FlowTracer

setmetatable(FlowTracer, {
    __call = function (cls, ...)
        return cls.new(...)
    end
})

function FlowTracer.new()
    local self = setmetatable({}, FlowTracer)

    self._ = {
        callstack = Stack.new() -- { key = "", message = "", stopwatch = sw }
    }

    return self
end

local function getKey(self)
    local peeked = self._.callstack:Peek()
    if peeked == nil then
        return 1
    end
    return peeked.key + 1
end

local function getIndent(count)
    local result = " "
    count = count or 1
    for i = 1, count do
        result = result .. "    "
    end
    return result
end

function FlowTracer:open(message)
    local newStart = {
        message = message,
        stopwatch = StopWatch.new(true),
        key = getKey(self)
    }

    local parent = self._.callstack:Peek()
    if parent ~= nil then
        message = message .. " at parent split: " .. parent.stopwatch:get_time()
    end
    print("[" .. tostring(newStart.key) .. ": Starting] " .. getIndent(newStart.key) .. message)

    self._.callstack:Push(newStart)
    return newStart.key
end

function FlowTracer:split(message)
    local parent = self._.callstack:Peek()
    if parent ~= nil then
        print("[" .. tostring(parent.key) .. ": Split   ] " .. getIndent(parent.key) .. message .. " at: " .. parent.stopwatch:get_time())
    else
        print("[root] " .. message)
    end
end

function FlowTracer:close(key)
    local peeked = self._.callstack:Peek()
    
    if peeked == nil then
        print("[root] Tried to close at root level. Key: " .. tostring(key))
    elseif key > peeked.key then
        print("[" .. tostring(peeked.key) .. ": Re-Close?] Attempted to close a flow at a level deeper than current open. Key: " .. tostring(peeked.key))
    elseif key < peeked.key then
        print("[" .. tostring(key) .. ": Early Close] Closing a flow without closing a child flow first")

        while peeked ~= nil and key ~= peeked.key and peeked.key > 0 do
            self._.callstack:Pop()
            print("[" .. tostring(key) .. ": Closed Orphaned Flow] " .. getIndent(peeked.key) ..  "Key: " .. tostring(peeked.key) .. ". Child time: " .. tostring(peeked.stopwatch:get_time()))
            peeked = self._.callstack:Peek()
        end

        self:close(key)
    elseif key == peeked.key then
        local popped = self._.callstack:Pop()
        print("[" .. tostring(key) .. ": Finished] " .. getIndent(popped.key) .. popped.message .. " at: " .. popped.stopwatch:get_time())
    else
        print("Failed to close key: "..tostring(key))
    end
end

return FlowTracer
