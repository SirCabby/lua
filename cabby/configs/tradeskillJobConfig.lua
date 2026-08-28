local Debug = require("utils.Debug.Debug")
local TableUtils = require("utils.TableUtils.TableUtils")

---The setup for a run of combines: what to combine in, what to put in it, and what stops it.
---
---**The setup persists and the run switch does not.** Which container and which materials is
---something the player worked out once and will want again tomorrow; whether the character is
---combining right now is an errand it was sent on this session, and a script that came back up
---already making combines would be doing something nobody asked it for. So there is no `enabled`
---key here -- the job holds that in memory and starts off every time (see `cabby/jobs/job.lua`).
---
---**The container is remembered by what it is, not by where its window was.** A pack is the bag
---slot number, because that is what `/combine pack3` and `/itemnotify in pack3 <n>` are addressed
---by; a world container -- a forge, a brew barrel, an oven standing in the world -- has no address
---beyond "the one that is open", so all that is kept of it is the name it had, which is enough to
---show on the page and to notice that a different one is open now.
---@class TradeskillJobConfig : BaseConfig
local TradeskillJobConfig = {
    key = "TradeskillJob",
    kinds = {
        ---a container standing in the world with its window open: a forge, a brew barrel, an oven
        world = "world",
        ---a tradeskill container in one of this character's bag slots
        pack = "pack"
    },
    _ = {
        isInit = false
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(TradeskillJobConfig.key, str)
end

local function getConfigSection()
    return Global.configStore:GetConfigRoot()[TradeskillJobConfig.key]
end

local function initAndValidate()
    local taint = false
    if getConfigSection() == nil then
        DebugLog("TradeskillJobConfig Section was not set, updating...")
        Global.configStore:GetConfigRoot()[TradeskillJobConfig.key] = {}
        taint = true
    end

    local configRoot = getConfigSection()

    -- no container chosen yet is the honest starting point: there is no default forge
    if configRoot.container == nil then
        configRoot.container = {}
        taint = true
    end

    if configRoot.items == nil then
        configRoot.items = {}
        taint = true
    end

    -- the limits. All three off means "keep going until the materials run out", which is the one
    -- limit that is not a preference -- a combine with nothing to combine cannot happen
    if configRoot.stopAtSkill == nil then
        configRoot.stopAtSkill = false
        taint = true
    end
    if configRoot.skill == nil then
        configRoot.skill = ""
        taint = true
    end
    if configRoot.skillLevel == nil then
        configRoot.skillLevel = 200
        taint = true
    end
    if configRoot.stopAfterCombines == nil then
        configRoot.stopAfterCombines = false
        taint = true
    end
    if configRoot.combines == nil then
        configRoot.combines = 20
        taint = true
    end
    if configRoot.stopAfterSuccesses == nil then
        configRoot.stopAfterSuccesses = false
        taint = true
    end
    if configRoot.successes == nil then
        configRoot.successes = 20
        taint = true
    end
    if configRoot.stopWhenTrivial == nil then
        configRoot.stopWhenTrivial = false
        taint = true
    end

    if taint then
        Global.configStore:SaveConfig()
    end
end

---@diagnostic disable-next-line: duplicate-set-field
function TradeskillJobConfig.Init()
    if not TradeskillJobConfig._.isInit then
        local ftkey = Global.tracing.open("TradeskillJobConfig Setup")

        initAndValidate()

        TradeskillJobConfig._.isInit = true
        Global.tracing.close(ftkey)
    end
end

---------------- The container --------------------

---@return table|nil container `{ kind, pack, name }`, nil when nothing has been chosen
function TradeskillJobConfig.GetContainer()
    local container = getConfigSection().container
    if container == nil or container.kind == nil then return nil end
    return container
end

---@param kind string one of TradeskillJobConfig.kinds
---@param pack number|nil bag slot number, for a pack
---@param name string what it is called, for the page to show
function TradeskillJobConfig.SetContainer(kind, pack, name)
    getConfigSection().container = { kind = kind, pack = tonumber(pack), name = tostring(name or "") }
    Global.configStore:SaveConfig()
end

function TradeskillJobConfig.ClearContainer()
    getConfigSection().container = {}
    Global.configStore:SaveConfig()
end

---How a container reads in a sentence, on the page and in `/ctradeskill`.
---@param container table|nil
---@return string
function TradeskillJobConfig.DescribeContainer(container)
    if container == nil then return "no container chosen" end
    local name = container.name
    if name == nil or name == "" then name = "container" end
    if container.kind == TradeskillJobConfig.kinds.world then
        return name .. " (open in the world)"
    end
    return name .. " (bag " .. tostring(container.pack) .. ")"
end

---------------- The materials --------------------

---The live list, held by reference so the page edits it in place the way the buff list is edited.
---@return table items array of `{ name, count }`
function TradeskillJobConfig.GetItems()
    return getConfigSection().items
end

---@param name string
---@param count number|nil how many go in per combine; each one takes a slot of its own, because
---the recipe is matched by slots occupied and not by how deep a stack is
function TradeskillJobConfig.AddItem(name, count)
    name = tostring(name or ""):match("^%s*(.-)%s*$")
    if name == "" then return end

    local items = getConfigSection().items
    for _, item in ipairs(items) do
        if tostring(item.name):lower() == name:lower() then
            -- naming the same thing twice is how somebody asks for two of it
            item.count = (tonumber(item.count) or 1) + (tonumber(count) or 1)
            Global.configStore:SaveConfig()
            return
        end
    end

    items[#items+1] = { name = name, count = math.max(1, tonumber(count) or 1) }
    Global.configStore:SaveConfig()
end

---@param index number
function TradeskillJobConfig.RemoveItem(index)
    local items = getConfigSection().items
    if items[index] == nil then return end
    table.remove(items, index)
    Global.configStore:SaveConfig()
end

---@param index number
---@param count number
function TradeskillJobConfig.SetItemCount(index, count)
    local items = getConfigSection().items
    if items[index] == nil then return end
    items[index].count = math.max(1, math.floor(tonumber(count) or 1))
    Global.configStore:SaveConfig()
end

---@param index number
---@param delta number -1 to move a row up, 1 to move it down
function TradeskillJobConfig.MoveItem(index, delta)
    local items = getConfigSection().items
    local to = index + delta
    if items[index] == nil or items[to] == nil then return end
    items[index], items[to] = items[to], items[index]
    Global.configStore:SaveConfig()
end

function TradeskillJobConfig.ClearItems()
    getConfigSection().items = {}
    Global.configStore:SaveConfig()
end

---@return number slots how many container slots one combine's worth of materials needs
function TradeskillJobConfig.GetSlotsNeeded()
    local needed = 0
    for _, item in ipairs(getConfigSection().items) do
        needed = needed + math.max(1, math.floor(tonumber(item.count) or 1))
    end
    return needed
end

---------------- The limits --------------------

---@return boolean
function TradeskillJobConfig.GetStopAtSkill()
    return getConfigSection().stopAtSkill == true
end

---@param value boolean
function TradeskillJobConfig.SetStopAtSkill(value)
    getConfigSection().stopAtSkill = value == true
    Global.configStore:SaveConfig()
end

---The tradeskill the skill limit watches. **`""` means Auto**, and Auto is the default: which skill
---a recipe raises is something the world says out loud the first time it does it, so it is a
---reading rather than a setting. Naming one here is for pinning it in advance -- a run that is
---expected to be trivial already, say, where no skill-up is ever going to arrive to say.
---@return string skill "" for Auto
function TradeskillJobConfig.GetSkill()
    return tostring(getConfigSection().skill or "")
end

---@param skill string
function TradeskillJobConfig.SetSkill(skill)
    getConfigSection().skill = tostring(skill or "")
    Global.configStore:SaveConfig()
end

---@return number
function TradeskillJobConfig.GetSkillLevel()
    return math.max(1, math.floor(tonumber(getConfigSection().skillLevel) or 200))
end

---@param level number
function TradeskillJobConfig.SetSkillLevel(level)
    getConfigSection().skillLevel = math.max(1, math.floor(tonumber(level) or 200))
    Global.configStore:SaveConfig()
end

---@return boolean
function TradeskillJobConfig.GetStopAfterCombines()
    return getConfigSection().stopAfterCombines == true
end

---@param value boolean
function TradeskillJobConfig.SetStopAfterCombines(value)
    getConfigSection().stopAfterCombines = value == true
    Global.configStore:SaveConfig()
end

---@return number
function TradeskillJobConfig.GetCombines()
    return math.max(1, math.floor(tonumber(getConfigSection().combines) or 20))
end

---@param count number
function TradeskillJobConfig.SetCombines(count)
    getConfigSection().combines = math.max(1, math.floor(tonumber(count) or 20))
    Global.configStore:SaveConfig()
end

---The other way to count to a number, and the one that means "I want this many of the thing".
---A combine the server made and lost still ate the materials, so a run counting attempts stops
---short of what it set out to produce whenever the recipe is anywhere near the character's skill.
---@return boolean
function TradeskillJobConfig.GetStopAfterSuccesses()
    return getConfigSection().stopAfterSuccesses == true
end

---@param value boolean
function TradeskillJobConfig.SetStopAfterSuccesses(value)
    getConfigSection().stopAfterSuccesses = value == true
    Global.configStore:SaveConfig()
end

---@return number
function TradeskillJobConfig.GetSuccesses()
    return math.max(1, math.floor(tonumber(getConfigSection().successes) or 20))
end

---@param count number
function TradeskillJobConfig.SetSuccesses(count)
    getConfigSection().successes = math.max(1, math.floor(tonumber(count) or 20))
    Global.configStore:SaveConfig()
end

---@return boolean
function TradeskillJobConfig.GetStopWhenTrivial()
    return getConfigSection().stopWhenTrivial == true
end

---@param value boolean
function TradeskillJobConfig.SetStopWhenTrivial(value)
    getConfigSection().stopWhenTrivial = value == true
    Global.configStore:SaveConfig()
end

---@diagnostic disable-next-line: duplicate-set-field
function TradeskillJobConfig.Print()
    TableUtils.Print(getConfigSection())
end

return TradeskillJobConfig
