local save, out = arg[1], arg[2]
local env = {}
assert(loadfile(save, "t", env))()
local log = assert(env.CombatTextIconsDB and env.CombatTextIconsDB.debugLog, "no debugLog in " .. save)
local file = assert(io.open(out, "wb")) -- "wb": LF on Windows too
for _, line in ipairs(log) do file:write(line, "\n") end
file:close()
print(#log .. " lines -> " .. out)
