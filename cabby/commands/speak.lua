---@diagnostic disable: undefined-field
local mq = require("mq")
local TableUtils = require("utils.TableUtils.TableUtils")
local StringUtils= require("utils.StringUtils.StringUtils")

---@class Speak
local Speak = {
    channelTypes = {
        -- `self` is not a chat channel: nothing is said out loud and nothing is listened for.
        -- Commands.Dispatch hands the phrase straight to its handler with our own name as the
        -- speaker (that is what /cself and hotbar buttons use), and this entry exists so those
        -- dispatches carry a line shaped like every other channel's -- Respond() can then find
        -- its way back here and answer in our own console instead of a channel.
        self = {
            name = "self",
            command = "echo",
            phrasePattern = "#1# tells themself, '<<phrase>>#2#'",
            isTellType = false,
            isLocal = true,
            order = 1
        },
        bc = {
            name = "bc",
            command = "bc",
            phrasePattern = "<#1#> <<phrase>>#2#",
            isTellType = false,
            order = 2
        },
        bct = {
            name = "bct",
            command = "bct",
            phrasePattern = "[#1#(msg)] <<phrase>>#2#",
            isTellType = true,
            order = 3
        },
        tell = {
            name = "tell",
            command = "tell",
            phrasePattern = "#1# tells you, '<<phrase>>#2#'",
            isTellType = true,
            order = 4
        },
        group = {
            name = "group",
            command = "g",
            phrasePattern = "#1# tells the group, '<<phrase>>#2#'",
            isTellType = false,
            order = 5
        },
        raid = {
            name = "raid",
            command = "rs",
            phrasePattern = "#1# tells the raid, '<<phrase>>#2#'",
            isTellType = false,
            order = 6
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
                print("Invalid tell-type channel with recepient. Expected: '<tell-channel> <name>. Received: " .. StringUtils.Join(channelWithTo, " "))
                return nil
            end
        else
            if #channelWithTo ~= 1 then
                print("Cannot supply additional channel arguments for non tell-type channel. Received: " .. StringUtils.Join(channelWithTo, " "))
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

---@return table speakChannels
function Speak:GetActiveSpeakChannels()
    return self._.channels
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

---@param channelType string channel type to check
---@return boolean isLocal true for channels that never touch chat, so they are dispatched to
---this character in-process instead of being spoken and listened for
function Speak.IsLocalType(channelType)
    if Speak.IsChannelType(channelType) then
        return Speak.channelTypes[channelType].isLocal == true
    end
    return false
end

---@return table channelTypes every channel name, in a stable display order
function Speak.GetAllChannelTypes()
    local channelTypes = {}
    for _, channelType in pairs(Speak.channelTypes) do
        table.insert(channelTypes, channelType)
    end
    -- pairs() order is arbitrary, and these lists drive combo boxes and help text
    table.sort(channelTypes, function(a, b) return (a.order or 0) < (b.order or 0) end)

    local result = {}
    for _, channelType in ipairs(channelTypes) do
        table.insert(result, channelType.name)
    end
    return result
end

---@return table channelTypes channels that can be listened on: local channels arrive by
---direct dispatch and have no chat line to match against
function Speak.GetListenChannelTypes()
    local result = {}
    for _, channelType in ipairs(Speak.GetAllChannelTypes()) do
        if not Speak.IsLocalType(channelType) then
            table.insert(result, channelType)
        end
    end
    return result
end

---@param channels table Channel type names to use to generate phrase patterns
---@return table phrasePatterns
function Speak.GetPhrasePatterns(channels)
    local phrasePatterns = {}

    for _, channel in ipairs(channels) do
        if not Speak.IsChannelType(channel) then
            print("Invalid channel type provided: ["..channel.."]")
        elseif not Speak.IsLocalType(channel) then
            -- a local channel has no chat line to listen for; registering its pattern as an
            -- event would only add a matcher that can never fire
            table.insert(phrasePatterns, Speak.channelTypes[channel:lower()].phrasePattern)
        end
    end

    return phrasePatterns
end

---Fill in a channel's pattern to produce the line a command would have arrived on. Used by
---the local channel, whose "line" is synthesized rather than read out of chat.
---@param channelType string
---@param speaker string who the command is attributed to
---@param phrase string command phrase plus any arguments
---@return string line
function Speak.BuildLine(channelType, speaker, phrase)
    if not Speak.IsChannelType(channelType) then return phrase end

    -- function replacements: speaker and phrase are user data, and a `%` in them would
    -- otherwise be read as a capture reference
    local line = string.gsub(Speak.channelTypes[channelType].phrasePattern, "#1#", function() return speaker end)
    line = string.gsub(line, "#2#", "")
    return (string.gsub(line, "<<phrase>>", function() return phrase end))
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
