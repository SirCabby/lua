local mq = require("mq")
---@type Config
local Config = require("utils.Config.Config")
local Debug = require("utils.Debug.Debug")
local Owners = require("utils.Owners.Owners")
local StringUtils = require("utils.StringUtils.StringUtils")
local TableUtils = require("utils.TableUtils.TableUtils")

---@class GeneralConfig
local GeneralConfig = {
    key = "General",
    keys = {
        version = "version",
        relayTellsTo = "relayTellsTo",
        activeChannels = "activeChannels"
    },
    channelTypes = {
        bc = "bc",
        tell = "tell",
        raid = "raid",
        group = "group"
    },
    eventIds = {
        tellToMe = "Tell to Me",
        groupInvited = "Invited to Group"
    }
}

---@param configFilePath string
---@return GeneralConfig
function GeneralConfig:new(configFilePath)
    local generalConfig = {}
    setmetatable(generalConfig, self)
    self.__index = self

    local config = Config:new(configFilePath)
    Debug:new()
    Owners:new(configFilePath)

    ---@param str string
    local function DebugLog(str)
        Debug:Log(GeneralConfig.key, str)
    end

    function GeneralConfig:GetRelayTellsTo()
        local generalConfig = config:GetConfig(GeneralConfig.key)
        return generalConfig[GeneralConfig.keys.relayTellsTo]
    end

    function GeneralConfig:SetRelayTellsTo(name)
        local generalConfig = config:GetConfig(GeneralConfig.key)
        DebugLog("Set relayTellsTo: [" .. name .. "]")
        generalConfig[GeneralConfig.keys.relayTellsTo] = name
        config:SaveConfig(GeneralConfig.key, generalConfig)
    end

    function GeneralConfig:TellToMe(speaker, message)
        local generalConfig = GeneralConfig:new(configFilePath)
        local tellTo = generalConfig:GetRelayTellsTo()
        if tellTo ~= speaker and mq.TLO.SpawnCount("npc " .. speaker)() < 1 then
            mq.cmd("/tell " .. tellTo .. " " .. speaker .. " told me: " .. message)
        end
        return true
    end

    function GeneralConfig:GroupInvited(speaker)
        if Owners:IsOwner(speaker) then
            DebugLog("Joining group of speaker [" .. speaker .. "]")
            mq.cmd("/invite")
        else
            DebugLog("Declining group of speaker [" .. speaker .. "]")
            mq.cmd("/disband")
        end
    end

    ---@return array
    function GeneralConfig:GetActiveChannels()
        local generalConfig = config:GetConfig(GeneralConfig.key)
        return generalConfig[GeneralConfig.keys.activeChannels]
    end

    ---Toggles an active command channel
    ---@param channel string Available types found in GeneralConfig.channelTypes
    ---@return boolean result - true if need to refresh channels, false if nothing changed
    function GeneralConfig:ToggleActiveChannel(channel)
        local generalConfig = config:GetConfig(GeneralConfig.key) or {}
        if not TableUtils.ArrayContains(TableUtils.GetValues(GeneralConfig.channelTypes), channel) then
            print("Invalid Channel Type. Valid Channel Types: [" .. StringUtils.Join(TableUtils.GetValues(GeneralConfig.channelTypes), ", ") .. "]")
            return false
        end
        if TableUtils.ArrayContains(generalConfig[GeneralConfig.keys.activeChannels], channel) then
            TableUtils.RemoveByValue(generalConfig[GeneralConfig.keys.activeChannels], channel)
            print("Removed [" .. channel .. "] as active channel")
        else
            generalConfig[GeneralConfig.keys.activeChannels][#generalConfig[GeneralConfig.keys.activeChannels] + 1] = channel
            print("Added [" .. channel .. "] to active channels")
        end
        config:SaveConfig(GeneralConfig.key, generalConfig)
        return true
    end

    ---Adds an active command channel
    ---@param channel string Available types found in GeneralConfig.channelTypes
    ---@return boolean result true if need to refresh channels, false if nothing changed
    function GeneralConfig:AddChannel(channel)
        local generalConfig = config:GetConfig(GeneralConfig.key) or {}
        if not TableUtils.IsArray(generalConfig[GeneralConfig.keys.activeChannels]) then error("GeneralConfig.Channels config was not an array") end
        if not TableUtils.ArrayContains(TableUtils.GetValues(GeneralConfig.channelTypes), channel) then
            print("Invalid Channel Type. Valid Channel Types: [" .. StringUtils.Join(TableUtils.GetValues(GeneralConfig.channelTypes), ", ") .. "]")
            return false
        end
        if not TableUtils.ArrayContains(generalConfig[GeneralConfig.keys.activeChannels], channel) then
            generalConfig[GeneralConfig.keys.activeChannels][#generalConfig[GeneralConfig.keys.activeChannels] + 1] = channel
            print("Added [" .. channel .. "] to active channels")
            config:SaveConfig(GeneralConfig.key, generalConfig)
            return true
        end
        DebugLog(channel .. " was already an active channel")
        return false
    end

    ---Removes an active command channel
    ---@param channel string Available types found in GeneralConfig.channelTypes
    ---@return boolean result true if need to refresh channels, false if nothing changed
    function GeneralConfig:RemoveChannel(channel)
        local generalConfig = config:GetConfig(GeneralConfig.key) or {}
        if not TableUtils.IsArray(generalConfig[GeneralConfig.keys.activeChannels]) then error("Command.Channels config was not an array") end
        if not TableUtils.ArrayContains(TableUtils.GetValues(GeneralConfig.channelTypes), channel) then
            print("Invalid Channel Type. Valid Channel Types: [" .. StringUtils.Join(TableUtils.GetValues(GeneralConfig.channelTypes), ", ") .. "]")
            return false
        end
        if TableUtils.ArrayContains(generalConfig[GeneralConfig.keys.activeChannels], channel) then
            TableUtils.RemoveByValue(generalConfig[GeneralConfig.keys.activeChannels], channel)
            print("Removed [" .. channel .. "] as active channel")
            config:SaveConfig(GeneralConfig.key, generalConfig)
            return true
        end
        DebugLog(channel .. " was not an active channel")
        return false
    end

    function GeneralConfig:Print()
        local generalConfig = config:GetConfig(GeneralConfig.key)
        TableUtils.Print(generalConfig)
    end

    ---Removes and re-adds this event to all registered channels
    ---@param eventId string
    ---@param phrase string
    ---@param eventFunction function
    function GeneralConfig:UpdateEventChannels(eventId, phrase, eventFunction)
        mq.unevent(eventId)
        local generalConfig = config:GetConfig(GeneralConfig.key)
        local channels = generalConfig.Channels or {}
        if TableUtils.ArrayContains(channels, GeneralConfig.channelTypes.bc) then
            mq.event(eventId, "<#1#> " .. phrase, eventFunction)
            mq.event(eventId, "<#1#> #2# " .. phrase, eventFunction)
            mq.event(eventId, "[#1#(msg)] " .. phrase, eventFunction)
        end
        if TableUtils.ArrayContains(channels, GeneralConfig.channelTypes.tell) then
            mq.event(eventId, "<#1#> tells you, '" .. phrase .. "'", eventFunction)
        end
        if TableUtils.ArrayContains(channels, GeneralConfig.channelTypes.group) then
            mq.event(eventId, "<#1#> tells the group, '" .. phrase .. "'", eventFunction)
        end
        if TableUtils.ArrayContains(channels, GeneralConfig.channelTypes.raid) then
            mq.event(eventId, "<#1#> tells the raid, '" .. phrase .. "'", eventFunction)
        end
    end

    -- Init any keys that were not setup
    local configForGeneral = config:GetConfig(GeneralConfig.key)
    local taint = false
    if configForGeneral[GeneralConfig.keys.version] == nil then
        DebugLog("General Version was not set, updating...")
        configForGeneral[GeneralConfig.keys.version] = 1
        taint = true
    end
    if configForGeneral[GeneralConfig.keys.activeChannels] == nil then
        DebugLog("Active Channels were not set, updating...")
        configForGeneral[GeneralConfig.keys.activeChannels] = {}
        taint = true
    end
    if taint then config:SaveConfig(GeneralConfig.key, configForGeneral) end

    -- Validation reminders
    if #configForGeneral[GeneralConfig.keys.activeChannels] < 1 then
        print("Not currently listening on any active channels. To learn more, /chelp activechannels")
    else
        print("Currently listening on active channels: [" .. StringUtils.Join(GeneralConfig:GetActiveChannels(), ", ") .. "]")
    end

    return generalConfig
end

return GeneralConfig
