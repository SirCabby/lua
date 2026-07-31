---@diagnostic disable: undefined-field
local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local StringUtils = require("utils.StringUtils.StringUtils")
local Time = require("utils.Time.Time")

local ChelpDocs = require("cabby.commands.chelpDocs")
local Command = require("cabby.commands.command")
local Commands = require("cabby.commands.commands")
local CombatConfig = require("cabby.configs.combatConfig")
local Roles = require("cabby.roles")
local SlashCmd = require("cabby.commands.slashcmd")
local Speak = require("cabby.commands.speak")
local Status = require("cabby.status")
local ToggleCommand = require("cabby.commands.toggleCommand")
local UserInput = require("cabby.utils.userinput")

---What this character is fighting.
---
---This used to be a field on the melee state, which was fine for exactly as long as melee was the
---only way to hurt something. A wizard fights the same mob a warrior does and has no melee state
---to keep it in, and `attack <id>` has to mean the same thing to both, so the engagement is its
---own thing: one target, whoever put it there, and everything that fights reads it.
---
---It holds no opinion about *how* to fight. The melee state gets on target and swings, the spell
---dps state casts at it, a tank state will taunt it -- and each one decides for itself whether it
---is in range, whether it is worth it, and when to give up.
---
---The engagement is *our* side of a fight. The world's side -- something out there actually
---fighting us, agreed to or not -- is published alongside it as `IsUnderAttack`, because with
---auto-engage off the two can disagree: a character can be under a beating it never picked up.
---What to do about that is each reader's own question; this service only keeps the fact honest.
---
---**It runs no game commands that decide anything.** Engaging is bookkeeping, which is what makes
---it safe to call from an ImGui button (the Attack button used to run `/mqtarget` from inside the
---render callback, which is the crash-to-desktop hazard the movement service is built around). The
---one thing it does say out loud -- the main tank calling the assist -- is said from `Pulse` and
---from nowhere else, for the same reason. `SetAutoAttack` is the one function here that runs a
---game command for its caller, and carries its own warning: states and services only, never a
---render callback.
---@class Combat
local Combat = {
    key = "Combat",
    eventIds = {
        assist = "assist",
        assistOnEngage = "assistonengage",
        attack = "attack",
        autoEngage = "autoengage",
        callAssist = "callassist",
        callDefend = "calldefend",
        defend = "defend",
        easeOff = "easeoff",
        disengageOnAttackOff = "disengageonattackoff",
        disengageOnTargetClear = "disengageontargetclear",
        engageOnAttack = "engageonattack"
    },
    ---How an engagement was decided, which is what says whether something weaker may replace it.
    ---An `order` is somebody's explicit choice and is never taken away automatically; the others
    ---are this character working it out for itself.
    sources = {
        order = "order",
        assist = "assist",
        hater = "hater",
        rescue = "rescue"
    },
    _ = {
        isInit = false,
        targetId = 0,
        engagedBy = nil,
        source = nil,
        engagedAtMs = 0,
        lastScanMs = 0,
        fightOpenUntilMs = nil,
        calledId = nil,
        underAttack = false,
        underAttackIds = nil,
        fightIds = nil,
        lastUnderAttackMs = 0,
        defendReports = {},
        ---{ [speaker] = id } for every assist call heard, which is the only way a client is told
        ---what another character is fighting
        assistCalls = {},
        zoneId = 0,
        attackWasOn = false,
        clientTargetWasId = 0,
        scriptedAttack = nil
    }
}

---How often the extended target window is swept looking for something that is attacking us.
---Twenty TLO reads is not free, and nothing is lost by noticing a quarter of a second late.
local scanIntervalMs = 250

---How long a fight stays open after its target is lost with nothing yet to replace it.
---
---This is the continuity the whole chain hangs off. A fight with three mobs is one fight, not
---three fights with gaps: the states that fight hold their frames off `IsEngaged`, and everything
---below them trusts that a frame it is given is a frame with no fight in it. So "the fight is
---over" must not blink true between one mob and the next just because the extended target window
---is a beat behind a corpse hitting the ground. While the fight is open with no target the sweep
---runs every pulse rather than on the ambient throttle, so the successor is engaged on the pulse
---it shows up.
---
---Short on purpose, and shorter than any real gap between pulls: between pulls the fight *is*
---over, and the chain falling through then is the design working -- sitting back down between
---pulls is the whole job of the state at the bottom of it. This bridges client lag inside one
---fight, nothing more.
local fightLingerMs = 500

---Where the assist call goes when nothing has been configured to speak on.
---
---Every other `speak` in cabby is a *report* -- "cannot see you to heal you", "I failed to click
---into the zone" -- and a character with no speak channels keeping those to itself is a reasonable
---thing to be. This one is not a report: it **is** assisting, on by default, and a group hears
---nothing without it. A tank that has never run `/speak` would lead nobody and say nothing about
---why, which is the worst of the three possible behaviours.
---
---So it falls back rather than being swallowed. `/speak assist <channel>` sends it somewhere else,
---and `callassist off` is how it is turned off -- an empty speak list is not that answer.
local fallbackAssistSpeak = Speak.new({ Speak.channelTypes.group.name })

---@param str string
local function DebugLog(str)
    Debug.Log(Combat.key, str)
end

---Where the defend report goes when nothing has been configured to speak on.
---
---Load-bearing the way the assist call is -- an unheard report is a healer eaten in silence --
---but it is machine-to-machine traffic for one listener, the tank, not something the group
---reads. bc reaches every connected character without scrolling anybody's group chat;
---/speak defend <channel> sends it somewhere else.
local fallbackDefendSpeak = Speak.new({ Speak.channelTypes.bc.name })

---@return Speak speak where the assist call goes
---@return boolean isFallback whether nothing was configured and the default above is answering
local function assistSpeak()
    local speak = Commands.GetCommandSpeak(Combat.eventIds.assist)
    if #speak:GetActiveSpeakChannels() > 0 then return speak, false end
    ---@diagnostic disable-next-line: return-type-mismatch
    return fallbackAssistSpeak, true
end

---@return Speak speak where the defend report goes
---@return boolean isFallback whether nothing was configured and the default above is answering
local function defendSpeak()
    local speak = Commands.GetCommandSpeak(Combat.eventIds.defend)
    if #speak:GetActiveSpeakChannels() > 0 then return speak, false end
    ---@diagnostic disable-next-line: return-type-mismatch
    return fallbackDefendSpeak, true
end

---@return number targetId 0 when not engaged
function Combat.GetTargetId()
    return Combat._.targetId
end

---In a fight, which outlives any one target: the beat after a mob dies while the successor is
---still being sought (see fightLingerMs) is the same fight, and every state that holds its frame
---off this answer keeps holding it across that beat.
---@return boolean isEngaged
function Combat.IsEngaged()
    return Combat._.targetId > 0 or Combat.IsSeeking()
end

---@return boolean isSeeking the fight is open with its target lost, looking for the successor
function Combat.IsSeeking()
    return Combat._.fightOpenUntilMs ~= nil
end

---What the group's main tank is fighting, as far as this client can be made to know.
---
---There is no reading another player's target (see `cabby.roles`), so the answer is assembled from
---the three ways it is knowable, strongest first: **the tank is us**, and our own engagement is the
---answer; **the tank said so**, which is what an `assist` call is -- one line per target, spoken by
---name, taken back by `assist off`, and heard by everyone; or **the tank holds the assist role as
---well**, in which case the client's own assist record is a record of the tank's target.
---
---Nil is "nobody here can say", which is a different answer from "the tank is on nothing" and must
---not be read as one -- a caller that treats them alike is acting on a group it cannot see. What to
---do about not knowing is the caller's own question: `states/petDpsState.lua` reads it as "the tank
---has it", because a pet taunting a mob off a warrior is the expensive way to be wrong.
---@return number|nil id
function Combat.GetTankTargetId()
    if Roles.IsMainTank() then
        -- mid-seek this is 0, and the honest answer then is that nobody can say yet
        return Combat._.targetId > 0 and Combat._.targetId or nil
    end

    local tank = Roles.GetMainTank()
    if tank == nil then return nil end

    -- by name, because a call carries the speaker's name and nothing else -- which is the identity
    -- the group window works in anyway
    for speaker, id in pairs(Combat._.assistCalls) do
        if Roles.Matches(tank, nil, speaker) then return id end
    end

    local assist = Roles.GetMainAssist()
    if assist ~= nil and Roles.Matches(tank, nil, assist.name) then
        local target = Roles.GetAssistTarget()
        if target ~= nil then return target.id end
    end

    return nil
end

---Have we taken the mob off the tank, so that the damage should stop until it is back?
---
---One question about the fight, answered here rather than twice over in the two states that hurt
---things: **the mob we are hurting is coming for us, and holding it is somebody else's job.** Both
---halves are already this service's facts -- the top of a hate list is `GetUnderAttackIds`, and
---what the tank is on is `GetTankTargetId` -- so this is a reading of them and nothing new. What
---to *do* about it stays with the caller, which is why the two answers differ: melee drops the
---swing and the ability lists (`states/meleeState.lua`), the rotation holds everything aimed at
---the mob and lets a shield through (`states/spellDpsState.lua`).
---
---Continuous, like everything else built on the hater sweep, and re-derived every pass: the moment
---the tank is back on top of the list the answer is false again and the damage resumes on that same
---pass. There is nothing to remember and nothing to time -- "it has been a while, start again" would
---be starting again into the same mob still coming for us.
---
---Four things say no, in the order they are asked:
---
---- **the switch is off**, which is the player saying they will manage it themselves;
---- **we are the main tank**, whose aggro is the job rather than a mistake to undo;
---- **nobody holds the tank role**, so there is no one to hand the mob back to -- a character that
---  stopped hitting what is eating it would be waiting for a rescue that was never coming;
---- **the tank is on something else**, which makes this ours: an add that picked us is not a mob we
---  pulled off anybody, and the `defend` report is what is already being said about it.
---
---**Not knowing what the tank is on reads as "the tank has this one"**, the same way
---`states/petDpsState.lua` reads it for its taunt, and for the same reason -- the two are one
---question ("is somebody else supposed to be holding this?") and answering it two ways in one
---script is incoherent. The costs are not symmetric either: a character that keeps ripping the mob
---off the tank is how a group wipes, and one that eases off a mob nobody else was on is still on
---the tank's radar, because being at the top of that hate list is exactly what the `defend` report
---is spoken from.
---@return boolean easeOff
---@return string|nil why in words, for the pages and `/cattack`
function Combat.ShouldEaseOff()
    if not CombatConfig.GetEaseOff() then return false, nil end
    if Roles.IsMainTank() then return false, nil end
    if Roles.GetMainTank() == nil then return false, nil end

    -- Between targets there is nothing being hurt and so nothing to ease off; the mob that is on
    -- us mid-seek is the next thing this fight engages, not something to be quiet about.
    local targetId = Combat._.targetId
    if targetId == 0 then return false, nil end

    local isOnUs = false
    for _, id in ipairs(Combat._.underAttackIds or {}) do
        if id == targetId then
            isOnUs = true
            break
        end
    end
    if not isOnUs then return false, nil end

    local tankOn = Combat.GetTankTargetId()
    if tankOn ~= nil and tankOn ~= targetId then return false, nil end

    if tankOn == nil then
        return true, "it is coming for me, and the main tank's target cannot be seen from here"
    end
    return true, "I have it off the main tank"
end

---Something out there is fighting *us* -- we are at the top of an auto-hater's hate list, the one
---it is actually coming for -- whether or not we have decided to fight it back. Independent of the
---engagement on purpose: engaged-but-not-under-attack is us beating on something that has not
---turned around yet, and under-attack-but-not-engaged is a beating nobody agreed to, which is
---exactly the case auto-engage off creates. Answers from the last scan; Pulse keeps it fresh.
---@return boolean isUnderAttack
function Combat.IsUnderAttack()
    return Combat._.underAttack
end

---Which mobs are coming for us, as `IsUnderAttack` in detail rather than in summary: everything on
---the extended target window that hates us *most*, from the last scan.
---
---The list is the fact and the *leaving* of it is a fact too, which is what makes it worth
---publishing at all: a mob drops out of it the moment somebody else takes it, because we are no
---longer the one it is coming for. `states/petDpsState.lua` peels with exactly that -- it sends the
---pet at what is on us and knows the peel took when the mob is no longer listed, with nothing timed
---and nothing assumed.
---
---The private table, in the order the window lists it (which is stable across scans, and is what
---keeps a caller choosing off it from picking a different one every pass). Callers read it; nobody
---modifies it.
---@return number[]|nil ids nil when nothing is coming for us
function Combat.GetUnderAttackIds()
    return Combat._.underAttackIds
end

---Everything on the extended target window that is fighting us, whatever its aggro -- the whole
---`Auto Hater` list rather than the `GetUnderAttackIds` subset that is coming for us *most*.
---
---Published beside that subset because the two are different facts and a reader usually wants one
---of them exactly: "what has us at the top of its hate list" is what a peel is aimed at, and "what
---is in this fight with us at all" is what crowd control has to cover. `cabby.mobs` merges this
---with the other angles.
---@return number[]|nil ids nil when the window says we are in no fight
function Combat.GetHaterIds()
    return Combat._.fightIds
end

---The standing `defend` reports: mobs a group member has said are beating on them, oldest first.
---
---The one thing this client learns about the fight that it could never see for itself -- the
---extended target window lists only what hates *us* -- and already swept for death, zone and flee.
---Ids only; who reported each one is the tank's business and stays private.
---@return number[] ids never nil; empty when nothing has been called
function Combat.GetDefendIds()
    local reported = {}
    for id, report in pairs(Combat._.defendReports) do
        reported[#reported + 1] = { id = id, firstMs = report.firstMs }
    end
    table.sort(reported, function(left, right) return left.firstMs < right.firstMs end)

    local ids = {}
    for _, entry in ipairs(reported) do ids[#ids + 1] = entry.id end
    return ids
end

---Every mob in this fight, as far as this client can know of them -- not just the one we are
---killing. For the jobs that are about the fight rather than about the kill: a debuff spread
---across everything on us before the rotation goes back to the primary is the worked example.
---
---Assembled from the three things this client is ever told, and nothing else -- there is no
---sweeping the room for spawns, so a mob nobody is fighting can never appear here:
---
---- **what we are fighting**, first, because it is the one being killed and everything else is
---  the rest of the fight around it;
---- **everything on the extended target window**, which is the client saying these are fighting
---  us -- more than `GetUnderAttackIds`, which is only the ones we are top of;
---- **the standing defend reports**, which are mobs beating on group members who cannot shed
---  them. Invisible to our own window (it lists only what hates *us*) and already swept for
---  death, zone and flee, they are the adds a caster would otherwise never hear about.
---
---Oldest report first among those, the order the tank picks them up in. Nothing here says a mob
---is *reachable*: whether a cast can be aimed at one of these is the caller's own question, asked
---of the world every pass.
---@return number[] ids never nil; empty when we are in no fight at all
function Combat.GetFightIds()
    local ids, seen = {}, {}

    local function add(id)
        if id == nil or id < 1 or seen[id] then return end
        seen[id] = true
        ids[#ids + 1] = id
    end

    add(Combat._.targetId)
    for _, id in ipairs(Combat._.fightIds or {}) do add(id) end
    for _, id in ipairs(Combat.GetDefendIds()) do add(id) end

    return ids
end

---@param id number
---@param by? string what decided this, in words
---@param source? string one of Combat.sources; anything asked for by a person is an order
function Combat.Engage(id, by, source)
    id = tonumber(id) or 0
    if id < 1 then return end
    if Combat._.targetId == id then return end

    Combat._.targetId = id
    Combat._.engagedBy = by or "an order"
    Combat._.source = source or Combat.sources.order
    Combat._.engagedAtMs = Time.current_time()
    -- the fight has its target (again); nothing left to seek
    Combat._.fightOpenUntilMs = nil
    DebugLog("Engaged " .. tostring(id) .. " (" .. Combat._.engagedBy .. ")")
end

---Close the fight, seek and all. This is the *deliberate* end -- an order, a flee, the seek
---coming up empty -- as against losing a target mid-fight, which is beginSeeking's case and
---keeps the fight open.
---@param reason? string
function Combat.Disengage(reason)
    if Combat._.targetId == 0 and not Combat.IsSeeking() then return end

    DebugLog("Disengaged " .. tostring(Combat._.targetId) .. (reason ~= nil and (": " .. reason) or ""))
    Combat._.targetId = 0
    Combat._.engagedBy = nil
    Combat._.source = nil
    Combat._.fightOpenUntilMs = nil
end

---The target is lost but the fight may not be over: hold it open and look hard for the successor.
---Only ever for a target this character *lost* -- it died, it despawned -- never for one it was
---told to drop: an order to stop is Disengage, and stopping is immediate.
---@param why string
local function beginSeeking(why)
    DebugLog("Lost " .. tostring(Combat._.targetId) .. " (" .. why .. "); holding the fight open")
    Combat._.targetId = 0
    Combat._.engagedBy = "between targets"
    Combat._.fightOpenUntilMs = Time.current_time() + fightLingerMs
end

---The script's own hand on the client's attack toggle -- melee gating the swing by range is the
---case it exists for. Routed through here so the edge watcher in `Pulse` can tell the script's
---toggles from the player's: a switch-off out of melee range is bookkeeping, and reading it as
---`attack off` said with the keyboard would close the fight and, from a tank, call the whole
---group off it (`disengageonattackoff` and the off-call) over a mob that stepped back. The mark
---is consumed by the next edge, so only the toggle this call flips is excused -- the player's
---next press still means what it always means.
---
---The one function in this module that runs a game command for its caller, so the render-callback
---rule applies: states and services only, never from ImGui (CommandQueue exists for that).
---@param on boolean
---@param why string for the debug log, so the toggle's history reads in words
function Combat.SetAutoAttack(on, why)
    if (mq.TLO.Me.Combat() == true) == on then return end
    Combat._.scriptedAttack = on
    DebugLog("Auto attack " .. (on and "on" or "off") .. ": " .. why)
    mq.cmd(on and "/attack on" or "/attack off")
end

---@return string description for status output
function Combat.Describe()
    if not Combat.IsEngaged() then return "standby" end
    if Combat.IsSeeking() then return "in a fight, between targets" end

    local name = mq.TLO.Spawn("id " .. tostring(Combat._.targetId)).CleanName()
    return "engaged with " .. (name or ("spawn " .. tostring(Combat._.targetId))) ..
        " (" .. tostring(Combat._.engagedBy) .. ")"
end

---Anything on the extended target window that is on us. `Auto Hater` is the client's own word for
---"this is fighting you", which is a better answer than anything we could work out ourselves.
---@return number|nil id
local function findAutoHater()
    for slot = 1, 20 do
        local xtarget = mq.TLO.Me.XTarget(slot)
        if xtarget.TargetType() == "Auto Hater" then
            local id = tonumber(xtarget.ID())
            if id ~= nil and id > 0 then return id end
        end
    end
    return nil
end

---What is fighting us, in one sweep of the extended target window: everything on it, and the
---subset that hates us *most*.
---
---`Auto Hater` is the client's own word for "this is fighting you", so the whole list is what we
---are in a fight with. `PctAggro` at 100 is the aggro meter saying "you are the one it is coming
---for", which is the narrower fact: most-hated rather than merely listed, and it matters -- a
---healer rides every fight's hate list off the heals alone, and a fact that read "listed" would
---keep it on its feet through fights it is medding through on purpose.
---
---One function for both because both come off the same twenty reads, which is not free. Gated on
---the client's own combat flag for the same reason the auto-engage sweep is: a mob that hates us
---from across the zone is not fighting us yet.
---@return number[]|nil fightIds everything on the window that is fighting us, in window order
---@return boolean isUnderAttack
---@return number[]|nil ids the mobs actually coming for us, when there are any
local function scanHaters()
    if mq.TLO.Me.CombatState() ~= "COMBAT" then return nil, false, nil end

    local fightIds, ids = nil, nil
    for slot = 1, 20 do
        local xtarget = mq.TLO.Me.XTarget(slot)
        if xtarget.TargetType() == "Auto Hater" then
            local id = tonumber(xtarget.ID())
            if id ~= nil and id > 0 then
                fightIds = fightIds or {}
                fightIds[#fightIds + 1] = id
                if (tonumber(xtarget.PctAggro()) or 0) >= 100 then
                    ids = ids or {}
                    ids[#ids + 1] = id
                end
            end
        end
    end
    return fightIds, ids ~= nil, ids
end

---Spawn types worth picking a fight with: mobs, pets, and the destructible objects the client
---types as `Object` (a catapult, a cocoon cluster). Not players, and not corpses -- a dead mob
---keeps its spawn id, and a fight is never picked up from a body.
local fightableTypes = { NPC = true, Pet = true, Object = true }

---What the main assist is on, when that is something worth picking a fight with.
---
---Two things are asked beyond "is it there", and both are about not starting a fight the group is
---not having. It has to be a **fightable type** -- which admits pets and destructibles, so the one
---thing keeping this off a group member's own wounded pet is the next check -- and it has to have
---**taken damage**, which is the difference between a thing the group is fighting and one the
---assist targeted to read its name off. That second check is why this path needs no percentage
---setting: the tank's own `assist` call is the order that opens a fight, and this is only the
---standing question of what the group is already on.
---@return number|nil id
local function assistTargetId()
    -- the assist leading itself is a character that attacks whatever it looks at
    if Roles.IsMainAssist() then return nil end

    local target = Roles.GetAssistTarget()
    if target == nil then return nil end

    local spawn = mq.TLO.Spawn("id " .. tostring(target.id))
    if spawn.ID() == nil or spawn.Dead() or not fightableTypes[spawn.Type()] then return nil end

    local pct = tonumber(spawn.PctHPs())
    if pct == nil or pct >= 100 then return nil end

    return target.id
end

---Drop the reports the world has taken back -- the mob is dead, gone, or not something to fight.
---
---Runs on every character on the ambient throttle, tank or not: the same table is the tank's
---radar and everybody's record of what has already been called, and both go stale the same way.
---This is what bounds it. Left to be swept only when it is read, a night's camp in one zone
---would hold an entry for every mob that ever turned on somebody, and the tank's pickup reads a
---spawn per entry four times a second.
local function sweepDefendReports()
    for id in pairs(Combat._.defendReports) do
        local spawn = mq.TLO.Spawn("id " .. tostring(id))
        if spawn.ID() == nil or spawn.Dead() or not fightableTypes[spawn.Type()] then
            Combat._.defendReports[id] = nil
        end
    end
end

---Drop the assist calls the world has taken back, on the same reasoning and the same cadence as
---the defend sweep above.
---
---A call is a statement that stands until the speaker replaces it or takes it back, and there is
---one way for it to go stale in between: the mob dies while that character says nothing more --
---`callassist` switched off mid-session, a tank that is not running cabby at all. What the world
---says about the mob settles it, so the record can never outlive the fight it describes.
local function sweepAssistCalls()
    for speaker, id in pairs(Combat._.assistCalls) do
        local spawn = mq.TLO.Spawn("id " .. tostring(id))
        if spawn.ID() == nil or spawn.Dead() or not fightableTypes[spawn.Type()] then
            Combat._.assistCalls[speaker] = nil
        end
    end
end

---The standing report of a mob beating on somebody who cannot shed it -- the longest-standing
---one, since that victim has been waiting longest. A report is said once and stands until the
---world takes it back, so the spawn is asked again here rather than trusted from the sweep,
---because acting is when it has to be true: a mob that went down in the last quarter second is
---not something to charge at.
---@return number|nil id
---@return string|nil reporter
local function oldestDefendReport()
    local bestId, bestReport = nil, nil
    for id, report in pairs(Combat._.defendReports) do
        local spawn = mq.TLO.Spawn("id " .. tostring(id))
        if spawn.ID() == nil or spawn.Dead() or not fightableTypes[spawn.Type()] then
            Combat._.defendReports[id] = nil
        elseif bestReport == nil or report.firstMs < bestReport.firstMs then
            bestId, bestReport = id, report
        end
    end
    if bestId == nil then return nil, nil end
    return bestId, bestReport.reporter
end

---The main tank saying what everyone should be on.
---
---This is the half of assisting that does not depend on the client keeping an assist target for
---us: whoever holds the group's main tank role says `assist <id>` out loud whenever what they are
---fighting changes, and every listener engages it the way an `attack` order would. It is one line
---per target rather than a heartbeat -- a character that misses one has its own auto-engage to
---fall back on, and chat that repeats itself is chat nobody reads.
---
---Called off as loudly as it is called on: the tank dropping its target says `assist off`, which
---is how a group stops fighting on the tank's say-so rather than one character at a time. That
---covers backing off by hand and the `flee` order alike, since both end with the tank disengaged.
---
---`assistonengage` is the same mouth with no role in front of it: a character carrying that
---switch announces its own fights -- and calls them off -- exactly as the tank would, for a group
---led by whichever character the player is actually driving rather than by the group window's
---roles. Off by default, since a whole group announcing at once is chat nobody reads.
local function callAssist()
    -- Between targets the fight is not over and there is nothing to say yet: the next line is
    -- either the successor's id or the off-call, depending on how the seek resolves. Saying "off"
    -- in the beat between two mobs would call the group off a fight that is still on.
    if Combat.IsSeeking() then return end

    -- Not calling is not the same as having called nothing: forget what was said, so that taking
    -- the lead back -- the role, either switch -- re-announces the fight instead of assuming
    -- everyone heard.
    local tankCalls = CombatConfig.GetCallAssist() and Roles.IsMainTank()
    if not tankCalls and not CombatConfig.GetAssistOnEngage() then
        Combat._.calledId = nil
        return
    end

    local id = Combat.GetTargetId()
    if Combat._.calledId == id then return end

    -- nothing to call off when nothing was ever called on -- the state a character starts in
    if id == 0 and Combat._.calledId == nil then
        Combat._.calledId = 0
        return
    end

    Combat._.calledId = id
    local phrase = Combat.eventIds.assist .. " " .. (id > 0 and tostring(id) or "off")
    DebugLog("Calling the assist: " .. phrase)
    assistSpeak():speak(phrase)
end

---A beating this character cannot shed, said out loud -- once per mob, group-wide -- for the
---one who can.
---
---The mob eating the healer is invisible to the tank's client -- the extended target window only
---lists what hates *you* -- so the fact is spoken from where it is knowable: whoever is at the
---top of a hate list says so, and the main tank hears `defend <ids>` and picks the mobs up when
---its hands are free. One line per mob for as long as it lives in this zone: saying it is what
---puts the mob on the tank's radar, the tank keeps it there until the world takes it back, and
---every character hears the same lines the tank does -- so the standing reports double as the
---group's shared record of what has been called, whoever called it. A mob bouncing between the
---tank and its victims, or between two victims, is never announced twice; what clears its entry
---is what would clear the tank's radar of it -- its death, a zone, a flee -- and only then is it
---news again. Our own line does not reliably come back to us (localecho is owner-gated), so the
---record is written at the mouth as well as at the ear.
---
---Two silences are deliberate. The main tank never reports -- everything coming for the tank is
---its own hater sweep's business. And the fight the *group was put on* is not reported: an
---engagement from an assist call or the assist's target is the group already knowing. A fight
---this character picked up for itself (its own hater sweep) is reported even though it is
---fighting back -- that is exactly the unattended beating the report exists for.
local function callDefend()
    if not CombatConfig.GetCallDefend() then return end
    if Roles.IsMainTank() then return end

    -- a run has nothing to say: nothing records it (the handler refuses, the wipe in Pulse
    -- empties the record), nothing acts on it, and a beating still real after the run is news
    if Status.IsFleeing() then return end

    local ids = Combat._.underAttackIds
    if ids == nil then return end

    local reports = Combat._.defendReports
    local groupKnows = Combat._.source == Combat.sources.assist
    local report = nil
    for _, id in ipairs(ids) do
        -- a filtered id is left unrecorded on purpose: if the group's fight ends while the mob
        -- is still on us, the beating becomes unattended and the very next pass announces it
        if reports[id] == nil and not (groupKnows and id == Combat._.targetId) then
            -- The window is a beat behind a corpse hitting the ground, and a line about one
            -- would be a line the tank refuses and a record entry standing for nothing. Asked
            -- only of what is about to be announced, which by now is a rare thing to have.
            local spawn = mq.TLO.Spawn("id " .. tostring(id))
            if spawn.ID() ~= nil and not spawn.Dead() and fightableTypes[spawn.Type()] then
                report = report or {}
                report[#report + 1] = id
            end
        end
    end
    if report == nil then return end

    local now = Time.current_time()
    local me = mq.TLO.Me.CleanName() or "me"
    for _, id in ipairs(report) do
        reports[id] = { reporter = me, firstMs = now }
    end

    local phrase = Combat.eventIds.defend .. " " .. table.concat(report, " ")
    DebugLog("Calling for defense: " .. phrase)
    defendSpeak():speak(phrase)
end

---Service contract: keep the engagement honest -- including the fight's continuity across a
---target dying -- say what we are on if the group looks to us for that, and pick one up when
---there is something to pick up.
function Combat.Pulse()
    local now = Time.current_time()

    -- Zoning resets the world's spawn ids, so everything keyed by one goes with it: a defend
    -- report from the last zone is about a mob that means nothing here, and a stale id kept
    -- across the line could even collide with a fresh spawn wearing it. Clearing the record is
    -- also what re-arms the one-line-per-mob rule -- on the far side of a zone, everything is
    -- news again. A flee empties it the same way, everywhere, reporter and tank alike: standing
    -- reports kept through a run would charge the tank -- and keep the reporters silent -- over
    -- mobs the group chose to leave.
    ---
    ---Heard assist calls go with them, and for the first of those reasons alone: a call is an id,
    ---an id means nothing on the far side of a zone line, and the character that spoke it will say
    ---the next one the moment it engages anything here. A run empties them for the same reason the
    ---reports go -- what the tank was on before the group ran is not what it is on now.
    local zoneId = tonumber(mq.TLO.Zone.ID()) or 0
    if zoneId ~= 0 and zoneId ~= Combat._.zoneId then
        Combat._.zoneId = zoneId
        if next(Combat._.defendReports) ~= nil then Combat._.defendReports = {} end
        if next(Combat._.assistCalls) ~= nil then Combat._.assistCalls = {} end
    end
    if Status.IsFleeing() then
        if next(Combat._.defendReports) ~= nil then Combat._.defendReports = {} end
        if next(Combat._.assistCalls) ~= nil then Combat._.assistCalls = {} end
    end

    -- The attack toggle and the client's target are watched every pulse without exception --
    -- engaged, dead, mid-seek -- so that the "it just changed" answers below can never fire late
    -- off a stale reading: a press seen while engaged is an edge consumed, not one saved up to
    -- charge something after the fight closes. Cabby's own toggles come through SetAutoAttack,
    -- which marks them so the block below can excuse them by name.
    local attackOn = mq.TLO.Me.Combat() == true
    local attackPressed = attackOn and not Combat._.attackWasOn
    local attackReleased = not attackOn and Combat._.attackWasOn
    Combat._.attackWasOn = attackOn

    -- An edge the script made is not the player's hand: the edge matching a SetAutoAttack mark
    -- is swallowed whole, so it can never read as an order below -- above all, melee dropping
    -- the swing out of range must not become `attack off` said with the keyboard. A mismatched
    -- edge is the player winning a race and keeps its meaning. Either way the mark dies on the
    -- first edge: whatever the toggle does after that, the script did not do it.
    if Combat._.scriptedAttack ~= nil and (attackPressed or attackReleased) then
        if attackPressed == Combat._.scriptedAttack then
            attackPressed = false
            attackReleased = false
        end
        Combat._.scriptedAttack = nil
    end

    local clientTargetId = tonumber(mq.TLO.Target.ID()) or 0
    -- what the client's target was cleared *from* this pulse; 0 while it was not cleared at all,
    -- including when it merely moved to something else (a heal borrows the target constantly)
    local clearedFromId = clientTargetId == 0 and Combat._.clientTargetWasId or 0
    Combat._.clientTargetWasId = clientTargetId

    -- Our own death is the one end of a fight nothing below watches for: every close in this
    -- file reads the *target*, and the mob that killed us is usually still standing. Die to it
    -- in the zone we bind in and its id keeps resolving -- the seek never opens, and the
    -- engagement would still be here, target and all, when we respawn, with melee re-acquiring
    -- the killer from across the zone. So death closes the fight the way an order would, and
    -- nothing is picked up while we are dead: the respawn window is not a frame to start a
    -- fight in. The off-call still goes out -- a dead main tank has exactly as much to call
    -- off as a fleeing one. HOVER is dead-but-not-released; DEAD is the beat before it.
    local myState = mq.TLO.Me.State()
    if myState == "DEAD" or myState == "HOVER" then
        Combat.Disengage("we died")
        -- dead is not under attack, and not in a fight; both facts start over with the respawn
        Combat._.underAttack = false
        Combat._.underAttackIds = nil
        Combat._.fightIds = nil
        callAssist()
        return
    end

    if Combat._.targetId > 0 then
        local spawn = mq.TLO.Spawn("id " .. tostring(Combat._.targetId))
        if spawn.ID() == nil then
            beginSeeking("it is gone")
        elseif spawn.Dead() or spawn.Type() == "Corpse" then
            beginSeeking("it is dead")
        end
    end

    -- a seek that found nothing in its window: the fight really is over now
    if Combat.IsSeeking() and now >= Combat._.fightOpenUntilMs then
        Combat.Disengage("nothing came to continue the fight")
    end

    -- The player calling the fight off in the client's language, honored the way the press is
    -- honored below: switching attack off, or clearing the target the fight is on, is `attack
    -- off` said with the keyboard. Both read edges, so only the act itself orders anything, and
    -- neither reads while fleeing -- travel drops auto attack every pass as bookkeeping, and the
    -- flee order has already said everything there is to say about the fight.
    if attackReleased and Combat.IsEngaged() and CombatConfig.GetDisengageOnAttackOff()
        and not Status.IsFleeing() then
        -- Only a toggle let go of, never one taken: a mez, a charm or a stun drops auto attack
        -- with nobody choosing to stop, and coming to with the whole fight called off is not
        -- what this switch is for. A feign is a choice, and does count.
        if not (mq.TLO.Me.Stunned() or mq.TLO.Me.Mezzed() ~= nil or mq.TLO.Me.Charmed() ~= nil) then
            Combat.Disengage("attack switched off by hand")
        end
    end

    if Combat._.targetId > 0 and clearedFromId == Combat._.targetId
        and CombatConfig.GetDisengageOnTargetClear() and not Status.IsFleeing() then
        -- Only a clear of the fight's own, still-standing target reads as an order. The world
        -- clears the client's target too -- the mob dies, the corpse poofs -- but the continuity
        -- above has turned those into a seek before this line; asking the spawn again covers the
        -- one that goes down on exactly this pulse.
        local spawn = mq.TLO.Spawn("id " .. tostring(Combat._.targetId))
        if spawn.ID() ~= nil and not spawn.Dead() and spawn.Type() ~= "Corpse" then
            Combat.Disengage("target cleared by hand")
        end
    end

    -- The world's side of the fight, kept fresh outside every gate below: whether something is
    -- coming for us is true or false regardless of what we have picked up, and auto-engage off
    -- is a choice about fighting back, not about whether the beating exists. Same throttle as
    -- the sweep, and for the same reason: twenty TLO reads is not free.
    if now - Combat._.lastUnderAttackMs >= scanIntervalMs then
        Combat._.lastUnderAttackMs = now
        Combat._.fightIds, Combat._.underAttack, Combat._.underAttackIds = scanHaters()
        -- the same cadence, and for the same reason: both are world-derived facts kept fresh at
        -- a rate nothing is lost by, and both cost a run of TLO reads
        sweepDefendReports()
        sweepAssistCalls()
    end

    -- before the gates below, and deliberately: a tank whose fight has just closed has something
    -- to say about it whether or not it is going to pick another one up
    callAssist()

    -- likewise outside the engaged gate: being beaten while fighting something else is exactly
    -- when the report matters
    callDefend()

    if Combat._.targetId > 0 then return end

    -- The person playing pressed attack -- the key, the client's own button, `/attack` -- and the
    -- client is swinging. That is an order like any other, given in the client's language instead
    -- of ours, so it is honored above the auto-engage gate: that switch decides whether to pick
    -- fights up unbidden, and this fight we were told about. The combat flag is asked as well as
    -- the toggle because the toggle alone is not intent -- autoattack survives a kill, and a
    -- leftover toggle plus a curious click on something far away must not order a charge; the
    -- swing, or the aggro, is when the fight is real. The `engageonattack` switch reads the press
    -- itself as the order instead: the moment the toggle turns on, the target under it is engaged
    -- with no wait for the swing or the aggro, so pressing attack at range is a charge. Only the
    -- turning-on reads that way -- the leftover toggle the combat flag exists to refuse still
    -- orders nothing. Read only while unengaged, so a target switched mid-fight does not move an
    -- engagement -- an order is never taken away automatically, by hand least of all.
    if (attackOn and mq.TLO.Me.CombatState() == "COMBAT")
        or (attackPressed and CombatConfig.GetEngageOnAttack()) then
        local id = tonumber(mq.TLO.Target.ID()) or 0
        if id > 0 then
            local spawn = mq.TLO.Spawn("id " .. tostring(id))
            if spawn.ID() ~= nil and not spawn.Dead() and fightableTypes[spawn.Type()] then
                Combat.Engage(id, "attacking by hand")
                return
            end
        end
    end

    if not CombatConfig.GetAutoEngage() then return end

    -- Travel mode is exactly the case for not picking a fight up. Nothing would act on it -- every
    -- state that fights is held back while flee is on -- but an engagement recorded now is one that
    -- resumes the moment the run ends, against whatever we ran past ten zones ago. Standing defend
    -- reports were already emptied at the top of this pulse, for the same reason.
    if Status.IsFleeing() then return end

    -- the ambient throttle is for watching an empty room; a fight seeking its successor reads
    -- the world every pulse (see fightLingerMs)
    if not Combat.IsSeeking() and now - Combat._.lastScanMs < scanIntervalMs then return end
    Combat._.lastScanMs = now

    -- The group's attackers before even the group's target, for the one character whose job is
    -- protecting it: a live defend report is a mob beating on somebody who cannot shed it, and
    -- the main tank picks it up the moment its hands are free -- never sooner. An engagement in
    -- progress is not switched off a report; the standing reports are the memory, and the
    -- fight's own end (the seek falling through to here every pulse) is when they are read,
    -- which is what keeps one pull's add the same fight. Deliberately above the CombatState
    -- gate below: the tank is precisely *not* in combat while the add is only on the healer,
    -- and the reporter already asked the combat-flag question on the client where the fact lives.
    if Roles.IsMainTank() then
        local defendId, reporter = oldestDefendReport()
        if defendId ~= nil then
            Combat.Engage(defendId, "it is attacking " .. (reporter or "the group"),
                Combat.sources.rescue)
            return
        end
    end

    -- The group's target before our own: what the main assist is fighting is what everyone else
    -- should be fighting, and a character that only ever answers what is hitting it is a character
    -- that fights six mobs one each. Self-defense is the fallback rather than the rule.
    local assistId = assistTargetId()
    if assistId ~= nil then
        local assist = Roles.GetMainAssist()
        Combat.Engage(assistId, "assisting " .. (assist ~= nil and assist.name or "the main assist"),
            Combat.sources.assist)
        return
    end

    -- only while the client says we are actually in a fight, so a mob that has us on its hate
    -- list from across the zone does not start one
    if mq.TLO.Me.CombatState() ~= "COMBAT" then return end

    local id = findAutoHater()
    if id ~= nil then
        Combat.Engage(id, "it attacked us", Combat.sources.hater)
    end
end

---@param stateMachine StateMachine
function Combat.Init(stateMachine)
    if Combat._.isInit then return end

    local ftkey = Global.tracing.open("Combat Setup")

    CombatConfig.Init()
    stateMachine:RegisterService(Combat)

    local attackDocs = ChelpDocs.new(function() return {
        "(attack <id>) Tells listener(s) to fight the spawn with <id>",
        " -- Usage: attack <spawn id>",
        " -- Usage (call it off): attack off",
        " -- What fighting means is up to the listener: a warrior gets on it and swings, a",
        "    wizard casts at it, and a character that does neither ignores it."
    } end )
    local function event_Attack(_, speaker, args)
        -- permission first: a speaker we take no orders from should cost us nothing, not even
        -- the complaints below
        if not Commands.GetCommandOwners(Combat.eventIds.attack):HasPermission(speaker) then
            DebugLog("Ignoring attack speaker [" .. speaker .. "]")
            return
        end

        args = StringUtils.Split(StringUtils.TrimFront(args or ""))

        -- these used to return silently, which is indistinguishable from a broken script when the
        -- order came from a hotbar button that was never given a target
        if #args < 1 then
            print("(attack) No target given. Usage: attack <spawn id>, or `attack off` to call it off.")
            return
        end

        if UserInput.IsFalse(args[1]:lower()) then
            Combat.Disengage("called off by " .. speaker)
            return
        end

        local targetId = tonumber(args[1])
        if targetId == nil then
            print("(attack) [" .. args[1] .. "] is not a spawn id. Usage: attack <spawn id>")
            return
        end

        if mq.TLO.SpawnCount("id " .. tostring(targetId) .. " radius 400 los")() < 1 then
            print("(attack) Nothing in range and in sight with id [" .. tostring(targetId) .. "]")
            return
        end

        -- Never a corpse: a dead mob keeps its spawn id, and the default here is ${Target.ID} --
        -- one press of an attack button on a body being looted would open a fight over nothing.
        local spawn = mq.TLO.Spawn("id " .. tostring(targetId))
        if spawn.Dead() or spawn.Type() == "Corpse" then
            print("(attack) [" .. tostring(targetId) .. "] is already dead")
            return
        end

        DebugLog("Attack ordered by [" .. speaker .. "] targetId: [" .. targetId .. "]")
        Combat.Engage(targetId, "ordered by " .. speaker)
    end
    Commands.RegisterCommEvent(Command.new(Combat.eventIds.attack, event_Attack, attackDocs)
        :WithArgs({
            required = true,
            hint = "a spawn id, or off",
            default = "${Target.ID}",
            choices = function() return {
                { label = "Whatever I have targeted", args = "${Target.ID}" },
                -- a button that calls the attack off should not be labelled "attack"
                { label = "Call off the attack", args = "off", name = "Back off" }
            } end
        }))

    local assistDocs = ChelpDocs.new(function() return {
        "(assist <id>) Calls listener(s) onto the target the group is fighting",
        " -- Usage: assist <spawn id>",
        " -- Usage (call the fight off): assist off",
        " -- Said automatically by whoever holds the group's Main Tank role, every time what they",
        "    are fighting changes -- see the (" .. Combat.eventIds.callAssist .. ") switch. Nothing else says it.",
        " -- Goes out on the group channel unless /speak says otherwise, so a tank that has never",
        "    configured a speak channel still leads the group.",
        " -- Heard, it engages exactly as (attack) does: a warrior gets on it and swings, a wizard",
        "    casts at it, and what each of them holds back for is still their own business.",
        " -- Ignored while flee is on, like every other way of picking a fight up during a run."
    } end )
    local function event_Assist(_, speaker, args)
        if not Commands.GetCommandOwners(Combat.eventIds.assist):HasPermission(speaker) then
            DebugLog("Ignoring assist speaker [" .. speaker .. "]")
            return
        end

        args = StringUtils.Split(StringUtils.TrimFront(args or ""))
        if #args < 1 then
            print("(assist) No target given. Usage: assist <spawn id>, or `assist off` to call the fight off.")
            return
        end

        if UserInput.IsFalse(args[1]:lower()) then
            -- the speaker taking their statement back, which is what makes the record a live fact
            -- rather than the last thing anybody happened to shout
            Combat._.assistCalls[speaker] = nil
            Combat.Disengage("called off by " .. speaker)
            return
        end

        local targetId = tonumber(args[1])
        if targetId == nil then
            print("(assist) [" .. args[1] .. "] is not a spawn id. Usage: assist <spawn id>")
            return
        end

        -- same reasoning as the auto-engage sweep: nothing would act on it during a run, and the
        -- engagement would come back the moment the run ended
        if Status.IsFleeing() then
            DebugLog("Ignoring assist from [" .. speaker .. "]: flee is on")
            return
        end

        -- No line of sight or radius check, unlike (attack). A call arrives the instant the tank
        -- engages, which is exactly when the rest of the group is still coming around the corner;
        -- refusing it there would drop the one call that mattered. Whether the thing is reachable
        -- is each state's own question, asked again every pass.
        local spawn = mq.TLO.Spawn("id " .. tostring(targetId))
        if spawn.ID() == nil then
            print("(assist) Nothing in the zone with id [" .. tostring(targetId) .. "]")
            return
        end
        if spawn.Dead() or spawn.Type() == "Corpse" then
            DebugLog("Ignoring assist on [" .. tostring(targetId) .. "]: it is already dead")
            return
        end

        -- Recorded whoever said it, and read back only for the character the group window names as
        -- the tank (see GetTankTargetId): a call is the one thing a client is ever told about what
        -- another character is fighting, and it is worth exactly as much when an `assistonengage`
        -- character says it as when the tank does -- the question is only ever who is speaking.
        Combat._.assistCalls[speaker] = targetId

        DebugLog("Assist called by [" .. speaker .. "] targetId: [" .. tostring(targetId) .. "]")
        Combat.Engage(targetId, "assist called by " .. speaker, Combat.sources.assist)
    end
    Commands.RegisterCommEvent(Command.new(Combat.eventIds.assist, event_Assist, assistDocs)
        :WithArgs({
            required = true,
            hint = "a spawn id, or off",
            default = "${Target.ID}",
            choices = function() return {
                { label = "Whatever I have targeted", args = "${Target.ID}" },
                { label = "Call the fight off", args = "off", name = "Stop" }
            } end
        }))

    local defendDocs = ChelpDocs.new(function() return {
        "(defend <id> [id ...]) Reports mobs attacking the speaker, for the main tank to pick up",
        " -- Usage: defend <spawn id> [spawn id ...]",
        " -- Said automatically by any character something is actually coming for (the top of its",
        "    hate list) that is not the main tank -- see the (" .. Combat.eventIds.callDefend .. ") switch.",
        " -- One line per mob, group-wide, for as long as it lives in this zone: every character",
        "    remembers the ids already called, its own and everyone else's, so a mob bouncing",
        "    between the tank and its victims is never re-announced. Its death, a zone, or a flee",
        "    clears its entry, and only then is it news again.",
        " -- Heard by the main tank with auto-engage on, a report stands until the mob is dead or",
        "    gone, and the longest-standing one is engaged the moment the tank is not already",
        "    fighting something. An engaged tank never switches targets off a report; it waits.",
        " -- Anyone in the listener's group may say it, owner or not -- defense of the group is",
        "    the group's to ask for. Speakers outside the group still need the owner list.",
        " -- Said by hand it is a request to peel: `defend ${Target.ID}` on a hotbar button asks",
        "    the tank to come take your target off you.",
        " -- Goes out over bc unless /speak defend says otherwise.",
        " -- Ignored while flee is on, and a run drops every standing report with it."
    } end )
    local function event_Defend(_, speaker, args)
        -- The usual ACL, widened by the one fact the owner list cannot know in advance: the
        -- group. Reports are machine-spoken by whichever characters happen to be grouped with
        -- the tank, and a group assembled fresh would otherwise need every member added to the
        -- tank's owner list before the tank would defend any of them. The invitation is the
        -- trust that matters here; a stranger shouting ids from outside the group still costs
        -- nothing.
        if not Commands.GetCommandOwners(Combat.eventIds.defend):HasPermission(speaker)
            and mq.TLO.Group.Member(speaker).ID() == nil then
            DebugLog("Ignoring defend speaker [" .. speaker .. "]")
            return
        end

        args = StringUtils.Split(StringUtils.TrimFront(args or ""))
        if #args < 1 then
            print("(defend) No mob given. Usage: defend <spawn id> [spawn id ...]")
            return
        end

        -- same reasoning as (assist): nothing would act on it during a run, and a standing
        -- entry would charge the tank back at whatever we ran from the moment the run ends
        if Status.IsFleeing() then
            DebugLog("Ignoring defend from [" .. speaker .. "]: flee is on")
            return
        end

        -- A standing entry lives until the world takes it back, and the pulse's own sweep is
        -- what takes it: recording is just recording.
        local now = Time.current_time()
        local recorded = false
        for _, arg in ipairs(args) do
            local id = tonumber(arg)
            if id ~= nil and id > 0 then
                recorded = true
                local known = Combat._.defendReports[id]
                Combat._.defendReports[id] = {
                    reporter = speaker,
                    -- the first report's time is kept across re-reports: longest-standing is
                    -- who the pickup answers first
                    firstMs = known ~= nil and known.firstMs or now
                }
            end
        end

        if not recorded then
            print("(defend) [" .. args[1] .. "] is not a spawn id. Usage: defend <spawn id> [spawn id ...]")
            return
        end
        DebugLog("Defend reported by [" .. speaker .. "]: " .. StringUtils.Join(args, " "))
    end
    Commands.RegisterCommEvent(Command.new(Combat.eventIds.defend, event_Defend, defendDocs)
        :WithArgs({
            required = true,
            hint = "one or more spawn ids",
            default = "${Target.ID}",
            choices = function() return {
                { label = "Peel whatever I have targeted", args = "${Target.ID}" }
            } end
        }))

    ToggleCommand.Register({
        key = Combat.key,
        phrase = Combat.eventIds.autoEngage,
        summary = "Turns engaging without being told on or off",
        about = {
            "On, the main assist's target is taken first, and whatever is attacking us after that.",
            "Off waits to be told what to fight: (attack <id>), an (assist) call, the Attack button,",
            "or your own attack key -- a fight started by hand is an order like any other."
        },
        get = CombatConfig.GetAutoEngage,
        set = CombatConfig.SetAutoEngage
    })

    ToggleCommand.Register({
        key = Combat.key,
        phrase = Combat.eventIds.callAssist,
        summary = "Turns calling the assist out to the group on or off",
        about = {
            "Only says anything while this character holds the group's Main Tank role.",
            "It goes out on the group channel unless /speak assist says otherwise."
        },
        get = CombatConfig.GetCallAssist,
        set = CombatConfig.SetCallAssist
    })

    ToggleCommand.Register({
        key = Combat.key,
        phrase = Combat.eventIds.callDefend,
        summary = "Turns calling out mobs this character cannot shed on or off",
        about = {
            "On, anything actually coming for this character (the top of its hate list) that",
            "nobody has yet called out is reported as (defend <id>), and the main tank engages",
            "the report the moment it is not already fighting something. One line per mob,",
            "group-wide, for as long as it lives in this zone -- its death, a zone, or a flee",
            "clears its entry, and only then is it news again. The fight the group was already",
            "put on is not reported, and the main tank itself never reports -- its own",
            "attackers are its own hater sweep's business.",
            "It goes out over bc unless /speak defend says otherwise."
        },
        get = CombatConfig.GetCallDefend,
        set = CombatConfig.SetCallDefend
    })

    ToggleCommand.Register({
        key = Combat.key,
        phrase = Combat.eventIds.easeOff,
        summary = "Turns easing off a mob pulled off the main tank on or off",
        about = {
            "On, a character that is not the group's main tank stops hurting the thing it is",
            "fighting for as long as that thing is coming for it and the tank should have it:",
            "the swing drops, the melee ability, taunt and hate lists hold, and the spell",
            "rotation holds everything aimed at the mob (a damage shield on somebody still goes",
            "up). Damage resumes the moment the tank is back on top of its hate list.",
            "Nothing is eased off for a group that has named no main tank, or for a mob the tank",
            "is on something else instead of -- that one is ours, and (defend) is what is said",
            "about it."
        },
        get = CombatConfig.GetEaseOff,
        set = CombatConfig.SetEaseOff
    })

    ToggleCommand.Register({
        key = Combat.key,
        phrase = Combat.eventIds.engageOnAttack,
        summary = "Turns starting the cabby fight the moment your attack turns on, on or off",
        about = {
            "On, the instant your attack toggles on -- the key, the client's button, /attack --",
            "whatever you have targeted is engaged as an order, with no wait for the swing or the",
            "aggro that normally confirms a hand-started fight: pressing attack at range is a",
            "charge. Only the press orders anything -- a toggle left on from the last fight stays",
            "just a toggle. Off, a hand-started fight is still honored once real combat begins."
        },
        get = CombatConfig.GetEngageOnAttack,
        set = CombatConfig.SetEngageOnAttack
    })

    ToggleCommand.Register({
        key = Combat.key,
        phrase = Combat.eventIds.assistOnEngage,
        summary = "Turns calling this character's own fights out as (assist) lines on or off",
        about = {
            "Every fight this character picks up is announced the way the main tank's is --",
            "(" .. Combat.eventIds.assist .. " <id>) on engaging, (" .. Combat.eventIds.assist .. " off) on dropping it -- with no role required.",
            "For leading the group from whichever character the player is actually driving.",
            "It goes out on the group channel unless /speak assist says otherwise."
        },
        get = CombatConfig.GetAssistOnEngage,
        set = CombatConfig.SetAssistOnEngage
    })

    ToggleCommand.Register({
        key = Combat.key,
        phrase = Combat.eventIds.disengageOnAttackOff,
        summary = "Turns calling the fight off when your attack switches off, on or off",
        about = {
            "On, switching your auto attack off -- the key, the client's button, /attack off --",
            "closes the cabby fight the way the Back Off button does, seek and all. Only the",
            "switch-off itself orders anything, and one that was taken from you rather than",
            "chosen -- a mez, a charm or a stun dropping auto attack -- orders nothing. Neither",
            "does cabby's own bookkeeping: melee holding the swing off out of melee range.",
            "Ignored while flee is on: travel drops auto attack itself, as bookkeeping."
        },
        get = CombatConfig.GetDisengageOnAttackOff,
        set = CombatConfig.SetDisengageOnAttackOff
    })

    ToggleCommand.Register({
        key = Combat.key,
        phrase = Combat.eventIds.disengageOnTargetClear,
        summary = "Turns calling the fight off when you clear its target, on or off",
        about = {
            "On, clearing your target -- ESC -- while it sits on the mob the fight is on closes",
            "the cabby fight the way the Back Off button does. Clearing anything else (a group",
            "member a heal landed on, a mob you were only inspecting) orders nothing, and the",
            "world taking the target -- the mob dying, the corpse poofing -- is not a clear.",
            "Ignored while flee is on."
        },
        get = CombatConfig.GetDisengageOnTargetClear,
        set = CombatConfig.SetDisengageOnTargetClear
    })

    local cattackDocs = ChelpDocs.new(function() return {
        "(/cattack) Report what this character is fighting",
        " -- Usage: /cattack",
        " -- Usage (call it off): /cattack off"
    } end )
    local function Bind_CAttack(...)
        local args = {...} or {}

        if #args > 0 and args[1]:lower() == "help" then
            cattackDocs:Print()
            return
        end

        if #args > 0 and UserInput.IsFalse(args[1]) then
            Combat.Disengage("called off by /cattack")
            print("Attack called off")
            return
        end

        print("Combat: " .. Combat.Describe())
        print(" -- auto-engage: " .. (CombatConfig.GetAutoEngage() and "on" or "off"))
        print(" -- engage on attack: " .. (CombatConfig.GetEngageOnAttack() and "on" or "off"))
        print(" -- disengage on attack off: " .. (CombatConfig.GetDisengageOnAttackOff() and "on" or "off"))
        print(" -- disengage on target clear: " .. (CombatConfig.GetDisengageOnTargetClear() and "on" or "off"))
        print(" -- roles: " .. Roles.Describe())

        local assistTarget = Roles.GetAssistTarget()
        if Roles.IsMainAssist() then
            print(" -- I am the main assist, so the assist target is not something to follow")
        else
            print(" -- the assist is on: " ..
                (assistTarget ~= nil and (assistTarget.name .. " (id " .. tostring(assistTarget.id) .. ")") or "nothing"))
        end

        -- What the tank is on is a different question from what the assist is on, and it is the one
        -- a pet's taunt is decided by
        local tankOn = Combat.GetTankTargetId()
        if Roles.GetMainTank() == nil then
            print(" -- the group has named no main tank")
        elseif tankOn ~= nil then
            local name = mq.TLO.Spawn("id " .. tostring(tankOn)).CleanName()
            print(" -- the main tank is on: " .. (name or ("spawn " .. tostring(tankOn))) ..
                " (id " .. tostring(tankOn) .. ")")
        else
            print(" -- the main tank is on: nothing this client can see -- it has called no assist," ..
                " and it does not hold the assist role either")
        end

        local tankCalls = CombatConfig.GetCallAssist() and Roles.IsMainTank()
        if tankCalls or CombatConfig.GetAssistOnEngage() then
            -- both on is still one mouth; the role is the wider job, so its wording wins
            local why = tankCalls and "as the main tank" or "for this character's own fights (assistonengage)"
            local speak, isFallback = assistSpeak()
            print(" -- calling the assist: on, " .. why .. ", spoken on [" ..
                StringUtils.Join(speak:GetActiveSpeakChannels(), ", ") .. "]" ..
                (isFallback and " -- the default, since nothing is set; /speak assist <channel> to change it" or ""))
        elseif not CombatConfig.GetCallAssist() then
            print(" -- calling the assist: off")
        else
            print(" -- calling the assist: on, but only the main tank calls it and that is not me")
        end

        -- the standing answer as well as the switch: "on" alone says nothing about whether this
        -- character is easing off right now, which is the thing somebody watching a fight asks
        local easeOff, easeWhy = Combat.ShouldEaseOff()
        print(" -- easing off what we pull off the tank (easeoff): " ..
            (CombatConfig.GetEaseOff() and "on" or "off") ..
            (easeOff and (" -- easing off now: " .. tostring(easeWhy)) or ""))

        -- the same table is the tank's radar and everyone else's record of what has been called
        print(" -- calling for defense (calldefend): " .. (CombatConfig.GetCallDefend() and "on" or "off"))
        local standing = 0
        for id, report in pairs(Combat._.defendReports) do
            standing = standing + 1
            local name = mq.TLO.Spawn("id " .. tostring(id)).CleanName()
            print(" -- defend report: " .. (name or ("spawn " .. tostring(id))) ..
                " (id " .. tostring(id) .. "), called by " .. report.reporter)
        end
        if standing == 0 then
            print(" -- defend reports: none standing")
        end
        -- the one setting that makes this whole report a lie about what will happen next: an
        -- engagement is still recorded while fleeing, and nothing whatsoever acts on it
        if Status.IsFleeing() then
            print(" -- flee is on: nothing will act on this until `flee off`")
        end
    end
    Commands.RegisterSlashCommand(SlashCmd.new("cattack", Bind_CAttack, cattackDocs))

    Combat._.isInit = true
    Global.tracing.close(ftkey)
end

return Combat
