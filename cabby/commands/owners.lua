---@diagnostic disable: undefined-field
local Debug = require("utils.Debug.Debug")
local StringUtils = require("utils.StringUtils.StringUtils")
local TableUtils = require("utils.TableUtils.TableUtils")

---@class Owners
local Owners = { author = "judged", key = "Owners" }

Owners.__index = Owners
setmetatable(Owners, {
    __call = function (cls, ...)
        return cls.new(...)
    end
})

---@param config Config config owning the configData table
---@param configData table table to append owners data to
---@return Owners
function Owners.new(config, configData)
    local self = setmetatable({}, Owners)

    self._ = {}
    self._.config = config
    self._.data = configData

    if self._.data.open == nil then
        self._.data.open = false
    end
    if self._.data.list == nil then
        self._.data.list = {}
    end

    return self
end

---@param str string
local function DebugLog(str)
    Debug.Log(Owners.key, str)
end

function Owners:Open(isOpen)
    self._.data.open = isOpen
    self._.config:SaveConfig()
end

function Owners:IsOpen()
    return self._.data.open
end

function Owners:Add(name)
    name = name:lower()
    if not TableUtils.ArrayContains(self._.data.list, name) then
        self._.data.list[#self._.data.list + 1] = name
        print("Added [" .. name .. "] as Owner")
        self._.config:SaveConfig()
        return
    end
    DebugLog(name .. " was already an owner")
end

function Owners:Remove(name)
    name = name:lower()
    if TableUtils.ArrayContains(self._.data.list, name) then
        TableUtils.RemoveByValue(self._.data.list, name)
        print("Removed [" .. name .. "] as Owner")
        self._.config:SaveConfig()
        return
    end
    DebugLog(name .. " was not an owner")
end

function Owners:IsOwner(name)
    return TableUtils.ArrayContains(self._.data.list, name:lower())
end

function Owners:HasPermission(name)
    return self._.data.open or Owners:IsOwner(name)
end

function Owners:Print()
    print("My Owners: [" .. StringUtils.Join(self._.data.list, ", ") .. "]")
end

return Owners
