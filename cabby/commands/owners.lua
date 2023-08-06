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

    local ownersKey = Owners.key:lower()
    if configData[ownersKey] == nil then
        configData[ownersKey] = {}
    end

    if not TableUtils.IsArray(configData[ownersKey]) then
        TableUtils.Print(configData)
        error("Owners config location was not an array")
    end

    self._.data = configData[ownersKey]

    return self
end

---@param str string
local function DebugLog(str)
    Debug.Log(Owners.key, str)
end

function Owners:GetOwners()
    return self._.data
end

function Owners:Add(name)
    name = name:lower()
    if not TableUtils.ArrayContains(self._.data, name) then
        self._.data[#self._.data + 1] = name
        print("Added [" .. name .. "] as Owner")
        self._.config:SaveConfig()
        return
    end
    DebugLog(name .. " was already an owner")
end

function Owners:Remove(name)
    name = name:lower()
    if TableUtils.ArrayContains(self._.data, name) then
        TableUtils.RemoveByValue(self._.data, name)
        print("Removed [" .. name .. "] as Owner")
        self._.config:SaveConfig()
        return
    end
    DebugLog(name .. " was not an owner")
end

function Owners:IsOwner(name)
    return TableUtils.ArrayContains(self._.data, name:lower())
end

function Owners:Print()
    print("My Owners: [" .. StringUtils.Join(self._.data, ", ") .. "]")
end

return Owners
