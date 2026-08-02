local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local StringUtils = require("utils.StringUtils.StringUtils")
local Time = require("utils.Time.Time")

local GeneralConfig = require("cabby.configs.generalConfig")

---Letting the people we are already with drag our corpse, said the moment we die.
---
---Consent is the one thing the server checks before it will let anybody but us summon our corpse
---(`Corpse::Summon` in `zone/corpse.cpp` -- the same `/corpse` that `states/corpseState.lua` uses
---to pull its own over). A corpse carries three ids that can grant it, and `/consent group`,
---`raid` and `guild` stamp the id we hold *right now* onto every corpse of ours the server can
---find (`Client::ConsentCorpses` -> world -> every zone). That makes this a thing to say **after**
---the corpse exists rather than before: a consent given while alive names corpses we do not have
---yet, and stamps nothing on the one we are about to leave.
---
---**It starts on the first frame we read as dead**, which is a frame with a corpse: the corpse is
---made in the same server tick that tells the client it died (`Client::Death`), and our answer has
---to travel back to the server, so it arrives behind it. That is also the last comfortable moment
---to say it -- the consent has to *find* the corpse in a loaded zone, and releasing to a bind point
---is what can leave the zone we died in with nobody left in it.
---
---**One consent every two and a half seconds.** The server allows one every two
---(`consent_throttle_timer`) and answers a faster one with a red "You must wait 2 seconds between
---consents." and nothing else: the consent is simply lost, and nothing in the world reads back as
---"that one did not take". The pacing is kept across deaths rather than per death, because the
---throttle it is dodging is.
---
---**Only the ties we actually have.** Group and raid consent stamp the id we are in, so consenting
---a group we are not in writes a zero -- which is what no consent already is. Reading first says
---the same nothing without spending one of those two-second slots on it.
---
---What it holds is the one thing the world cannot answer: whether this death has been consented
---yet. A corpse does not read back as "we already said this", and saying it twice costs a slot the
---ties still waiting are entitled to.
---@class Consent
local Consent = {
    key = "Consent",
    _ = {
        isInit = false,
        wasDead = false,
        ---what this death still owes, in the order it goes out; nil when nothing is owed
        owed = nil,
        lastSentMs = 0
    }
}

---How long between consents; see above for the two seconds this is half a second clear of.
local consentPaceMs = 2500

---@param str string
local function DebugLog(str)
    Debug.Log(Consent.key, str)
end

---Whether the client is dead. HOVER is dead and not yet released; DEAD is the beat before it, and
---the two are one death rather than two -- which is why the edge below is the only thing read.
---@return boolean isDead
local function isDead()
    local state = tostring(mq.TLO.Me.State() or "")
    return state == "DEAD" or state == "HOVER"
end

---The consents this death is worth giving, in the order they go out.
---
---Group and raid first: both are stamped on the corpse where it lies, so both want the zone we died
---in still loaded, and a release to the bind point is what starts emptying it. Guild last because
---it is the one that does not need the corpse found at all -- consenting a guild also writes the id
---onto every corpse of ours in the database (`UpdateCharacterCorpseConsent`), buried ones included.
---@return table owed
local function owedConsents()
    local owed = {}

    if mq.TLO.Me.Grouped() == true then owed[#owed+1] = "group" end
    if (tonumber(mq.TLO.Raid.Members()) or 0) > 0 then owed[#owed+1] = "raid" end

    -- `GuildID` rather than `Guild`: the name is a lookup in the guild list the client has been
    -- sent, and a name it cannot resolve reads exactly like having no guild at all. Both of the
    -- "no guild" values are checked, which is what MQ's own spawn reader does with the same field.
    local guildId = tonumber(mq.TLO.Me.GuildID()) or 0
    if guildId > 0 and guildId < 0xFFFFFFFF then owed[#owed+1] = "guild" end

    return owed
end

---Service contract: watch for our own death, then pay what it owes, one consent per slot.
function Consent.Pulse()
    local dead = isDead()
    local wasDead = Consent._.wasDead
    Consent._.wasDead = dead

    if dead and not wasDead and GeneralConfig.GetConsentOnDeath() then
        local owed = owedConsents()
        if #owed > 0 then
            Consent._.owed = owed
            -- Said out loud once, in our own console, because all of this happens while the player
            -- is looking at a respawn window: a character that consented and a character whose
            -- setting is off look exactly the same from there.
            print("(" .. GeneralConfig.eventIds.consentOnDeath .. ") Consenting " ..
                StringUtils.Join(owed, ", ") .. " to drag my corpse")
        else
            DebugLog("Died with no group, raid or guild to consent")
        end
    end

    local owed = Consent._.owed
    if owed == nil then return end

    -- Turning the setting off is an order to stop now, not one that takes effect next death.
    if not GeneralConfig.GetConsentOnDeath() then
        DebugLog("Dropping what this death still owed: the setting was turned off")
        Consent._.owed = nil
        return
    end

    -- Nothing goes out while the world is being taken down and put back up. A command typed into a
    -- loading screen is a command nobody hears, and the release to a bind point that lands in the
    -- middle of this is the very thing it has to survive.
    local gameState = mq.TLO.EverQuest.GameState()
    if gameState ~= nil and gameState ~= "INGAME" then return end

    local now = Time.current_time()
    if now - Consent._.lastSentMs < consentPaceMs then return end
    Consent._.lastSentMs = now

    local who = table.remove(owed, 1)
    if #owed < 1 then Consent._.owed = nil end

    DebugLog("Consenting " .. who)
    mq.cmd("/consent " .. who)
end

---@param stateMachine StateMachine
function Consent.Init(stateMachine)
    if Consent._.isInit then return end

    local ftkey = Global.tracing.open("Consent Setup")

    stateMachine:RegisterService(Consent)

    -- Whatever the client was doing when this came up is where the watching starts from, not
    -- something that just happened: a script restarted next to a corpse it never saw made has no
    -- way of knowing that corpse was not consented the first time round, and acting on a death
    -- nobody observed is acting for a reason we do not have.
    Consent._.wasDead = isDead()

    Consent._.isInit = true
    Global.tracing.close(ftkey)
end

return Consent
