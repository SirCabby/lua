---@class ChelpDocs
---@field lines function Returns array of string lines
---@field additionalLines table Table of additional lines arrays
local ChelpDocs = {}

ChelpDocs.__index = ChelpDocs
setmetatable(ChelpDocs, {
    __call = function (cls, ...)
        return cls.new(...)
    end
})

---@param lines function
---@return ChelpDocs
function ChelpDocs.new(lines)
    local self = setmetatable({}, ChelpDocs)

    self.lines = lines
    self.additionalLines = {}

    return self
end

---@param key string
---@param lines function Returns array of string lines
function ChelpDocs:AddAdditionalLines(key, lines)
    self.additionalLines[key] = ChelpDocs.new(lines)
end

function ChelpDocs:Print()
    for _, line in ipairs(self.lines()) do
        print(line)
    end
end

---@return table lines
function ChelpDocs:GetLines()
    return self.lines()
end

return ChelpDocs
