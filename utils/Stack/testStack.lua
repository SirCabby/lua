local mq = require("mq")
local Debug = require("utils.Debug.Debug")
local Stack = require("utils.Stack.Stack")

mq.cmd("/mqclear")

Debug:new()
--Debug.toggles[Stack.key] = true

---@type Stack
local st = Stack:new()

assert(#st.stack == 0, "Stack created with entries")
print("Stack created")

st:push("foo")
assert(st:peek() == "foo", "Failed to push string \"foo\"")
print("Stack: [\"foo\"]")

st:push(2)
assert(st:peek() == 2, "Failed to push number (2)")
print("Stack: [\"foo\", 2]")

st:push(3):push(4)
print("Stack: [\"foo\", 2, 3, 4]")
assert(st:pop(3) == 3, "Failed to pop correct index (3)")
print("Stack: [\"foo\", 2, 4]")
assert(st:pop() == 4, "Failed to pop correct item (4)")
print("Stack: [\"foo\", 2]")
st:pop()
print("Stack: [\"foo\"]")
st:pop()
print("Stack: []")
st:pop()
print("Stack: []")

assert(#st.stack == 0, "Stack should be empty")
