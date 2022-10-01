local mq = require("mq")
local StringUtils = require("utils.StringUtils.StringUtils")

mq.cmd("/mqclear")

local testStr = "The big brown cow jumped over the moon"

local splitStr = StringUtils.Split(testStr)
assert(#splitStr == 8, "Incorrect number of split strings: "..tostring(#splitStr))
for _,str in ipairs(splitStr) do
    print(str)
end

local joinedStr = StringUtils.Join(splitStr)
print(joinedStr)
assert(testStr == joinedStr, "Did not join string correctly")

local charArray = StringUtils.ToCharArray(testStr)
assert(#charArray == 38, "Failed to create char array")
