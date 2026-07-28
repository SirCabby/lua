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
---from nowhere else, for the same reason.
---@class Combat
local Combat = {
    key = "Combat",
    eventIds = {
        assist = "assist",
        assistOnEngage = "assistonengage",
        attack = "attack",
        autoEngage = "autoengage",
        callAssist = "callassist",
        disengageOnAttackOff = "disengageonattackoff",
        disengageOnTargetClear = "disengageontargetclear",
        engageOnAttack = "engageonattack"
    },
    ---How an engagement was decided, which is what says whether something weaker may replace it.
    ---An `order` is somebody's explicit choice and is never taken away automatically; the other
    ---two are this character working it out for itself.
    sources = {
        order = "order",
        assist = "assist",
        hater = "hater"
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
        lastUnderAttackMs = 0,
        attackWasOn = false,
        clientTargetWasId = 0
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

---@return Speak speak where the assist call goes
---@return boolean isFallback whether nothing was configured and the default above is answering
local function assistSpeak()
    local speak = Commands.GetCommandSpeak(Combat.eventIds.assist)
    if #speak:GetActiveSpeakChannels() > 0 then return speak, false end
    ---@diagnostic disable-next-line: return-type-mismatch
    return fallbackAssistSpeak, true
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

---Something out there is fighting *us* -- we are at the top of an auto-hater's hate list, the one
---it is actually coming for -- whether or not we have decided to fight it back. Independent of the
---engagement on purpose: engaged-but-not-under-attack is us beating on something that has not
---turned around yet, and under-attack-but-not-engaged is a beating nobody agreed to, which is
---exactly the case auto-engage off creates. Answers from the last scan; Pulse keeps it fresh.
---@return boolean isUnderAttack
function Combat.IsUnderAttack()
    return Combat._.underAttack
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

---Whether anything with us on its hate list hates us *most*: `PctAggro` at 100 is the client's
---aggro meter saying "you are the one it is coming for". Most-hated rather than merely listed,
---and it matters -- a healer rides every fight's hate list off the heals alone, and a fact that
---read "listed" would keep it on its feet through fights it is medding through on purpose. Gated
---on the client's own combat flag for the same reason the auto-engage sweep is: a mob that hates
---us from across the zone is not fighting us yet.
---@return boolean isUnderAttack
local function scanUnderAttack()
    if mq.TLO.Me.CombatState() ~= "COMBAT" then return false end

    for slot = 1, 20 do
        local xtarget = mq.TLO.Me.XTarget(slot)
        if xtarget.TargetType() == "Auto Hater" and (tonumber(xtarget.PctAggro()) or 0) >= 100 then
            return true
        end
    end
    return false
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

---Service contract: keep the engagement honest -- including the fight's continuity across a
---target dying -- say what we are on if the group looks to us for that, and pick one up when
---there is something to pick up.
function Combat.Pulse()
    local now = Time.current_time()

    -- The attack toggle and the client's target are watched every pulse without exception --
    -- engaged, dead, mid-seek -- so that the "it just changed" answers below can never fire late
    -- off a stale reading: a press seen while engaged is an edge consumed, not one saved up to
    -- charge something after the fight closes. Our own melee state turning the swing on only
    -- ever does it while engaged, which is how its edges die here too.
    local attackOn = mq.TLO.Me.Combat() == true
    local attackPressed = attackOn and not Combat._.attackWasOn
    local attackReleased = not attackOn and Combat._.attackWasOn
    Combat._.attackWasOn = attackOn

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
        -- dead is not under attack; the fact starts over with the respawn
        Combat._.underAttack = false
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
        Combat._.underAttack = scanUnderAttack()
    end

    -- before the gates below, and deliberately: a tank whose fight has just closed has something
    -- to say about it whether or not it is going to pick another one up
    callAssist()

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
    -- resumes the moment the run ends, against whatever we ran past ten zones ago
    if Status.IsFleeing() then return end

    -- the ambient throttle is for watching an empty room; a fight seeking its successor reads
    -- the world every pulse (see fightLingerMs)
    if not Combat.IsSeeking() and now - Combat._.lastScanMs < scanIntervalMs then return end
    Combat._.lastScanMs = now

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
            "chosen -- a mez, a charm or a stun dropping auto attack -- orders nothing.",
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
