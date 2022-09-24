-- includes
local PackageMan = require("mq/PackageMan")
local lfs = PackageMan.Require("luafilesystem", "lfs")
if not lfs then
    lfs = PackageMan.InstallAndLoad("luafilesystem")
end

-- fields
local DIR_SEP = package.config:sub(1,1)

-- lib functions

--- Find a file based on the root directory
-- @param root string: absolute file path to root folder to search from
-- @param fileName string: name of the file to find, including extension
-- @param isRecursive bool: true to recursively search in sub-folders
-- @return string: file path of found file
function FindFile(root, fileName, isRecursive)
	for entity in lfs.dir(root) do
		if entity ~= "." and entity ~= ".." then
			local fullPath = root..DIR_SEP..entity
			local mode = lfs.attributes(fullPath, "mode")
			if mode == "file" and entity == fileName then
				return fullPath
			elseif mode == "directory" and isRecursive then
				local result = FindFile(fullPath, fileName, isRecursive);
                if result ~= nil then
                    return result
                end
			end
		end
	end
end