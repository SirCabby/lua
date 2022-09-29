local StringUtils = require("utils.StringUtils.StringUtils")

local testStr = "The big brown cow jumped over the moon"

local splitStr = StringUtils.Split(testStr)
assert(#splitStr == 8, "Incorrect number of split strings: "..tostring(#splitStr))
for _,str in ipairs(splitStr) do
    print(str)
end

local joinedStr = StringUtils.Join(splitStr)
print(joinedStr)
assert(testStr == joinedStr, "Did not join string correctly")
