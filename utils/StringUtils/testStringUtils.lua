local mq = require("mq")
local StringUtils = require("utils.StringUtils.StringUtils")

mq.cmd("/mqclear")

StringUtils.debug = true

local testStr = "The big brown cow jumped over the moon"

local splitStr = StringUtils.Split(testStr)
assert(#splitStr == 8, "Incorrect number of split strings: " .. tostring(#splitStr))

local joinedStr = StringUtils.Join(splitStr, " ")
assert(testStr == joinedStr, "Did not join string correctly")

local charArray = StringUtils.ToCharArray(testStr)
assert(#charArray == 38, "Failed to create char array")

local whitespaceStr = "   trim this . "
local trimmedStr = StringUtils.TrimFront(whitespaceStr)
assert(trimmedStr == "trim this . ", "Failed to trim whitespace from front of string: (" .. trimmedStr .. ")")
