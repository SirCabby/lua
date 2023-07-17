local mq = require("mq")
local FileSystem = require("utils.FileSystem.FileSystem")
local StringUtils = require("utils.StringUtils.StringUtils")

local LUA_DIR = mq.TLO.Lua.Dir()

local foundTests = FileSystem.FindAllFiles(LUA_DIR, "test", true)

for i = 1, #foundTests do
    if FileSystem.FileExists(foundTests[i]) and foundTests[i]:match("^.+(%..+)$"):lower() == ".lua" then
        local luaFile = StringUtils.Split(foundTests[i], "\\lua\\")[2]
        print("Found file: " .. luaFile)

        mq.cmdf("/lua run %s", luaFile)
    end
end