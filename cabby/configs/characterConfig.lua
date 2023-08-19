local mq = require("mq")

local Debug = require("utils.Debug.Debug")

local Character = require("cabby.character")

---@class CharacterConfig
local CharacterConfig = {
    key = "CharacterConfig",
    _ = {
        isInit = false,
        config = {},
        character = {
            abilities = {}
        }
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(CharacterConfig.key, str)
end

local function initAndValidate()
    local configRoot = CharacterConfig._.config:GetConfigRoot()

    -- init config structure if missing
    local taint = false
    if configRoot.CharacterConfig == nil then
        DebugLog("CharacterConfig Section was not set, updating...")
        configRoot.CharacterConfig = {}
        taint = true
    end
    CharacterConfig._.configData = configRoot.CharacterConfig
    if taint then
        CharacterConfig._.config:SaveConfig()
    end

    Character.Refresh()
end

---Initialize the static object, only done once
---@param config Config
function CharacterConfig.Init(config)
    if not CharacterConfig._.isInit then
        local ftkey = Global.tracing.open("CharacterConfig Setup")
        CharacterConfig._.config = config

        initAndValidate()

        CharacterConfig._.isInit = true
        Global.tracing.close(ftkey)
    end
end

return CharacterConfig
