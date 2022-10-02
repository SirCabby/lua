local PackageMan = require("mq/PackageMan")
local lfs = PackageMan.Require("luafilesystem", "lfs")

---@class FileSystem
local FileSystem = { author = "judged" }
local DIR_SEP = package.config:sub(1,1)


--- Find a file based on the root directory
---@param root string: absolute file path to root folder to search from
---@param fileName string: name of the file to find, including extension
---@param isRecursive boolean: true to recursively search in sub-folders
---@return string: file path of found file, empty string if not
function FileSystem.FindFile(root, fileName, isRecursive)
	for entity in lfs.dir(root) do
		if entity ~= "." and entity ~= ".." then
			local fullPath = root..DIR_SEP..entity
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

return FileSystem
