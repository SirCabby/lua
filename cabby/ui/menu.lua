local mq = require("mq")
local ImGui = require "ImGui"

local ChelpDocs = require("cabby.commands.chelpDocs")
local Commands = require("cabby.commands.commands")
local SlashCmd = require("cabby.commands.slashcmd")
local UserInput = require("cabby.utils.userinput")

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

Menu.HelpMarker = function(message)
    ImGui.TextDisabled("(?)");
    if ImGui.IsItemHovered() then
        ImGui.BeginTooltip();
        ImGui.PushTextWrapPos(ImGui.GetFontSize() * 35.0);
        ImGui.TextUnformatted(message);
        ImGui.PopTextWrapPos();
        ImGui.EndTooltip();
    end
end

Menu.Init = function()
    if not Menu._.isInit then
        Menu.OpenMainMenu()

        local stateDocs = ChelpDocs.new(function()
            local result = { "(/state) Registered States:" }
            for i, state in ipairs(Menu._.registrations.states) do
                ---@type State
                state = state
                result[#result+1] = i .. ") " .. state.key:sub(1, -6) .. ": " .. tostring(state.IsEnabled())
            end
            result[#result+1] = "  -- Toggle a state: /state <name>"
            result[#result+1] = "  -- Set enabled: /state <name> <0 | 1>"
            return result
        end )
        local function Bind_State(...)
            local args = {...} or {}
            if args == nil or #args < 1 or #args > 2 or args[1]:lower() == "help" then
                stateDocs:Print()
                return
            end

            local arg1 = args[1]:lower()
            local arg2 = ""
            if #args == 2 then
                arg2 = args[2]:lower()
            end

            for _, state in ipairs(Menu._.registrations.states) do
                ---@type State
                state = state
                if state.key:sub(1, -6):lower() == arg1 then
                    if arg2 ~= "" then
                        state.SetEnabled(UserInput.IsTrue(arg2))
                    else
                        state.SetEnabled(not state.IsEnabled())
                    end

                    return
                end
            end

            stateDocs:Print()
        end
        Commands.RegisterSlashCommand(SlashCmd.new("state", Bind_State, stateDocs))

        local menuDocs = ChelpDocs.new(function() return {
            "(/cmenu) Toggles the Cabby Menu UI",
            "  -- Set On/Off: /cmenu <0 | 1>"
        } end )
        local function Bind_Menu(...)
            local args = {...} or {}
            local generalConfig = Global.configStore:GetConfigRoot()["GeneralConfig"]

            if #args < 1 then
                generalConfig.isMenuOpen = not generalConfig.isMenuOpen
                Global.configStore:SaveConfig()
                return
            end

            if #args ~= 1 or args[1]:lower() == "help" then
                menuDocs:Print()
                return
            end

            if UserInput.IsTrue(args[1]) then
                generalConfig.isMenuOpen = true
                Global.configStore:SaveConfig()
                return
            end
            if UserInput.IsFalse(args[1]) then
                generalConfig.isMenuOpen = false
                Global.configStore:SaveConfig()
                return
            end

            menuDocs:Print()
        end
        Commands.RegisterSlashCommand(SlashCmd.new("cmenu", Bind_Menu, menuDocs))

        Menu._.isInit = true
    end
end

Menu.OpenMainMenu = function()
    local selectedIndex = 0
    local generalConfig = Global.configStore:GetConfigRoot()["GeneralConfig"]

    mq.imgui.init("Cabby Menu", function()
        if generalConfig.isMenuOpen == nil then generalConfig.isMenuOpen = true end

        if not generalConfig.isMenuOpen then return end

        local open, show = ImGui.Begin("Cabby Menu", generalConfig.isMenuOpen)
        if open ~= generalConfig.isMenuOpen then
            generalConfig.isMenuOpen = open
            Global.configStore:SaveConfig()
        end
        if show then
            local indexBase = 0
            local selectedMenu = NotSelected
            local _, height = ImGui.GetContentRegionAvail()
            local childWindowFlags = bit32.bor(ImGuiChildFlags.Border)
            if ImGui.BeginChild("listItems", 170, height-2, childWindowFlags) then
                if ImGui.TreeNode("Configs") then
                    for i, config in ipairs(Menu._.registrations.configs) do
                        ---@type CabbyConfig
                        config = config
                        local isSelected = selectedIndex == i + indexBase
                        if ImGui.Selectable(config.key:sub(1, -7), isSelected) then
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
                        if ImGui.Selectable(state.key:sub(1, -6), isSelected) then
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
            end
            ImGui.EndChild()

            -- Right Pane Selected Child Menu
            local width, height = ImGui.GetContentRegionAvail()
            local childFlags = bit32.bor(ImGuiChildFlags.Border, ImGuiChildFlags.AutoResizeX)
            local windowFlags = bit32.bor(ImGuiWindowFlags.HorizontalScrollbar)
            ImGui.SameLine()
            if ImGui.BeginChild("displayPane", width - 178, height, childFlags, windowFlags) then
                selectedMenu()
            end
            ImGui.EndChild()
        end
        ImGui.End()
    end)
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
