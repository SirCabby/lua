---@diagnostic disable: duplicate-set-field

local ImGui = require("ImGui")

---@class CabbyConfig
local CabbyConfig = { key = "CabbyConfig" }

function CabbyConfig.Init() end

function CabbyConfig.BuildMenu()
    ImGui.Text("No menu exists yet for this page")
end
