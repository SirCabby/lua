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

---What a client-side chat timestamp looks like in front of a line: `[23:39:30] ` or
---`[Sun Jul 26 23:39:30 2026] `. Some clients (RoF2 client-plus among them) put one on every
---line, and MQ feeds Blech the line as rendered, so every pattern here has to cope with it being
---there or not.
local timestampPrefix = "[#*#] "

---Take the speaker's name back out of a capture that may have swallowed a timestamp.
---
---Two shapes arrive, depending on where the pattern's first wildcard sits. A pattern that starts
---with `#1#` captures the whole prefix (`[Sun Jul 26 23:39:30 2026] Haedes`), and `bct`'s
---`[#1#(msg)]` captures from inside the timestamp's own bracket (`23:39:30] [Haedes`). Rather
---than unpick either, take the name off the end: EQ names are letters, chat carries the first
---name alone, and nothing else in these captures ends in a run of letters.
---@param name string|nil as captured from the chat line
---@return string|nil speaker
function Speak.CleanSpeaker(name)
    if name == nil then return nil end

    local cleaned = tostring(name):match("(%a+)%s*$")
    if cleaned == nil then return name end
    return cleaned
end

---Whether a pattern needs a second, timestamped copy of itself registered alongside it.
---
---Only when the plain pattern *cannot* match a timestamped line, which is narrower than it
---looks. Blech files a pattern under the first character it can match, and tests a line only
---against the patterns filed under the line's own first character plus those filed under "starts
---with a variable". So a pattern opening with a scan variable (`#1#`, `#*#`) is tested against
---every line and swallows the timestamp into that first capture, and one opening with `[` is
---filed under `[`, which is exactly what a timestamp starts with -- both still fire, and
---`CleanSpeaker` puts the speaker capture right. Registering a variant for those would be
---actively harmful: the line would match both patterns and every command would run twice, which
---on a toggle is two flips and no visible effect.
---
---Anything else -- a pattern opening with literal text, `You have been slain by #1#!` -- is filed
---under that letter, is never tested against a line beginning with `[`, and is simply never heard
---while timestamps are on. Those are the patterns that need the variant.
---@param pattern string
---@return boolean needsVariant
local function NeedsTimestampVariant(pattern)
    -- `##` is Blech's escape for a literal `#`, so it opens with text, not a variable
    if pattern:sub(1, 1) == "#" and pattern:sub(2, 2) ~= "#" then return false end
    if pattern:sub(1, 1) == "[" then return false end
    return true
end

---Every pattern that has to be registered for `pattern` to be heard, whether or not the client
---stamps a timestamp on the line.
---
---Registering what this returns -- rather than the pattern alone -- is the whole of coping with
---timestamps on the listening side; `CleanSpeaker` handles the capture side.
---@param pattern string
---@return table patterns the pattern itself, plus a timestamped copy when it needs one
function Speak.GetListenPatterns(pattern)
    local patterns = { pattern }
    if NeedsTimestampVariant(pattern) then
        table.insert(patterns, timestampPrefix .. pattern)
    end
    return patterns
end

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
            local pattern = Speak.channelTypes[channel:lower()].phrasePattern
            for _, listenPattern in ipairs(Speak.GetListenPatterns(pattern)) do
                table.insert(phrasePatterns, listenPattern)
            end
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
