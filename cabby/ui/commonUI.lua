---@class CommonUI
local CommonUI = {}

CommonUI.HelpMarker = function(message)
    ImGui.TextDisabled("(?)");
    if ImGui.IsItemHovered() then
        ImGui.BeginTooltip();
        ImGui.PushTextWrapPos(ImGui.GetFontSize() * 35.0);
        ImGui.TextUnformatted(message);
        ImGui.PopTextWrapPos();
        ImGui.EndTooltip();
    end
end

return CommonUI
