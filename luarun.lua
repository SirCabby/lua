--region includes===========================================================
local mq = require("mq")
require "filesystem.filesystem"
--endregion includes===========================================================

--region fields=================================================================
local args = {...}
local LUA_DIR = mq.TLO.Lua.Dir()
--endregion fields=================================================================

--region local functions=========================================================
--- Adds ".lua" to end of supplied fileName
local function AddLuaExtensionIfMissing(fileName)
    if not string.find(string.lower(fileName), ".lua") then
        return fileName..".lua"
    end
    return fileName
end
--endregion local functions=========================================================

--region start===================================================================
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
    local luaFile = FindFile(LUA_DIR, luaFileName, true)
    if luaFile == nil then
        print("Unable to find lua file to run: "..luaFileName)
        mq.exit()
    else
        print("Found file: "..luaFile)
    end

    mq.cmdf("/lua run %s", luaFile)
end
--endregion start===================================================================