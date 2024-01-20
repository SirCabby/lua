---@diagnostic disable: undefined-field
local mq = require("mq")
local TableUtils = require("utils.TableUtils.TableUtils")
local StringUtils= require("utils.StringUtils.StringUtils")

---@class Speak
local Speak = {
    channelTypes = {
        bc = {
            name = "bc",
            command = "bc",
            phrasePattern = "<#1#> <<phrase>>#2#",
            isTellType = false
        },
        bct = {
            name = "bct",
            command = "bct",
            phrasePattern = "[#1#(msg)] <<phrase>>#2#",
            isTellType = true
        },
        tell = {
            name = "tell",
            command = "tell",
            phrasePattern = "#1# tells you, '<<phrase>>#2#'",
            isTellType = true
        },
        raid = {
            name = "raid",
            command = "rs",
            phrasePattern = "#1# tells the raid, '<<phrase>>#2#'",
            isTellType = false
        },
        group = {
            name = "group",
            command = "g",
            phrasePattern = "#1# tells the group, '<<phrase>>#2#'",
            isTellType = false
        }
    }
}
Speak.__index = Speak

setmetatable(Speak, {
    __call = function (cls, ...)
        return cls.new(...)
    end
})

--- to leverage tell-to channel types, submit string as "<channeltype> <to>"
---@param channels table channel types
---@return Speak|nil
function Speak.new(channels)
    local self = setmetatable({}, Speak)

---@diagnostic disable-next-line: inject-field
    self._ = {}
    self._.channels = channels

    -- validate
    for _, channelWithTo in ipairs(channels) do
        channelWithTo = StringUtils.Split(channelWithTo)
        local channel = channelWithTo[1]
        if not Speak.IsChannelType(channel) then
            print("Invalid channel type supplied to speak: " .. channel)
            return nil
        end
        if Speak.IsTellType(channel) then
            if #channelWithTo ~= 2 then
                print("Invalid tell-type channel with recepient. Expected: '<tell-channel> <name>. Received: " .. channelWithTo)
                return nil
            end
        else
            if #channelWithTo ~= 1 then
                print("Cannot supply additional channel arguments for non tell-type channel. Received: " .. channelWithTo)
                return nil
            end
        end
    end

    return self
end

function Speak:speak(message)
    for _, channelWithTo in ipairs(self._.channels) do
        channelWithTo = StringUtils.Split(channelWithTo)
        local channel = channelWithTo[1]
        if Speak.IsTellType(channel) then
            local tellTo = channelWithTo[2]
            Speak.Message(channel, message, tellTo)
        else
            Speak.Message(channel, message)
        end
    end
end

function Speak:Print()
    print("Currently speaking to: [" .. StringUtils.Join(self._.channels, ", ") .. "]")
end

---@param channelType string channel type to check
---@return boolean isChannelType
function Speak.IsChannelType(channelType)
    return TableUtils.ArrayContains(Speak.GetAllChannelTypes(), channelType)
end

function Speak.IsTellType(channelType)
    if Speak.IsChannelType(channelType) then
        return Speak.channelTypes[channelType].isTellType
    end
    return false
end

function Speak.GetAllChannelTypes()
    local result = {}
    for _, channelType in pairs(Speak.channelTypes) do
        table.insert(result, channelType.name)
    end
    return result
end

---@param channels table Channel type names to use to generate phrase patterns
---@return table phrasePatterns 
function Speak.GetPhrasePatterns(channels)
    local phrasePatterns = {}

    for _, channel in ipairs(channels) do
        if Speak.IsChannelType(channel) then
            table.insert(phrasePatterns, Speak.channelTypes[channel:lower()].phrasePattern)
        else
            print("Invalid channel type provided: ["..channel.."]")
        end
    end

    return phrasePatterns
end

---@param line string event text line
---@return table? requestChannelType
function Speak.GetRequestChannel(line)
    for _, channelType in pairs(Speak.channelTypes) do
        local regex = string.gsub(channelType.phrasePattern, "%#1%#", "%.%*")
        regex = string.gsub(regex, "%#2%#", "%.%*")
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

function Speak.Message(channel, message, to)
    if Speak.IsTellType(channel) then
        if to == nil then
            print("Cannot speak a message to a tell channel without a recipient name")
            return
        end
        message = to .. " " .. message
    else
        if to ~= nil then
            print("Cannot speak a message to a recipient when not in a tell-type channel")
            return
        end
    end
    mq.cmd("/"..Speak.channelTypes[channel].command.." "..message)
end

function Speak.Respond(eventLine, speaker, responseMessage)
    local requestChannel = Speak.GetRequestChannel(eventLine)
    if requestChannel == nil then
        print("Unable to speak. Could not find response channel for event line: " .. eventLine)
    else
        if requestChannel.name == Speak.channelTypes.tell.name or requestChannel.name == Speak.channelTypes.bct.name then
            responseMessage = speaker .. " " .. responseMessage
        end
        mq.cmd("/"..requestChannel.command.." "..responseMessage)
    end
end

return Speak
