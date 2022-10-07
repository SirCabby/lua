local Config = require("utils.Config.Config")
local TableUtils = require("utils.TableUtils.TableUtils")

---@class GeneralConfig
local GeneralConfig = {
    debug = false,
    configKey = "General",
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

    ---@param str string
    local function Debug(str)
        if GeneralConfig.debug then print(str) end
    end

    function GeneralConfig:GetRelayTellsTo()
        local generalConfig = config:GetConfig(GeneralConfig.configKey)
        return generalConfig[GeneralConfig.keys.relayTellsTo]
    end

    function GeneralConfig:SetRelayTellsTo(name)
        local generalConfig = config:GetConfig(GeneralConfig.configKey)
        Debug("Set relayTellsTo: [" .. name .. "]")
        generalConfig[GeneralConfig.keys.relayTellsTo] = name
        config:SaveConfig(GeneralConfig.configKey, generalConfig)
    end

    function GeneralConfig:Print()
        local generalConfig = config:GetConfig(GeneralConfig.configKey)
        TableUtils.Print(generalConfig)
    end

    local configForGeneral = config:GetConfig(GeneralConfig.configKey)
    local taint = false
    if configForGeneral[GeneralConfig.keys.version] == nil then
        Debug("General Version was not set, updating...")
        configForGeneral[GeneralConfig.keys.version] = 1
        taint = true
    end
    if taint then config:SaveConfig(GeneralConfig.configKey, configForGeneral) end

    return generalConfig
end

return GeneralConfig
