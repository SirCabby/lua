local Debug = require("utils.Debug.Debug")
local StringUtils = require("utils.StringUtils.StringUtils")
local TableUtils = require("utils.TableUtils.TableUtils")

---@class Owners
local Owners = { author = "judged", key = "Owners" }

---@meta Owners
---Adds a new owner
---@param name string
function Owners:Add(name) end
---Removes a current owner
---@param name string
function Owners:Remove(name) end
---Returns true if name is listed as an owner
---@param name string
---@return boolean
function Owners:IsOwner(name) end
function Owners:Print() end
---@return array
function Owners:GetOwners() end

---@param config Config config owning the configData table
---@param configData table table to append owners data to
---@return Owners
function Owners:new(config, configData)
    local owners = {}

    ---@param str string
    local function DebugLog(str)
        Debug.Log(Owners.key, str)
    end

    function owners:GetOwners()
        local ownersKey = Owners.key:lower()
        if configData[ownersKey] == nil then
            configData[ownersKey] = {}
        end

        if not TableUtils.IsArray(configData[ownersKey]) then
            error("Owners config location was not an array")
        end

        return configData[ownersKey]
    end

    local ownersArray = owners:GetOwners()

    function owners:Add(name)
        name = name:lower()
        if not TableUtils.ArrayContains(ownersArray, name) then
            ownersArray[#ownersArray + 1] = name
            print("Added [" .. name .. "] as Owner")
            config:SaveConfig()
            return
        end
        DebugLog(name .. " was already an owner")
    end

    function owners:Remove(name)
        name = name:lower()
        if TableUtils.ArrayContains(ownersArray, name) then
            TableUtils.RemoveByValue(ownersArray, name)
            print("Removed [" .. name .. "] as Owner")
            config:SaveConfig()
            return
        end
        DebugLog(name .. " was not an owner")
    end

    function owners:IsOwner(name)
        return TableUtils.ArrayContains(ownersArray, name:lower())
    end

    function owners:Print()
        print("My Owners: [" .. StringUtils.Join(ownersArray, ", ") .. "]")
    end

    config:SaveConfig()

    return owners
end

return Owners
