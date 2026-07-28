---@diagnostic disable: undefined-field
local mq = require("mq")

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

---@diagnostic disable-next-line: inject-field
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
    print("Owners Open: [" .. tostring(isOpen) .. "]")
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

---@param name string speaker who issued the command
---@return boolean hasPermission
function Owners:HasPermission(name)
    if name == nil then return false end

    -- we always take our own orders, without having to list ourselves as an owner. The local
    -- channel (Commands.Dispatch, /cself, hotbar buttons) speaks as this character, and that
    -- trust stops there: a *chat* line spoken by our own name (our broadcast looped back by
    -- eqbcs localecho) is owner-gated in protectChatHandler before any handler -- and so this
    -- check -- ever runs, so saying yes here does not widen what chat can make us do.
    local myName = mq.TLO.Me.CleanName()
    if myName ~= nil and name:lower() == myName:lower() then
        return true
    end

    return self._.data.open or self:IsOwner(name)
end

function Owners:Print()
    print("My Owners: [" .. StringUtils.Join(self._.data.list, ", ") .. "]")
end

---@return table owners
function Owners:GetOwnersList()
    return self._.data.list
end

return Owners
