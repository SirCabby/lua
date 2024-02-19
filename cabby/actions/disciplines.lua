local mq = require("mq")

local Discipline = require("cabby.actions.discipline")

---@class Disciplines
local Disciplines = {
    all = {},
    hate = {},      -- Increases player's hate towards target
    melee = {},     -- Actions to perform while in melee combat
    taunt = {}      -- Moves to top of hatelist
}

---@param name string
---@return Discipline discipline
Disciplines.Get = function(name)
    name = name:lower()
    for _, discipline in ipairs(Disciplines.all) do
        ---@type Discipline
        discipline = discipline

        if discipline:Name():lower() == name then
            return discipline
        end
---@diagnostic disable-next-line: missing-return
    end
end

-- Read Disciplines
Disciplines.Refresh = function()
    Disciplines.all = {}
    Disciplines.hate = {}
    Disciplines.melee = {}
    Disciplines.taunt = {}

    for i = 1, 200 do
        local disc = mq.TLO.Me.CombatAbility(i)
        if disc.Name() == nil then break end

        Disciplines.all[#Disciplines.all+1] = Discipline.new(disc.Name())

        if disc.HasSPA(92)() or disc.HasSPA(192)() then
            Disciplines.taunt[#Disciplines.taunt+1] = Discipline.new(disc.Name())
        elseif disc.TargetType() == "Single" then
            Disciplines.melee[#Disciplines.melee+1] = Discipline.new(disc.Name())
        end

        print(disc.Name())
        -- print(disc.CategoryID())
        -- print(disc.SubcategoryID())
        -- print(" -- " .. disc.EnduranceCost())
        -- print(" -- " .. disc.TargetType())
        -- print(" -- " .. disc.SpellType())
        -- print(" -- " .. disc.Duration.TotalSeconds())
        -- print(" -- " .. disc.RecastTime()) --ms
    end
end
Disciplines.Refresh() -- Init

return Disciplines
