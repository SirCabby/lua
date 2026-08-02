---How much of a fight something is, in the one measure the client will actually hand over: the
---colour it cons.
---
---A level on its own says nothing -- fifty is a joke to a sixty-five and a wall to a forty-five --
---and the con colour is the game answering *relative to me, how much trouble is this*, which is
---exactly the question behind spending a four second cast, an item on a long timer or a damage
---shield's mana on a fight rather than keeping it for the next one. So it is a ladder, weakest to
---toughest, and what a setting made of it says is the rung at which something becomes worth doing.
---
---**A floor, never a window.** Effort is a thing you spend more of as fights get harder, so what a
---slot carries is "at least this much of a fight" and everything above it is included. Nobody wants
---a nuke that fires on blues and stops on reds.
---
---Published as its own service rather than living inside the state that wanted it first, because
---the question is the same wherever it comes up: the grey mob not worth a damage shield is not
---worth a discipline, a mez or a summoned pet either, and every one of those should be reading the
---same ladder rather than growing its own spelling of "light blue".
---
---**It decides nothing.** No frames, no commands, no config of its own -- it reads a spawn and
---answers, which also makes it safe to call from an ImGui callback.
---@class Cons
local Cons = {}

---Weakest first. The order *is* the meaning here, so it is an array and the ranks are derived from
---it rather than written down twice.
---
---`reported` is what `Spawn.ConColor` says, which is the game's spelling and not ours: it is listed
---rather than upper-cased out of `display`, so that renaming what a user reads can never quietly
---stop matching what the client says.
Cons.ladder = {
    { value = "grey",      display = "Grey",       reported = "GREY" },
    { value = "green",     display = "Green",      reported = "GREEN" },
    { value = "lightblue", display = "Light blue", reported = "LIGHT BLUE" },
    { value = "blue",      display = "Blue",       reported = "BLUE" },
    { value = "white",     display = "White",      reported = "WHITE" },
    { value = "yellow",    display = "Yellow",     reported = "YELLOW" },
    { value = "red",       display = "Red",        reported = "RED" }
}

local rankOfValue = {}
local rankOfReported = {}
for rank, con in ipairs(Cons.ladder) do
    con.rank = rank
    rankOfValue[con.value] = rank
    rankOfReported[con.reported] = rank
end

---The bottom rung, which is what "anything at all" means: there is nothing weaker than grey, so a
---floor set there is every fight there is.
Cons.any = Cons.ladder[1].value

---The top rung, which is the one with nothing above it.
Cons.toughest = Cons.ladder[#Cons.ladder].value

---@param con string|nil
---@return string con one of `Cons.ladder`'s values; the bottom rung for anything unrecognised,
---which is what an unset field and a config edited by hand both come through as
function Cons.Sanitize(con)
    return rankOfValue[con] ~= nil and con or Cons.any
end

---What a rung reads as when it is being used as a floor.
---
---The bottom rung is every fight there is and says so rather than naming a colour nobody was
---thinking about. The top has nothing above it, so "and up" would be a promise about mobs that do
---not exist.
---@param con string
---@return string display
function Cons.ThresholdDisplay(con)
    con = Cons.Sanitize(con)
    if con == Cons.any then return "Any con" end
    for _, known in ipairs(Cons.ladder) do
        if known.value == con then
            return known.value == Cons.toughest and (known.display .. " only") or (known.display .. "+")
        end
    end
    return "Any con"
end

---Is this spawn at least this much of a fight?
---
---A floor at the bottom rung is the answer to everything and is given without reading the world at
---all: that is what leaves a slot nobody has set behaving exactly as it did before, and what keeps
---this off the hot path for every rotation that never asked the question.
---
---**An unreadable con is not "tough enough".** A spawn the client will not answer for is one we
---know nothing about, and the whole point of a floor is holding the expensive thing back until we
---do -- the same reading the dps rotation gives an unreadable health.
---@param spawn any mq spawn TLO for the mob being judged
---@param con string the floor, one of `Cons.ladder`'s values
---@return boolean meets
function Cons.Meets(spawn, con)
    local floor = rankOfValue[con]
    if floor == nil or floor <= 1 then return true end
    if spawn == nil then return false end

    local rank = rankOfReported[tostring(spawn.ConColor())]
    return rank ~= nil and rank >= floor
end

return Cons
