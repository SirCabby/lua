--[[
Config.store: { <-- Global / static config manager table
    "filepath1": { <-- Config:new() will be scoped to this
        "name1": { <-- each GetConfig returns this, but static reference so more copies share state and don't thrash
            ...
        }
    }
}
--]]

---@class ConfigStore
local ConfigStore = { author = "judged", key = "ConfigStore", store = {} }

return ConfigStore
