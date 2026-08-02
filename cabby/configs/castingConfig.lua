local mq = require("mq")
local ImGui = require("ImGui")

local Casting = require("utils.Casting.Casting")
local Debug = require("utils.Debug.Debug")
local TableUtils = require("utils.TableUtils.TableUtils")

local CommonUI = require("cabby.ui.commonUI")
local Menu = require("cabby.ui.menu")

---Settings for the casting service, and the page that shows what it is doing.
---
---The service keeps its own defaults (`utils.Casting.Casting.settings`); this owns the two a user
---has a reason to change and pushes them down. Everything else in there is a timing nobody
---sensibly tunes.
---@class CastingConfig : BaseConfig
local CastingConfig = {
    key = "CastingConfig",
    ---mem gem 0 means "the last one", resolved against this character's gem count
    autoGem = 0,
    _ = {
        isInit = false
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(CastingConfig.key, str)
end

local function getConfigSection()
    return Global.configStore:GetConfigRoot()[CastingConfig.key]
end

---Hand the current settings to the service. Called after every change, so the two cannot drift.
local function pushSettings()
    local configRoot = getConfigSection()
    Casting.Configure({
        -- 0 is the service's "last gem" too, so this passes straight through
        memGem = configRoot.mem_gem,
        settleMs = configRoot.settle_ms
    })
end

local function initAndValidate()
    local taint = false
    if getConfigSection() == nil then
        DebugLog("CastingConfig Section was not set, updating...")
        Global.configStore:GetConfigRoot()[CastingConfig.key] = {}
        taint = true
    end

    local configRoot = getConfigSection()

    if configRoot.mem_gem == nil then
        configRoot.mem_gem = CastingConfig.autoGem
        taint = true
    end

    if configRoot.settle_ms == nil then
        configRoot.settle_ms = 250
        taint = true
    end

    -- This was once a ceiling on how long a cast could spend getting started. It is gone: every
    -- part of preparing is a wait for something that changes, and giving up only threw away the
    -- waiting already done -- whoever asked for the cast re-asked on the next frame anyway. Take
    -- the key out rather than leaving it in the file looking like it still does something.
    if configRoot.prepare_timeout_ms ~= nil then
        DebugLog("Removing the preparation ceiling; casts now keep trying until called off")
        configRoot.prepare_timeout_ms = nil
        taint = true
    end

    if taint then
        Global.configStore:SaveConfig()
    end
end

---@diagnostic disable-next-line: duplicate-set-field
function CastingConfig.Init()
    if not CastingConfig._.isInit then
        local ftkey = Global.tracing.open("CastingConfig Setup")

        initAndValidate()
        pushSettings()
        Menu.RegisterConfig(CastingConfig)

        CastingConfig._.isInit = true
        Global.tracing.close(ftkey)
    end
end

---------------- Config Management --------------------

---@return number memGem 0 for "the last gem", resolved when a spell needs memorizing and the bar
---is full -- an empty gem is preferred over this one and is looked for at that same moment
function CastingConfig.GetMemGem()
    return getConfigSection().mem_gem
end

---@param gem number
function CastingConfig.SetMemGem(gem)
    getConfigSection().mem_gem = math.max(math.min(math.floor(gem), 12), 0)
    Global.configStore:SaveConfig()
    pushSettings()
end

---@return number settleMs
function CastingConfig.GetSettleMs()
    return getConfigSection().settle_ms
end

---@param milliseconds number
function CastingConfig.SetSettleMs(milliseconds)
    getConfigSection().settle_ms = math.max(math.min(math.floor(milliseconds), 2000), 0)
    Global.configStore:SaveConfig()
    pushSettings()
end

---@diagnostic disable-next-line: duplicate-set-field
function CastingConfig.BuildMenu()
    ImGui.SeparatorText("Casting")
    ImGui.SameLine()
    CommonUI.HelpMarker("Spells, item clicks and AA activations all run through one casting service: one cast at a time, and while it is preparing or in the air everything lower in the priority chain is held back so nothing walks the character off mid-cast.")

    ImGui.Text("Now: " .. Casting.Describe() .. " [" .. Casting.GetStatus() .. "]")
    local reason = Casting.GetReason()
    if reason ~= nil then
        ImGui.TextDisabled(" -- " .. reason)
    end
    local floor = Casting.GetPriorityFloor()
    if floor ~= nil then
        ImGui.TextDisabled(" -- holding back everything weaker than priority " .. tostring(floor))
    end

    ImGui.Spacing()

    local gems = math.floor(tonumber(mq.TLO.Me.NumGems()) or 8)
    local memGem = CastingConfig.GetMemGem()
    ImGui.SetNextItemWidth(120)
    local gemLabel = memGem == CastingConfig.autoGem and ("Last gem (" .. tostring(gems) .. ")") or ("Gem " .. tostring(memGem))
    if ImGui.BeginCombo("Memorize over", gemLabel) then
        local _, autoPressed = ImGui.Selectable("Last gem (" .. tostring(gems) .. ")", memGem == CastingConfig.autoGem)
        if autoPressed then
            CastingConfig.SetMemGem(CastingConfig.autoGem)
        end
        for gem = 1, gems do
            local _, pressed = ImGui.Selectable("Gem " .. tostring(gem), memGem == gem)
            if pressed then
                CastingConfig.SetMemGem(gem)
            end
        end
        ImGui.EndCombo()
    end
    ImGui.SameLine()
    CommonUI.HelpMarker("Which gem a spell that is not memorized gets cast over when your bar is full. An empty gem is always used first, so this only matters once there are none -- and the last gem is the default because it is the one least likely to hold something you are playing with by hand.")

    ImGui.SetNextItemWidth(120)
    local settle, settleChanged = ImGui.DragInt("Stand still for (ms)", CastingConfig.GetSettleMs(), 10, 0, 2000)
    if settleChanged then
        CastingConfig.SetSettleMs(settle)
    end
    ImGui.SameLine()
    CommonUI.HelpMarker("How long the character has to have been stopped before a cast is started. A character that has only just stopped is still moving as far as the server is concerned, and the cast is lost.")
end

---@diagnostic disable-next-line: duplicate-set-field
function CastingConfig.Print()
    TableUtils.Print(getConfigSection())
end

return CastingConfig
