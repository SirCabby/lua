local mq = require("mq")
local Json = require("utils.Json.Json")

mq.cmd("/mqclear")

-- {
--     "key": 1,
--     "key2": [
--         {
--             "foo" = true,
--             "bar" = 0
--         },
--         {
--             "boo" = "hi"
--         },
--     ]
-- }
local key2arrayObj1 = {
    foo = true,
    bar = 0
}
local key2arrayObj2 = {
    boo = "hi"
}
local key2Array = {
    key2arrayObj1,
    key2arrayObj2
}
local tbl = {}
tbl.key = 1
tbl.key2 = key2Array

local array = {}
table.insert(array, key2arrayObj1)
table.insert(array, key2arrayObj1)
table.insert(array, key2arrayObj2)
table.insert(array, key2arrayObj1)

--Json.debug = true

print("test: \"hey\"")
Json.Print(Json.Serialize("hey"))
print()
print("test: 1")
Json.Print(Json.Serialize(1))
print()
print("test: true")
Json.Print(Json.Serialize(true))
print()
print("test: nil")
Json.Print(Json.Serialize(nil))
print()

print("test: table")
Json.Print(Json.Serialize(tbl))
print()
print("test: deserialize table and reserialize")
print()
local obj = Json.Deserialize(Json.Serialize(tbl))
Json.Print(Json.Serialize(obj))

print("test: array")
Json.Print(Json.Serialize(array))
print()
print("test: deserialize array and reserialize")
print()
obj = Json.Deserialize(Json.Serialize(array))
Json.Print(Json.Serialize(obj))
