local mq = require("mq")
local ImGui = require "ImGui"

---@class Menu
local Menu = {
    key = "Menu",
    _ = {
        isInit = false,
        registrations = {
            configs = {},
            comms = {},
            slashcmds = {},
            events = {},
            states = {}
        }
    }
}

local function NotSelected()
    ImGui.Text("Make a selection to display settings")
end

local function PageDne()
    ImGui.Text("Settings page does not yet exist for this selection")
end

Menu.Init = function()
    if not Menu._.isInit then
        local selectedIndex = 0
        mq.imgui.init("Cabby Menu", function()
            ImGui.Begin("Cabby Menu")
                local indexBase = 0
                local selectedMenu = NotSelected
                local _, height = ImGui.GetContentRegionAvail()
                ImGui.BeginChild("listItems", 170, height-2, true)
                    if ImGui.TreeNode("Configs") then
                        for i, config in ipairs(Menu._.registrations.configs) do
                            ---@type CabbyConfig
                            config = config
                            local isSelected = selectedIndex == i + indexBase
                            if ImGui.Selectable(config.key, isSelected) then
                                selectedIndex = i + indexBase
                                if config.BuildMenu == nil then
                                    selectedMenu = PageDne
                                else
                                    selectedMenu = config.BuildMenu
                                end
                            end

                            if isSelected then
                                ImGui.SetItemDefaultFocus()
                            end
                        end
                        ImGui.TreePop()
                    end

                    indexBase = indexBase + #Menu._.registrations.configs
                    if ImGui.TreeNode("States") then
                        for i, state in ipairs(Menu._.registrations.states) do
                            ---@type State
                            state = state
                            local isSelected = selectedIndex == i + indexBase
                            if ImGui.Selectable(state.key, isSelected) then
                                selectedIndex = i + indexBase
                                if state.BuildMenu == nil then
                                    selectedMenu = PageDne
                                else
                                    selectedMenu = state.BuildMenu
                                end
                            end

                            if isSelected then
                                ImGui.SetItemDefaultFocus()
                            end
                        end
                        ImGui.TreePop()
                    end
                ImGui.EndChild()
                
                -- Right Pane Selected Child Menu
                local width, height = ImGui.GetContentRegionAvail()
                ImGui.SameLine()
                ImGui.BeginChild("displayPane", width - 178, height, true)
                    selectedMenu()
                ImGui.EndChild()
            ImGui.End()
        end)

        Menu._.isInit = true
    end
end

---@param config CabbyConfig
Menu.RegisterConfig = function(config)
    table.insert(Menu._.registrations.configs, config)
end

---@param state State
Menu.RegisterState = function(state)
    table.insert(Menu._.registrations.states, state)
end

return Menu
