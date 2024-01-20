local PackageMan = require("mq/PackageMan")

local Debug = require("utils.Debug.Debug")
local StringUtils = require("utils.StringUtils.StringUtils")

---@class FileSystem
local FileSystem = { author = "judged", DIR_SEP = package.config:sub(1,1), key = "FileSystem" }

local function DebugLog(str)
    Debug.Log(FileSystem.key, str)
end

local function getLfs()
    if FileSystem.lfs == nil then
        FileSystem.lfs = PackageMan.Require("luafilesystem", "lfs")
    end
    return FileSystem.lfs
end

--- Find a file based on the root directory
---@param root string: absolute file path to root folder to search from
---@param fileName string: name of the file to find, including extension
---@param isRecursive boolean: true to recursively search in sub-folders
---@return string: file path of found file, empty string if not
function FileSystem.FindFile(root, fileName, isRecursive)
    DebugLog("Finding file [" .. fileName .. "] recursively? " .. tostring(isRecursive) .. ", in root: " .. root)
    local lfs = getLfs()
	for entity in lfs.dir(root) do
		if entity ~= "." and entity ~= ".." and entity ~= ".git" and entity ~= ".vscode" then
            local fullPath = FileSystem.PathJoin(root, entity)
			local mode = lfs.attributes(fullPath, "mode")
            DebugLog("Found file or directory with mode [" .. mode .. "]: " .. fullPath)
			if mode == "file" and string.lower(entity) == string.lower(fileName) then
                DebugLog("Found matching file: " .. fullPath)
				return fullPath
			elseif mode == "directory" and isRecursive then
                DebugLog("Found directory: " .. fullPath)
				local result = FileSystem.FindFile(fullPath, fileName, true);
                if result ~= "" then
                    return result
                end
			end
		end
	end
    return ""
end

--- Find all files based on the root directory
---@param root string: absolute file path to root folder to search from
---@param searchText string: search file names for this text
---@param isRecursive boolean: true to recursively search in sub-folders
---@return table: array of found files
function FileSystem.FindAllFiles(root, searchText, isRecursive)
    local result = {}
    local lfs = getLfs()
    DebugLog("Finding files matching [" .. searchText .. "] recursively? " .. tostring(isRecursive) .. ", in root: " .. root)
	for entity in lfs.dir(root) do
		if entity ~= "." and entity ~= ".." and entity ~= ".git" and entity ~= ".vscode" then
            local fullPath = FileSystem.PathJoin(root, entity)
			local mode = lfs.attributes(fullPath, "mode")
            DebugLog("Found file or directory with mode [" .. mode .. "]: " .. fullPath)
			if mode == "file" and entity:lower():find(searchText:lower()) then
                DebugLog("Found matching file: " .. fullPath)
                result[#result+1] = fullPath
			elseif mode == "directory" and isRecursive then
                DebugLog("Found directory: " .. fullPath)
				local recurResult = FileSystem.FindAllFiles(fullPath, searchText, true);
                if #recurResult > 0 then
                    for i = 1, #recurResult do
                        result[#result+1] = recurResult[i]
                    end
                end
			end
		end
	end
    return result
end

---@param filePath string absolute path
---@return boolean
function FileSystem.FileExists(filePath)
    local mode = getLfs().attributes(filePath, "mode")
    DebugLog("Does file exist? " .. tostring(mode == "file") .. ": " .. filePath)
    return mode == "file"
end

---Opens file, reads it to a single string, and closes file
---@param filePath string
---@return string
function FileSystem.ReadFile(filePath)
    DebugLog("Feading file: " .. filePath)
    assert(FileSystem.FileExists(filePath), "Unable to find file: " .. filePath)
    local file = io.open(filePath, "r")
    assert(file ~= nil, "Unable to open file: " .. filePath)
    local result = file:read("*a")
    file:close()
    DebugLog("Read result: " .. result)
    return result
end

---Opens or Creates file, writes content into it, then closes file
---@param filePath string
---@param content table string array of lines to write
function FileSystem.WriteFile(filePath, content)
    DebugLog("Writing file: " .. filePath)
    local file = io.open(filePath, "w+")
    assert(file ~= nil, "Unable to create file: " .. filePath)
    for _, value in ipairs(content) do
        DebugLog("Wrote line: " .. value)
        file:write(value, "\n")
    end
    file:close()
end

---@return string
function FileSystem.PathJoin(...)
    local result = StringUtils.Join({...}, FileSystem.DIR_SEP)
    DebugLog("Joined strings: " .. result)
    return result
end

return FileSystem
