---@diagnostic disable: duplicate-set-field

local ImGui = require("ImGui")

---@class BaseConfig
local BaseConfig = { key = "BaseConfig" }

function BaseConfig.Init() end

function BaseConfig.BuildMenu()
    ImGui.Text("No menu exists yet for this page")
end
