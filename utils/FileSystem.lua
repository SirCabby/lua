local PackageMan = require("mq/PackageMan")
local lfs = PackageMan.Require("luafilesystem", "lfs")
local StringUtils = require("utils.StringUtils.StringUtils")

---@class FileSystem
local FileSystem = { author = "judged", DIR_SEP = package.config:sub(1,1) }

--- Find a file based on the root directory
---@param root string: absolute file path to root folder to search from
---@param fileName string: name of the file to find, including extension
---@param isRecursive boolean: true to recursively search in sub-folders
---@return string: file path of found file, empty string if not
function FileSystem.FindFile(root, fileName, isRecursive)
	for entity in lfs.dir(root) do
		if entity ~= "." and entity ~= ".." and entity ~= ".git" and entity ~= ".vscode" then
            local fullPath = FileSystem.PathJoin(root, entity)
			local mode = lfs.attributes(fullPath, "mode")
			if mode == "file" and string.lower(entity) == string.lower(fileName) then
				return fullPath
			elseif mode == "directory" and isRecursive then
				local result = FileSystem.FindFile(fullPath, fileName, true);
                if result ~= "" then
                    return result
                end
			end
		end
	end
    return ""
end

---@param filePath string absolute path
---@return boolean
function FileSystem.FileExists(filePath)
    local mode = lfs.attributes(filePath, "mode")
    return mode == "file"
end

---Opens file, reads it to a single string, and closes file
---@param filePath string
---@return string
function FileSystem.ReadFile(filePath)
    assert(FileSystem.FileExists(filePath), "Unable to find file: " .. filePath)
    local file = io.open(filePath, "r")
    assert(file ~= nil, "Unable to open file: " .. filePath)
    local result = file:read("*a")
    file:close()
    return result
end

---Opens or Creates file, writes content into it, then closes file
---@param filePath string
---@param content table string array of lines to write
function FileSystem.WriteFile(filePath, content)
    local file = io.open(filePath, "w+")
    assert(file ~= nil, "Unable to create file: " .. filePath)
    for _, value in ipairs(content) do
        file:write(value, "\n")
    end
    file:close()
end

---@return string
function FileSystem.PathJoin(...)
    return StringUtils.Join({...}, FileSystem.DIR_SEP)
end

return FileSystem
