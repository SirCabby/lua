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

---@param config Config
---@param configLocation string dot-separated object path to owners config storage location -ex: MyClass.key .. "." .. Sub.key
---@return Owners
function Owners:new(config, configLocation)
    local owners = {}

    ---@param str string
    local function DebugLog(str)
        Debug.Log(Owners.key, str)
    end

    function owners:GetOwners()
        local configStorageLocationSplit = StringUtils.Split(configLocation, ".")
        local locationTraverse = config:GetConfigRoot()
        for i = 1, #configStorageLocationSplit do
            if locationTraverse[configStorageLocationSplit[i]] == nil then
                DebugLog("Adding new Owners location that was not initialized to a table. Location: [" .. StringUtils.Join({ unpack(configStorageLocationSplit, 1, i) }, ".") .. "]")
                locationTraverse[configStorageLocationSplit[i]] = {}
            end

            if type(locationTraverse) ~= "table" then
                error("Owners config location contained a non-table entry.  Unable to save owners config. Location: [" .. StringUtils.Join({ unpack(configStorageLocationSplit, 1, i) }, ".") .. "]")
            end

            locationTraverse = locationTraverse[configStorageLocationSplit[i]]
        end

        local ownersKey = Owners.key:lower()
        if locationTraverse[ownersKey] == nil then
            locationTraverse[ownersKey] = {}
        end

        if not TableUtils.IsArray(locationTraverse[ownersKey]) then
            error("Owners config location was not an array")
        end

        return locationTraverse[ownersKey]
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
