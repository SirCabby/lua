local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local Geometry = require("utils.Movement.Geometry")
local Time = require("utils.Time.Time")

---Low level locomotion primitives: the single owner of the movement keys.
---
---Nothing else in a script should press movement keys -- routing every hold/release through
---here is what keeps two behaviors from fighting over the same key.
---
---Hold/Release record *desired* key state and send nothing. `Apply()` reconciles desired
---against what we have actually told the client (`/keypress <key> hold` presses and holds,
---a plain `/keypress <key>` releases), so a key command is only ever emitted on transition.
---
---**Apply() must only be called from the host's main loop**, which in practice means only
---from `Movement.Pulse()`. Driving EQ's mappable commands from inside an ImGui render
---callback -- a menu button that stops movement, say -- executes them in the middle of the
---client's frame, and MQ2MoveUtils flagged that as a crash-to-desktop hazard in its own
---source. Splitting desired state from application is what makes it safe for a button, a
---chat event handler or a state to ask for movement from wherever they happen to run.
---@class Locomotion
local Locomotion = {
    author = "judged",
    key = "Locomotion",
    ---How many pulses ahead a task must aim when it decides to stop against a threshold.
    ---
    ---A key released this pulse actually lets go noticeably later: the release is emitted at the
    ---end of the pulse, behind that pulse's own command yields, and the client acts on it a frame
    ---after that -- a full pulse of actuation lag, and the next pulse gap is never quite the last
    ---one. So a task steering by a distance it read this pulse is steering by where it *was*, and
    ---testing "am I there" against the raw read stops a full pulse of travel too late, every time.
    ---The cure is to test the threshold against where we will be when the release lands: raw
    ---distance minus how fast the gap closed last pulse, times this. Erring long means stopping
    ---short, which costs one more creeping pulse; erring short means running past the mark,
    ---flipping around to re-face it, and a stuck detector staring at the oscillation -- so this
    ---leans past a full pulse.
    leadPulses = 1.5,
    ---A gap that changed by more than this in one pulse was not closed by running, it was a
    ---teleport -- ours or theirs -- and is not a speed to aim stops with.
    closingClamp = 30,
    ---EQ mappable command names, keyed by direction
    keys = {
        forward = "forward",
        backward = "back",
        strafeLeft = "strafe_left",
        strafeRight = "strafe_right"
    },
    _ = {
        desired = {},
        applied = {},
        lastStandMs = 0
    }
}

local opposites = {
    forward = "back",
    back = "forward",
    strafe_left = "strafe_right",
    strafe_right = "strafe_left"
}

local standRetryMs = 1000

---@param str string
local function DebugLog(str)
    Debug.Log(Locomotion.key, str)
end

---Ask to hold a movement key down, releasing its opposite first. Takes effect on Apply().
---@param key string one of Locomotion.keys
function Locomotion.Hold(key)
    local opposite = opposites[key]
    if opposite ~= nil then
        Locomotion.Release(opposite)
    end
    Locomotion._.desired[key] = true
end

---Ask to release a movement key. Takes effect on Apply().
---@param key string one of Locomotion.keys
function Locomotion.Release(key)
    Locomotion._.desired[key] = false
end

---Send the key commands needed to make the client match what was asked for.
---**Main loop only** -- see the note on this module.
function Locomotion.Apply()
    for _, key in pairs(Locomotion.keys) do
        local desired = Locomotion._.desired[key] == true
        if desired ~= (Locomotion._.applied[key] == true) then
            if desired then
                DebugLog("Holding movement key [" .. key .. "]")
                mq.cmd("/keypress " .. key .. " hold")
            else
                DebugLog("Releasing movement key [" .. key .. "]")
                mq.cmd("/keypress " .. key)
            end
            Locomotion._.applied[key] = desired
        end
    end
end

function Locomotion.ReleaseForwardBack()
    Locomotion.Release(Locomotion.keys.forward)
    Locomotion.Release(Locomotion.keys.backward)
end

function Locomotion.ReleaseStrafe()
    Locomotion.Release(Locomotion.keys.strafeLeft)
    Locomotion.Release(Locomotion.keys.strafeRight)
end

function Locomotion.ReleaseAll()
    for _, key in pairs(Locomotion.keys) do
        Locomotion.Release(key)
    end
end

---Release every movement key even if we do not believe we are holding it, and send it now.
---Used on startup, where another script (or a previous run of this one) may have left a key
---down. Main loop only, same as Apply().
function Locomotion.ForceReleaseAll()
    for _, key in pairs(Locomotion.keys) do
        Locomotion._.desired[key] = false
        Locomotion._.applied[key] = true
    end
    Locomotion.Apply()
end

---@param key string one of Locomotion.keys
---@return boolean isHeld whether we are asking for this key, which may be a frame ahead of the client
function Locomotion.IsHeld(key)
    return Locomotion._.desired[key] == true
end

---@return boolean isMoving true while this module is asking for any movement key
function Locomotion.IsMoving()
    for _, key in pairs(Locomotion.keys) do
        if Locomotion._.desired[key] then return true end
    end
    return false
end

---Snap our heading toward a location. `fast` sets the heading outright instead of turning
---over several frames. On land the camera pitch is left alone; given a `z` while swimming it
---is aimed too, because swimming goes where the camera looks -- a follower that never noses
---down cannot follow anyone down.
---@param y number
---@param x number
---@param z? number aim the pitch as well when swimming
function Locomotion.FaceLoc(y, x, z)
    if z ~= nil and mq.TLO.Me.FeetWet() then
        mq.cmdf("/face fast loc %.2f,%.2f,%.2f", y, x, z)
        return
    end
    mq.cmdf("/face fast nolook loc %.2f,%.2f", y, x)
end

---@return number heading current heading in degrees counter-clockwise
function Locomotion.GetHeading()
    return mq.TLO.Me.Heading.DegreesCCW() or 0
end

---@param y number
---@param x number
---@return number heading we would need to travel to reach the location, degrees counter-clockwise
function Locomotion.GetHeadingToLoc(y, x)
    return Geometry.HeadingTo(mq.TLO.Me.Y() or 0, mq.TLO.Me.X() or 0, y, x)
end

function Locomotion.Jump()
    mq.cmd("/keypress jump")
end

---@return boolean isRooted
function Locomotion.IsRooted()
    return mq.TLO.Me.Rooted() ~= nil
end

---@return boolean canJump false while levitating or swimming, where jumping does nothing useful
function Locomotion.CanJump()
    return not mq.TLO.Me.Levitating() and not mq.TLO.Me.FeetWet()
end

---Stand up when sitting or ducking. Throttled, since the stand does not take effect until
---the server answers and we do not want to spam it every frame.
---@return boolean isStanding true when we are already in a state that can move
function Locomotion.StandIfNeeded()
    local state = mq.TLO.Me.State()
    if state ~= "SIT" and state ~= "DUCK" then
        return state == "STAND" or state == "HOVER" or state == "MOUNT"
    end

    local now = Time.current_time()
    if now - Locomotion._.lastStandMs >= standRetryMs then
        Locomotion._.lastStandMs = now
        DebugLog("Standing up from state [" .. tostring(state) .. "]")
        mq.cmd("/stand")
    end
    return false
end

return Locomotion
