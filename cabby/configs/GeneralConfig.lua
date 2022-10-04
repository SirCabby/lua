local Config = require("utils.Config.Config")
local TableUtils = require("utils.TableUtils.TableUtils")

local GeneralConfig = { debug = false, configKey = "General" }

function GeneralConfig:new(configFilePath)
    local generalConfig = {}
    setmetatable(generalConfig, self)
    self.__index = self
    local config = Config:new(configFilePath)

    ---@param str string
    local function Debug(str)
        if GeneralConfig.debug then print(str) end
    end

    function GeneralConfig:Print()
        local generalConfig = config:GetConfig(GeneralConfig.configKey)
        TableUtils.Print(generalConfig)
    end

    local generalConfig = config:GetConfig(GeneralConfig.configKey)
    local taint = false
    if generalConfig["version"] == nil then
        Debug("General Version was not set, updating...")
        generalConfig["version"] = 1
        taint = true
    end
    if taint then config:SaveConfig(GeneralConfig.configKey, generalConfig) end

    return generalConfig
end

return GeneralConfig
