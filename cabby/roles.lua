---@diagnostic disable: undefined-field
local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local StringUtils = require("utils.StringUtils.StringUtils")
local Time = require("utils.Time.Time")

local ChelpDocs = require("cabby.commands.chelpDocs")
local Commands = require("cabby.commands.commands")
local SlashCmd = require("cabby.commands.slashcmd")

---Who holds which job, and what the main assist is on.
---
---The group window already answers this and every EQ player already sets it, so nothing here is
---configured: main tank and main assist are read out of the client the same way the character's
---level is. That is the point -- a group that reassigns the tank mid-session has said everything
---it needs to say, and no cabby character has to be told separately.
---
---**It reads and nothing else.** Whether a role is worth acting on is the caller's business:
---`cabby.combat` uses the assist's target to decide what to fight, `states/healState.lua` uses the
---tank to decide who a tank-scoped heal is for, and each one applies its own judgment about range,
---health and whether the thing is worth the mana. Keeping that split is what lets the tank matter
---to the healer without the healer knowing anything about how the group engages.
---
---Two client facts shape what can be answered:
---
---- **Main tank is a group role, and only a group role.** The raid window has a main assist (three
---  of them) and a leader, but no tank -- inside a raid the tank of *this* group is still the group
---  window's, which is what a healer wants anyway.
---- **The assist's target comes from the client, not from watching them.** There is no way to read
---  what another player has targeted; what there is, is the client's own record of the assist
---  target (`Me.GroupAssistTarget`, `Me.RaidAssistTarget[#]`) -- the same value `/assist` and the
---  group window's assist display work off. When a server does not keep it current, this reads as
---  "the assist is on nothing", and the tank's own `assist` call (see `cabby.combat`) is the path
---  that does not depend on it. `/croles` says which of the two is answering.
---@class Roles
local Roles = {
    key = "Roles",
    _ = {
        isInit = false,
        lastScanMs = 0,
        mainTank = nil,
        mainAssist = nil,
        assistTarget = nil
    }
}

---How often the roles are re-read. They change when somebody drags a name onto a role in the
---group window, which is to say hardly ever -- but the assist's target moves with every pull, and
---this is also what the menu pages read every frame, so it is one cheap scan for both.
local scanIntervalMs = 250

---The raid can name three assists; `Me.RaidAssistTarget` is indexed by that slot.
local maxRaidAssists = 3

---@param str string
local function DebugLog(str)
    Debug.Log(Roles.key, str)
end

---@param member any a groupmember or raidmember TLO
---@param source string which window the role was read out of
---@return table? role { name, id, source }; nil when nobody holds it
local function readMember(member, source)
    local name = member.Name()
    if name == nil or name == "" then return nil end

    -- a member who is out of zone has no spawn, and the name is the identity that matters
    return { name = name, id = tonumber(member.Spawn.ID()) or 0, source = source }
end

---@return table? target { id, name }
local function readAssistTarget()
    ---@param spawn any a spawn TLO
    ---@return table? target
    local function asTarget(spawn)
        local id = tonumber(spawn.ID())
        if id == nil or id < 1 then return nil end
        return { id = id, name = spawn.CleanName() or ("spawn " .. tostring(id)) }
    end

    local target = asTarget(mq.TLO.Me.GroupAssistTarget)
    if target ~= nil then return target end

    for slot = 1, maxRaidAssists do
        target = asTarget(mq.TLO.Me.RaidAssistTarget(slot))
        if target ~= nil then return target end
    end

    return nil
end

local function scan()
    Roles._.mainTank = readMember(mq.TLO.Group.MainTank, "group")

    -- the group window first: a raid assist is a raid-wide call, and a group inside a raid is
    -- often working on something of its own with its own assist named
    Roles._.mainAssist = readMember(mq.TLO.Group.MainAssist, "group")
        or readMember(mq.TLO.Raid.MainAssist, "raid")

    Roles._.assistTarget = readAssistTarget()
end

---@return table roles the private table, re-read when the scan interval has passed
local function current()
    local now = Time.current_time()
    if now - Roles._.lastScanMs >= scanIntervalMs then
        Roles._.lastScanMs = now
        scan()
    end
    return Roles._
end

---Re-read the roles now rather than on the next scan.
function Roles.Refresh()
    Roles._.lastScanMs = Time.current_time()
    scan()
end

---Is this role held by that character?
---
---By spawn id where both sides have one, and by name otherwise -- a role holder who is out of the
---zone has no spawn, and the name is the identity the group window works in either way.
---@param role table? one of the roles returned below
---@param id number|nil spawn id to test
---@param name string|nil clean name to test
---@return boolean matches
function Roles.Matches(role, id, name)
    if role == nil then return false end

    id = tonumber(id)
    if role.id > 0 and id ~= nil then return role.id == id end

    return name ~= nil and role.name:lower() == tostring(name):lower()
end

---@param role table? as returned by the getters below
---@return boolean isMe
local function isMe(role)
    return Roles.Matches(role, mq.TLO.Me.ID(), mq.TLO.Me.CleanName())
end

---@return table? mainTank { name, id, source }; nil when the group has not named one
function Roles.GetMainTank()
    return current().mainTank
end

---@return table? mainAssist { name, id, source }; nil when neither group nor raid has named one
function Roles.GetMainAssist()
    return current().mainAssist
end

---What the main assist has targeted, as the client reports it.
---@return table? target { id, name }; nil when they are on nothing, or the server does not say
function Roles.GetAssistTarget()
    return current().assistTarget
end

---@return boolean isMainTank whether this character holds the role
function Roles.IsMainTank()
    return isMe(current().mainTank)
end

---@return boolean isMainAssist whether this character holds the role
function Roles.IsMainAssist()
    return isMe(current().mainAssist)
end

---@param role table?
---@return string description
local function describeRole(role)
    if role == nil then return "nobody" end
    return role.name .. (isMe(role) and " (me)" or "") .. " [" .. role.source .. "]"
end

---@return string description one line, for the state pages
function Roles.Describe()
    local roles = current()
    return "tank: " .. describeRole(roles.mainTank) .. "  |  assist: " .. describeRole(roles.mainAssist)
end

function Roles.Init()
    if Roles._.isInit then return end

    local ftkey = Global.tracing.open("Roles Setup")

    local crolesDocs = ChelpDocs.new(function() return {
        "(/croles) Report the group and raid roles this character can see",
        " -- Usage: /croles",
        " -- Roles are read out of the group window (and the raid's main assist), never configured",
        "    here: set them the way the group already does and every cabby character follows.",
        " -- Main tank is a group role even inside a raid -- the raid window has no tank.",
        " -- What the assist is on comes from the client's own assist target. A server that does",
        "    not keep it current reads as `nothing`, and the tank's (assist) call still works."
    } end )
    local function Bind_CRoles(...)
        local args = {...} or {}
        if #args > 0 and args[1]:lower() == "help" then
            crolesDocs:Print()
            return
        end

        Roles.Refresh()
        local roles = Roles._

        print("Roles: " .. Roles.Describe())
        if roles.assistTarget ~= nil then
            print(" -- the assist is on: " .. roles.assistTarget.name ..
                " (id " .. tostring(roles.assistTarget.id) .. ")")
        else
            print(" -- the assist is on: nothing")
        end

        local mine = {}
        if Roles.IsMainTank() then mine[#mine+1] = "main tank" end
        if Roles.IsMainAssist() then mine[#mine+1] = "main assist" end
        print(" -- I hold: " .. (#mine > 0 and StringUtils.Join(mine, ", ") or "no role"))
    end
    Commands.RegisterSlashCommand(SlashCmd.new("croles", Bind_CRoles, crolesDocs))

    DebugLog("Roles registered")
    Roles._.isInit = true
    Global.tracing.close(ftkey)
end

return Roles
