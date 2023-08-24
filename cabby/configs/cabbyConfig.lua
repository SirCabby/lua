---@diagnostic disable: duplicate-set-field

local ImGui = require("ImGui")

---@class CabbyConfig
local CabbyConfig = { key = "CabbyConfig" }

---@param config Config
function CabbyConfig.Init(config) end

function CabbyConfig.BuildMenu()
    ImGui.Text("No menu exists yet for this page")
end
