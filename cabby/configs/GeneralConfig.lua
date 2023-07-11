local Config = require("utils.Config.Config")
local Debug = require("utils.Debug.Debug")
local TableUtils = require("utils.TableUtils.TableUtils")

---@class GeneralConfig
local GeneralConfig = {
    key = "General",
    keys = {
        version = "version",
        relayTellsTo = "relayTellsTo"
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

    function GeneralConfig:Print()
        local generalConfig = config:GetConfig(GeneralConfig.key)
        TableUtils.Print(generalConfig)
    end

    local configForGeneral = config:GetConfig(GeneralConfig.key)
    local taint = false
    if configForGeneral[GeneralConfig.keys.version] == nil then
        DebugLog("General Version was not set, updating...")
        configForGeneral[GeneralConfig.keys.version] = 1
        taint = true
    end
    if taint then config:SaveConfig(GeneralConfig.key, configForGeneral) end

    return generalConfig
end

return GeneralConfig
