---@class SlashCmd : CommandBase
---@field cmdFunction function
local SlashCmd = {}

SlashCmd.__index = SlashCmd
setmetatable(SlashCmd, {
    __call = function (cls, ...)
        return cls.new(...)
    end
})

---@param command string
---@param cmdFunction function
---@param docs ChelpDocs
---@return SlashCmd
function SlashCmd.new(command, cmdFunction, docs)
    local self = setmetatable({}, SlashCmd)

    self.command = command
    self.cmdFunction = cmdFunction
    self.docs = docs

    return self
end

return SlashCmd
