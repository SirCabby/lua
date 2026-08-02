local Debug = require("utils.Debug.Debug")
local TableUtils = require("utils.TableUtils.TableUtils")

local ActionType = require("cabby.actions.actionType")
-- for `shortNames` alone, which is data: nothing here loads a class module
local Classes = require("cabby.classes.classes")

---What this character heals, and with what.
---
---The whole model is one ordered list of **heal slots**. A slot is an action (a spell, an AA or a
---clicky) plus the two things that decide when it is the right one: the health it is *for*
---(`hp_threshold` -- use it on someone at or below this), and who it is for (`heal_scope`).
---Walking the list in order and taking the first slot that fits is how every heal macro since
---AFCleric has chosen a heal, and it is what lets one mechanism cover what those macros spelled
---out one setting at a time: a slot at 85% scoped to the tank is TankHealPoint, a slot at 50%
---scoped to yourself is SelfHealPoint, and a group heal at 60% is DivArbPoint.
---
---Scope only ever narrows a heal that *could* go to more than one person. Where a spell can be
---aimed is the spell's own business and outranks it: a pet heal lands on the pet and a self heal
---lands on us whatever the slot says, which is why the page offers those slots the one scope they
---can have and does not let it be changed.
---"Anyone else" is the rest of the group and not the pet -- the pet has a scope of its own, and
---a heal meant for the people in the group should not be spent on a pet because nobody thought
---to say so.
---@class HealStateConfig : BaseConfig
local HealStateConfig = {
    key = "HealState",
    scopes = {
        Any = { value = "any", display = "Anyone" },
        Self = { value = "self", display = "Myself" },
        Tank = { value = "tank", display = "The tank" },
        Others = { value = "others", display = "Anyone else" },
        Pet = { value = "pet", display = "My pet" }
    },
    ---Whether this character answers cure requests, and when.
    ---
    ---One setting rather than two switches, because the second one only means anything when the
    ---first is on: "cure, but not in a fight" and "cure, fights included" are two answers to one
    ---question, and a pair of checkboxes would offer a fourth state ("not curing, but in battle")
    ---that stands for nothing.
    cureModes = {
        Off = { value = "off", display = "Disabled" },
        OutOfCombat = { value = "outofcombat", display = "Curing, out of combat" },
        Always = { value = "always", display = "Curing, in battle too" }
    },
    ---Whether this character rezzes the corpses lying around it, and when. The same three answers
    ---to the same one question the cure mode asks, and deliberately the same shape: "rez, but not
    ---while fighting" and "rez, fights included" are two answers rather than a second switch, and
    ---a pair of checkboxes would offer a fourth state that stands for nothing.
    rezModes = {
        Off = { value = "off", display = "Disabled" },
        OutOfCombat = { value = "outofcombat", display = "Rezzing, out of combat" },
        Always = { value = "always", display = "Rezzing, in battle too" }
    },
    _ = {
        isInit = false
    }
}

local defaultThreshold = 70
local defaultGroupMin = 3

---What a rez setting holds when the user has not named a spell: work it out from what this
---character owns. The best experience out of a fight, the shortest cast in one.
local autoRez = ""

---Which corpse is worth rezzing first, as the list ships.
---
---**Whoever can put the rest of the group back on its feet goes first.** A cleric standing up is
---six more rezzes and the healing to survive them, which is worth more than any one corpse; the
---other classes that can rez follow for the same reason. Then the people the fight cannot restart
---without, then everybody else in the order `Classes.shortNames` groups them.
---
---It is only a default. The whole point of the list being ordered and editable is that a group
---knows its own answer -- and the tank switch above it outranks the list entirely.
local defaultRezClasses = {
    "CLR", "DRU", "SHM", "PAL", "NEC",
    "WAR", "SHD",
    "MNK", "ROG", "BER", "RNG", "BST", "BRD", "ENC", "MAG", "WIZ"
}

---@param str string
local function DebugLog(str)
    Debug.Log(HealStateConfig.key, str)
end

local function getConfigSection()
    return Global.configStore:GetConfigRoot()[HealStateConfig.key]
end

local function initAndValidate()
    local taint = false
    if getConfigSection() == nil then
        DebugLog("HealStateConfig Section was not set, updating...")
        Global.configStore:GetConfigRoot()[HealStateConfig.key] = {}
        taint = true
    end

    local configRoot = getConfigSection()

    if configRoot.enabled == nil then
        configRoot.enabled = true
        taint = true
    end

    if configRoot.heal_group == nil then
        configRoot.heal_group = true
        taint = true
    end

    if configRoot.heal_pets == nil then
        -- off by default: a pet is cheaper to re-summon than a heal is to cast, and a healer
        -- spending mana on one while the tank drops is the classic complaint about heal bots.
        -- A pet class that means to keep its pet up turns it on, and the Heal State page says so
        -- against any slot holding a pet heal, which would otherwise never fire for no visible
        -- reason
        configRoot.heal_pets = false
        taint = true
    end

    if configRoot.emergency_pct == nil then
        configRoot.emergency_pct = 35
        taint = true
    end

    -- Out of combat by default: the middle answer is the one that cannot cost anything anybody
    -- would miss. A cure is a gem and a global cooldown spent on somebody who is not dying, and a
    -- healer that starts doing that mid-fight the first time a character is upgraded is a change
    -- nobody asked for. Curing in battle is where most of the value is -- that is when the DoTs
    -- land -- so it is one pick away on the Heal State page rather than off the table.
    if configRoot.cure_mode == nil then
        configRoot.cure_mode = HealStateConfig.cureModes.OutOfCombat.value
        taint = true
    end

    -- Out of combat by default, for the reason curing is: a rez is a long cast and a big chunk of
    -- the mana bar, and a healer that starts one in the middle of a fight the first time a
    -- character learns Resurrection is a change nobody asked for. Rezzing during a fight is a real
    -- job -- getting the tank back up is sometimes the whole answer -- so it is one pick away on
    -- the Heal State page rather than off the table.
    if configRoot.rez_mode == nil then
        configRoot.rez_mode = HealStateConfig.rezModes.OutOfCombat.value
        taint = true
    end

    if configRoot.rez_spell == nil then
        configRoot.rez_spell = autoRez
        taint = true
    end

    if configRoot.battle_rez_spell == nil then
        configRoot.battle_rez_spell = autoRez
        taint = true
    end

    if configRoot.rez_tank_first == nil then
        configRoot.rez_tank_first = true
        taint = true
    end

    -- **Repaired rather than trusted.** The class list is sixteen rows of hand-editable config that
    -- decides who gets left on the ground, so a row lost to a bad edit is somebody quietly never
    -- rezzed again. Known entries keep the order they are in, anything unknown goes, and any class
    -- missing from the list is appended switched on -- which is also how a list written by an older
    -- version picks up a class it never knew about.
    local known = {}
    for _, shortName in ipairs(Classes.shortNames) do known[shortName] = true end

    ---The one flag a row carries, read as a switch; on when it was never written.
    ---
    ---Spelled out rather than done with `and`/`or`, which cannot express it: `written ~= nil and
    ---written or fallback` hands back the fallback whenever `written` is *false*, which is exactly
    ---the value being asked about -- a class deliberately switched off would come back on.
    ---@param written any
    ---@param fallback any an older spelling of the same flag, when there is one
    ---@return boolean
    local function flag(written, fallback)
        if written ~= nil then return written ~= false end
        if fallback ~= nil then return fallback ~= false end
        return true
    end

    ---**Every class is rezzed; the flag is only ever about when.** There is deliberately no "rez
    ---this class at all" switch -- a corpse left lying there forever is not a setting anybody
    ---reached for, and `rezzing off` is already the answer for the whole character. So a class out
    ---of a fight is always rezzed, and the flag says whether a fight is interrupted for them.
    ---
    ---**On to start with.** Rezzing during a fight is already behind its own mode switch and already
    ---waits for everybody alive, so a flag defaulted off would be a second switch somebody has to go
    ---and find after turning the first one on. It is for narrowing, not for opting in.
    ---@param entry table|nil what was in the config, when there was something
    ---@return table row
    local function rezClassRow(shortName, entry)
        entry = entry or {}
        return {
            class = shortName,
            -- `enabled` is what this flag was called back when it meant "rezzed at all"
            in_combat = flag(entry.in_combat, entry.enabled)
        }
    end

    local rezClasses, seen = {}, {}
    for _, entry in ipairs(configRoot.rez_classes or {}) do
        local shortName = tostring((type(entry) == "table" and entry.class) or ""):upper()
        if known[shortName] and not seen[shortName] then
            seen[shortName] = true
            -- a row spelled the old way is a row that has changed on disk
            if entry.in_combat == nil or entry.enabled ~= nil or entry.out_of_combat ~= nil then
                taint = true
            end
            rezClasses[#rezClasses+1] = rezClassRow(shortName, entry)
        else
            taint = true
        end
    end

    for _, shortName in ipairs(defaultRezClasses) do
        if known[shortName] and not seen[shortName] then
            seen[shortName] = true
            rezClasses[#rezClasses+1] = rezClassRow(shortName)
            taint = true
        end
    end
    -- anything `defaultRezClasses` itself has fallen behind on, so a new class is never silently
    -- missing from the list whichever of the two is out of date
    for _, shortName in ipairs(Classes.shortNames) do
        if not seen[shortName] then
            seen[shortName] = true
            rezClasses[#rezClasses+1] = rezClassRow(shortName)
            taint = true
        end
    end

    configRoot.rez_classes = rezClasses

    if configRoot.actions == nil then
        configRoot.actions = {}
        taint = true
    end

    -- a slot that was never finished being filled in cannot be healed with
    for i = #configRoot.actions, 1, -1 do
        local action = configRoot.actions[i]
        if action.actionType == nil or action.actionType == ActionType.Edit then
            table.remove(configRoot.actions, i)
            taint = true
        end
    end

    if taint then
        Global.configStore:SaveConfig()
    end
end

---@diagnostic disable-next-line: duplicate-set-field
function HealStateConfig.Init()
    if not HealStateConfig._.isInit then
        local ftkey = Global.tracing.open("HealStateConfig Setup")

        initAndValidate()

        HealStateConfig._.isInit = true
        Global.tracing.close(ftkey)
    end
end

---------------- Config Management --------------------

---@return boolean isEnabled
function HealStateConfig.IsEnabled()
    return getConfigSection().enabled
end

---@param enable boolean
function HealStateConfig.SetEnabled(enable)
    getConfigSection().enabled = enable == true
    Global.configStore:SaveConfig()
    print("HealState is Enabled: [" .. tostring(enable) .. "]")
end

---Whether the rest of the group is somebody this character heals at all -- which is to say
---whether they are *watched*, since a heal is only ever chosen for somebody being watched. Off
---leaves this character and its pet, and a group-mate at 10% to whoever else is healing.
---
---It says nothing about group heal *spells*. One of those is cast because enough of the people
---being watched are hurt, so switching this off shrinks the count it is judged against rather
---than taking the spell out of the list.
---@return boolean healGroup
function HealStateConfig.GetHealGroup()
    return getConfigSection().heal_group
end

---@param enable boolean
function HealStateConfig.SetHealGroup(enable)
    getConfigSection().heal_group = enable == true
    Global.configStore:SaveConfig()
    print("HealState heals group members: [" .. tostring(enable) .. "]")
end

---@return boolean healPets
function HealStateConfig.GetHealPets()
    return getConfigSection().heal_pets
end

---@param enable boolean
function HealStateConfig.SetHealPets(enable)
    getConfigSection().heal_pets = enable == true
    Global.configStore:SaveConfig()
    print("HealState heals pets: [" .. tostring(enable) .. "]")
end

---The health at which someone is in trouble rather than merely hurt. It does not decide which
---heal to use -- the slots do that -- it decides what is worth throwing away a heal in progress
---for.
---@return number pct
function HealStateConfig.GetEmergencyPct()
    return getConfigSection().emergency_pct
end

---@param pct number
function HealStateConfig.SetEmergencyPct(pct)
    getConfigSection().emergency_pct = math.max(math.min(math.floor(pct), 99), 1)
    Global.configStore:SaveConfig()
end

---Whether this character answers cure requests, and when.
---@return string mode one of HealStateConfig.cureModes values
function HealStateConfig.GetCureMode()
    local mode = getConfigSection().cure_mode
    for _, known in pairs(HealStateConfig.cureModes) do
        if known.value == mode then return mode end
    end
    return HealStateConfig.cureModes.Off.value
end

---@param mode string one of HealStateConfig.cureModes values
function HealStateConfig.SetCureMode(mode)
    for _, known in pairs(HealStateConfig.cureModes) do
        if known.value == mode then
            getConfigSection().cure_mode = mode
            Global.configStore:SaveConfig()
            print("HealState curing: [" .. known.display .. "]")
            return
        end
    end
    print("[" .. tostring(mode) .. "] is not a curing setting")
end

---@param mode string
---@return string display
function HealStateConfig.GetCureModeDisplay(mode)
    for _, known in pairs(HealStateConfig.cureModes) do
        if known.value == mode then return known.display end
    end
    return HealStateConfig.cureModes.Off.display
end

---@return boolean isCuring whether cures are answered at all
function HealStateConfig.IsCuring()
    return HealStateConfig.GetCureMode() ~= HealStateConfig.cureModes.Off.value
end

---@return boolean curesInCombat whether cures are answered during a fight
function HealStateConfig.GetCureInCombat()
    return HealStateConfig.GetCureMode() == HealStateConfig.cureModes.Always.value
end

---Whether this character rezzes what is lying around it, and when.
---@return string mode one of HealStateConfig.rezModes values
function HealStateConfig.GetRezMode()
    local mode = getConfigSection().rez_mode
    for _, known in pairs(HealStateConfig.rezModes) do
        if known.value == mode then return mode end
    end
    return HealStateConfig.rezModes.Off.value
end

---@param mode string one of HealStateConfig.rezModes values
function HealStateConfig.SetRezMode(mode)
    for _, known in pairs(HealStateConfig.rezModes) do
        if known.value == mode then
            getConfigSection().rez_mode = mode
            Global.configStore:SaveConfig()
            print("HealState rezzing: [" .. known.display .. "]")
            return
        end
    end
    print("[" .. tostring(mode) .. "] is not a rezzing setting")
end

---@param mode string
---@return string display
function HealStateConfig.GetRezModeDisplay(mode)
    for _, known in pairs(HealStateConfig.rezModes) do
        if known.value == mode then return known.display end
    end
    return HealStateConfig.rezModes.Off.display
end

---@return boolean isRezzing whether corpses are rezzed at all
function HealStateConfig.IsRezzing()
    return HealStateConfig.GetRezMode() ~= HealStateConfig.rezModes.Off.value
end

---@return boolean rezzesInCombat whether a rez may be started during a fight
function HealStateConfig.GetRezInCombat()
    return HealStateConfig.GetRezMode() == HealStateConfig.rezModes.Always.value
end

---@return string autoRez what a rez setting holds when no spell has been named
function HealStateConfig.AutoRez()
    return autoRez
end

---Which rez to cast out of a fight, by name; empty for "the best I have".
---@return string name
function HealStateConfig.GetRezSpell()
    return tostring(getConfigSection().rez_spell or autoRez)
end

---@param name string|nil a rez this character owns, or nil/empty for the best it has
function HealStateConfig.SetRezSpell(name)
    getConfigSection().rez_spell = tostring(name or autoRez)
    Global.configStore:SaveConfig()
end

---Which rez to cast during a fight, by name; empty for "the quickest I have".
---
---A setting of its own rather than the same one, because the question is not the same question: out
---of a fight the only thing that matters is the experience handed back, and in one it is whether
---the cast bar can survive being interrupted. A character that owns both a ten second rez and an
---instant AA wants each of them, in its own circumstance.
---@return string name
function HealStateConfig.GetBattleRezSpell()
    return tostring(getConfigSection().battle_rez_spell or autoRez)
end

---@param name string|nil a rez this character owns, or nil/empty for the quickest it has
function HealStateConfig.SetBattleRezSpell(name)
    getConfigSection().battle_rez_spell = tostring(name or autoRez)
    Global.configStore:SaveConfig()
end

---Whether the main tank's corpse jumps the class order.
---@return boolean tankFirst
function HealStateConfig.GetRezTankFirst()
    return getConfigSection().rez_tank_first == true
end

---@param enable boolean
function HealStateConfig.SetRezTankFirst(enable)
    getConfigSection().rez_tank_first = enable == true
    Global.configStore:SaveConfig()
    print("HealState rezzes the tank first: [" .. tostring(enable) .. "]")
end

---Who is rezzed first, and who a fight is interrupted for.
---
---One ordered list rather than a ranking and a switch, because they are the same list read twice:
---where a class sits is who is gone to first, and its flag is whether a fight is interrupted for
---them. The same shape the heal slots have, and for the same reason -- a walk from the top is how
---the answer is arrived at.
---
---**The flag is about when, never about whether.** Every class on this list is rezzed once the
---fighting stops; there is no "leave this one lying there" switch, because that is not a setting
---anybody reached for and `rezzing off` already answers it for the whole character. What the flag
---buys is the real judgment: out of a fight a rez costs time nobody is using, and during one it
---costs a cast somebody alive may need -- so a group that will interrupt a fight for its cleric and
---nobody else has somewhere to say exactly that.
---@return table classes array of { class, in_combat }, best first
function HealStateConfig.GetRezClasses()
    return getConfigSection().rez_classes
end

---Where this class sits in the order, and whether it is rezzed in this situation.
---@param shortName string|nil as the client reports it, or nil when the corpse will not say
---@param inCombat boolean whether there is a fight on, which is the only situation the flag gates
---@return number rank lower is sooner; a class not in the list ranks last
---@return boolean enabled true for a class the corpse cannot name, which is not a reason to leave
---somebody on the ground
function HealStateConfig.GetRezClassRank(shortName, inCombat)
    if shortName == nil or shortName == "" then return #Classes.shortNames + 1, true end

    shortName = tostring(shortName):upper()
    for rank, entry in ipairs(HealStateConfig.GetRezClasses()) do
        if entry.class == shortName then
            return rank, HealStateConfig.GetRezClassEnabled(entry, inCombat)
        end
    end

    return #Classes.shortNames + 1, true
end

---@param entry table a row of the class list
---@param inCombat boolean
---@return boolean enabled out of a fight this is always true: the flag only gates fights
function HealStateConfig.GetRezClassEnabled(entry, inCombat)
    if not inCombat then return true end
    return entry.in_combat ~= false
end

---@param shortName string
---@param enable boolean whether a fight is interrupted for this class
function HealStateConfig.SetRezClassInCombat(shortName, enable)
    for _, entry in ipairs(HealStateConfig.GetRezClasses()) do
        if entry.class == shortName then
            entry.in_combat = enable == true
            Global.configStore:SaveConfig()
            return
        end
    end
end

---Move a class one place up or down the order. The list is the priority, so this is the whole of
---editing it -- the same up/down the heal slots are reordered with.
---@param index number
---@param offset number -1 or 1
function HealStateConfig.MoveRezClass(index, offset)
    local classes = HealStateConfig.GetRezClasses()
    local to = index + offset
    if classes[index] == nil or classes[to] == nil then return end

    local moved = table.remove(classes, index)
    table.insert(classes, to, moved)
    Global.configStore:SaveConfig()
end

---@return table actions the heal slots, in the order they are tried
function HealStateConfig.GetActions()
    return getConfigSection().actions
end

---Every action list this state owns, in the shape the shared `action` command and the menu both
---read. There is only one here, unlike the melee state's three.
---@return table actionLists array of { label, actions }
function HealStateConfig.GetActionLists()
    return { { label = "Heal", actions = HealStateConfig.GetActions() } }
end

---------------- Heal slot fields --------------------

---These are written straight to the live slot rather than staged behind a Save, for the same
---reason the Enabled switch is: a threshold is not part of *describing* a heal, it is the dial
---you reach for while watching a fight go badly.

---@param action Action
---@return number pct use this heal on someone at or below this health
function HealStateConfig.GetThreshold(action)
    return tonumber(action.hp_threshold) or defaultThreshold
end

---@param action Action
---@param pct number
function HealStateConfig.SetThreshold(action, pct)
    action.hp_threshold = math.max(math.min(math.floor(pct), 100), 1)
    Global.configStore:SaveConfig()
end

---@param action Action
---@return string scope one of HealStateConfig.scopes values
function HealStateConfig.GetScope(action)
    local scope = action.heal_scope
    for _, known in pairs(HealStateConfig.scopes) do
        if known.value == scope then return scope end
    end
    return HealStateConfig.scopes.Any.value
end

---@param action Action
---@param scope string
function HealStateConfig.SetScope(action, scope)
    action.heal_scope = scope
    Global.configStore:SaveConfig()
end

---How many people have to be hurt before a group heal is worth casting. Only means anything for
---a slot holding a spell that heals the group rather than a target.
---@param action Action
---@return number count
function HealStateConfig.GetGroupMin(action)
    return tonumber(action.group_min) or defaultGroupMin
end

---@param action Action
---@param count number
function HealStateConfig.SetGroupMin(action, count)
    action.group_min = math.max(math.min(math.floor(count), 6), 1)
    Global.configStore:SaveConfig()
end

---@param scope string
---@return string display
function HealStateConfig.GetScopeDisplay(scope)
    for _, known in pairs(HealStateConfig.scopes) do
        if known.value == scope then return known.display end
    end
    return HealStateConfig.scopes.Any.display
end

---@diagnostic disable-next-line: duplicate-set-field
function HealStateConfig.Print()
    TableUtils.Print(getConfigSection())
end

return HealStateConfig
