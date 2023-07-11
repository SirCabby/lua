local mq = require("mq")
local FileSystem = require("utils.FileSystem")
local StringUtils = require("utils.StringUtils.StringUtils")

local args = {...}
local LUA_DIR = mq.TLO.Lua.Dir()

---Adds ".lua" to end of supplied fileName
---@param fileName string @the file to find, that is possibly missing an extension of .lua
---@return string @The file name is returned, and ensured to have it suffixed with .lua
local function AddLuaExtensionIfMissing(fileName)
    if not string.find(string.lower(fileName), ".lua") then
        return fileName .. ".lua"
    end
    return fileName
end

-- start
do
    if args[1] == nil then
        print("Must supply a lua file name to run. Usage:")
        print("-- /lua run luarun somefile.lua")
        print("Alternatively, setup an alias via:")
        print("-- /alias /luar /lua run luarun somefile.lua")
        print("Alias usage:")
        print("-- /luar somefile.lua")
        mq.exit()
    end

    local luaFileName = AddLuaExtensionIfMissing(args[1])
    local luaFile = FileSystem.FindFile(LUA_DIR, luaFileName, true)
    if luaFile == "" then
        print("Unable to find lua file to run: " .. luaFileName)
        mq.exit()
    end
    
    luaFile = StringUtils.Split(luaFile, "\\lua\\")[2]
    print("Found file: " .. luaFile)

    mq.cmdf("/lua run %s", luaFile)
end
