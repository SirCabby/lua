local Debug = require("utils.Debug.Debug")

---@class CabbyConfig
local MeleeStateConfig = {
    key = "MeleeState",
    _ = {
        isInit = false,
        config = {}
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(MeleeStateConfig.key, str)
end

local function getConfigSection()
    return MeleeStateConfig._.config:GetConfigRoot()[MeleeStateConfig.key]
end

local function initAndValidate()
    if getConfigSection() == nil then
        DebugLog("MeleeStateConfig Section was not set, updating...")
        MeleeStateConfig._.config:GetConfigRoot()[MeleeStateConfig.key] = {}

        local configRoot = getConfigSection()
        configRoot.enabled = true
        configRoot.stick = true
        configRoot.stick_distance = 12
        configRoot.engage_range = 50
        configRoot.actions = {}
    end
end

---Initialize the static object, only done once
---@diagnostic disable-next-line: duplicate-set-field
function MeleeStateConfig.Init()
    if not MeleeStateConfig._.isInit then
        local ftkey = Global.tracing.open("MeleeStateConfig Setup")
        MeleeStateConfig._.config = Global.configStore

        initAndValidate()

        -- local function CMelee_Help()
        --     print("(/cmelee <option> <value>) Melee Settings")
        --     print(" -- enable : " .. tostring(getConfigSection().enabled))
        -- end

        -- local function Bind_CMelee(...)
        --     local args = {...} or {}
        --     if args == nil or #args < 1 or #args > 2 or args[1]:lower() == "help" then
        --             CMelee_Help()
        --         return
        --     end

        --     local arg1 = args[1]:lower()
        --     local arg2 = ""
        --     if #args == 2 then
        --         arg2 = args[2]:lower()
        --     end

        --     if arg1 == "enabled" then
        --         if #args == 1 then
        --             MeleeStateConfig.SetEnabled(not MeleeStateConfig.IsEnabled())
        --         else
        --             MeleeStateConfig.SetEnabled(UserInput.IsTrue(arg2))
        --         end
        --     end
        -- end
        -- Commands.RegisterSlashCommand("cmelee", Bind_CMelee)

        MeleeStateConfig._.isInit = true
        Global.tracing.close(ftkey)
    end
end

---------------- Config Management --------------------

---@return boolean isEnabled
function MeleeStateConfig.IsEnabled()
    return getConfigSection().enabled
end

function MeleeStateConfig.SetEnabled(isEnabled)
    getConfigSection().enabled = isEnabled
    MeleeStateConfig._.config:SaveConfig()
    print("MeleeState is Enabled: [" .. tostring(isEnabled) .. "]")
end

return MeleeStateConfig
