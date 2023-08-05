local mq = require("mq")
local TableUtils = require("utils.TableUtils.TableUtils")

---@class Broadcast
local Broadcast = {
    channelTypes = {
        bc = {
            name = "bc",
            command = "bc",
            phrasePattern = "<#1#> <<phrase>>"
        },
        bct = {
            name = "bct",
            command = "bct",
            phrasePattern = "[#1#(msg)] <<phrase>>"
        },
        tell = {
            name = "tell",
            command = "tell",
            phrasePattern = "#1# tells you, '<<phrase>>'"
        },
        raid = {
            name = "raid",
            command = "rs",
            phrasePattern = "#1# tells the raid, '<<phrase>>'"
        },
        group = {
            name = "group",
            command = "g",
            phrasePattern = "#1# tells the group, '<<phrase>>'"
        }
    }
}

---@param channelType string channel type to check
---@return boolean isChannelType
function Broadcast.IsChannelType(channelType)
    return TableUtils.ArrayContains(Broadcast.GetAllChannelTypes(), channelType:lower())
end

function Broadcast.GetAllChannelTypes()
    local result = {}
    for _, channelType in pairs(Broadcast.channelTypes) do
        table.insert(result, channelType.name)
    end
    return result
end

---@param channels array Channel type names to use to generate phrase patterns
---@return array phrasePatterns 
function Broadcast.GetPhrasePatterns(channels)
    local phrasePatterns = {}

    for _, channel in ipairs(channels) do
        if Broadcast.IsChannelType(channel) then
            table.insert(phrasePatterns, Broadcast.channelTypes[channel:lower()].phrasePattern)
        else
            print("Invalid channel type provided: ["..channel.."]")
        end
    end

    return phrasePatterns
end

---@param line string event text line
---@return table? requestChannelType
function Broadcast.GetRequestChannel(line)
    for _, channelType in pairs(Broadcast.channelTypes) do
        local regex = string.gsub(channelType.phrasePattern, "%#1%#", "%.%*")
        regex = string.gsub(regex, "%<%<phrase%>%>", "%.%*")
        regex = string.gsub(regex, "%<", "%%%<")
        regex = string.gsub(regex, "%>", "%%%>")
        regex = string.gsub(regex, "%,", "%%%,")
        regex = string.gsub(regex, "%[", "%%%[")
        regex = string.gsub(regex, "%]", "%%%]")
        regex = string.gsub(regex, "%(", "%%%(")
        regex = string.gsub(regex, "%)", "%%%)")
        if line:find(regex) ~= nil then
            return channelType
        end
    end
end

function Broadcast.Message(channel, message, to)
    if to ~= nil then
        message = to .. " " .. message
    end
    mq.cmd("/"..Broadcast.channelTypes[channel].command.." "..message)
end

function Broadcast.Respond(eventLine, speaker, responseMessage)
    local requestChannel = Broadcast.GetRequestChannel(eventLine)
    if requestChannel == nil then
        print("Unable to broadcast. Could not find response channel for event line: " .. eventLine)
    else
        if requestChannel.name == Broadcast.channelTypes.tell.name or requestChannel.name == Broadcast.channelTypes.bct.name then
            responseMessage = speaker .. " " .. responseMessage
        end
        mq.cmd("/"..requestChannel.command.." "..responseMessage)
    end
end

return Broadcast
