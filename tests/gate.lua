-- Gate: the keep/reject rule for a fix round and the baseline file it judges against. Pure numbers in, verdict out: no
-- addon, no bench.lua, no score_lib.lua; bench builds the numbers from its in-memory results (never from printed text).
--
--   lua tests/gate.lua    runs the start-up asserts and prints nothing
--
-- A baseline is { looRight, baseWrong, druidRight, druidWrong, maxWrong = { [class] = n }, k, commit }; a candidate is
-- the same plus flakes. Every number is a percentage of the meter, compared as raw floats.

local G = {}

local STEP, DRUID_STEP = 0.05, 0.1 -- the smallest move that counts: loo/base/shuffle numbers, the hold-out druid

-- Sorted class names of a maxWrong table: the order reasons and the baseline text come out in.
local function SortedClasses(maxWrong)
    local classes = {}
    for class in pairs(maxWrong) do classes[#classes + 1] = class end
    table.sort(classes)

    return classes
end

-- KEEP when nothing got worse past its step and something got better past its step; else REJECT with every reason.
-- Improvements: looRight up, baseWrong down, any baseline class's maxWrong down. The druid and the flakes never improve.
function G.Judge(baseline, candidate)
    local reasons, improved = {}, false
    local function Check(label, delta, step, lowerIsBetter, canImprove)
        local worse = lowerIsBetter and delta >= step or not lowerIsBetter and delta <= -step
        local better = lowerIsBetter and delta <= -step or not lowerIsBetter and delta >= step
        if worse then reasons[#reasons + 1] = string.format("%s %+.2f", label, delta) end
        improved = improved or canImprove and better
    end
    Check("looRight", candidate.looRight - baseline.looRight, STEP, false, true)
    Check("baseWrong", candidate.baseWrong - baseline.baseWrong, STEP, true, true)
    for _, class in ipairs(SortedClasses(baseline.maxWrong)) do
        local now = candidate.maxWrong[class]
        if now == nil then error("gate: baseline class " .. class .. " missing from the run") end
        Check("maxWrong " .. class, now - baseline.maxWrong[class], STEP, true, true)
    end
    if candidate.flakes ~= 0 then reasons[#reasons + 1] = "flakes " .. candidate.flakes end
    Check("druidRight", candidate.druidRight - baseline.druidRight, DRUID_STEP, false, false)
    Check("druidWrong", candidate.druidWrong - baseline.druidWrong, DRUID_STEP, true, false)
    if not improved then reasons[#reasons + 1] = "nothing improved" end

    return #reasons == 0 and "KEEP" or "REJECT", reasons
end

-- The baseline file's text: keys sorted, floats to 0.0001, maxWrong on one line with its classes sorted.
function G.GateText(numbers)
    local flakes = numbers.flakes or 0
    if flakes > 0 then
        error("gate: refusing to save a baseline from a run with " .. flakes .. " flakes")
    end
    local parts = {}
    for index, class in ipairs(SortedClasses(numbers.maxWrong)) do
        parts[index] = string.format("%s = %.4f", class, numbers.maxWrong[class])
    end

    return table.concat({
        "return {\n",
        string.format("    baseWrong = %.4f,\n", numbers.baseWrong),
        string.format("    commit = %q,\n", numbers.commit),
        string.format("    druidRight = %.4f,\n", numbers.druidRight),
        string.format("    druidWrong = %.4f,\n", numbers.druidWrong),
        string.format("    k = %d,\n", numbers.k),
        string.format("    looRight = %.4f,\n", numbers.looRight),
        "    maxWrong = { " .. table.concat(parts, ", ") .. " },\n",
        "}\n",
    })
end

local function CheckBaseline(t, path)
    if type(t) ~= "table" then error("gate baseline " .. path .. ": not a table") end
    for _, field in ipairs({ "baseWrong", "commit", "druidRight", "druidWrong", "k", "looRight", "maxWrong" }) do
        if t[field] == nil then error("gate baseline " .. path .. ": missing " .. field) end
    end
    if type(t.maxWrong) ~= "table" then error("gate baseline " .. path .. ": maxWrong is not a table") end

    return t
end

function G.LoadBaseline(path)
    local file = io.open(path)
    if not file then error("gate baseline " .. path .. ": not found") end
    file:close()
    local t = dofile(path)

    return CheckBaseline(t, path)
end

do -- start-up asserts
    local B = { looRight = 60, baseWrong = 1, druidRight = 20, druidWrong = 0.5, maxWrong = { shaman = 0.5, warlock = 1 } }
    local function C(overrides)
        local copy = { flakes = 0, maxWrong = {} }
        for key, value in pairs(B) do copy[key] = value end
        for class, value in pairs(B.maxWrong) do copy.maxWrong[class] = value end
        for key, value in pairs(overrides or {}) do copy[key] = value end

        return copy
    end
    local function Expect(candidate, want, why, label)
        local verdict, reasons = G.Judge(B, candidate)
        local got = table.concat(reasons, "; ")
        assert(verdict == want and got == why,
            "Judge: " .. label .. ": want " .. want .. " '" .. why .. "', got " .. verdict .. " '" .. got .. "'")
    end
    Expect(C(), "REJECT", "nothing improved", "no change")
    Expect(C({ looRight = 59.9 }), "REJECT", "looRight -0.10; nothing improved", "looRight drops")
    Expect(C({ baseWrong = 0.9 }), "KEEP", "", "baseWrong falls")
    Expect(C({ looRight = 59.97, baseWrong = 0.9 }), "KEEP", "", "looRight within its step")
    Expect(C({ maxWrong = { shaman = 0.5, warlock = 0.9 } }), "KEEP", "", "a maxWrong falls")
    Expect(C({ maxWrong = { shaman = 0.5, warlock = 1, priest = 9 } }), "REJECT", "nothing improved", "run class outside the baseline")
    Expect(C({ maxWrong = { shaman = 0.5, warlock = 1, druid = -1 } }), "REJECT", "nothing improved", "druid maxWrong never counts")
    Expect(C({ druidRight = 19.8 }), "REJECT", "druidRight -0.20; nothing improved", "druidRight drops")
    Expect(C({ druidRight = 20.5 }), "REJECT", "nothing improved", "druidRight rises is no improvement")
    Expect(C({ looRight = 60.1 }), "KEEP", "", "looRight rises is an improvement")
    Expect(C({ druidWrong = 0.3 }), "REJECT", "nothing improved", "druidWrong falling is no improvement")
    Expect(C({ druidRight = 19.93 }), "REJECT", "nothing improved", "druidRight within its step")
    Expect(C({ druidRight = 19.88 }), "REJECT", "druidRight -0.12; nothing improved", "druidRight past its step")
    Expect(C({ flakes = 1 }), "REJECT", "flakes 1; nothing improved", "a flake")
    Expect(C({ looRight = 59.9, baseWrong = 1.06, maxWrong = { shaman = 0.7, warlock = 1.1 }, flakes = 2, druidWrong = 0.8 }),
        "REJECT", "looRight -0.10; baseWrong +0.06; maxWrong shaman +0.20; maxWrong warlock +0.10; flakes 2; druidWrong +0.30; nothing improved",
        "every reason, in order")
    local ok, message = pcall(G.Judge, B, C({ maxWrong = { shaman = 0.5 } }))
    assert(not ok and message:find("warlock", 1, true), "Judge: a baseline class missing from the run is an error naming it")

    local sample = { looRight = 61.9012, baseWrong = 0.8123, druidRight = 12.3456, druidWrong = 0.4321, k = 8, commit = "5071da7",
        maxWrong = { warlock = 0.6, shaman = 0, priest = 0.9 } }
    local text = G.GateText(sample)
    assert(text == 'return {\n    baseWrong = 0.8123,\n    commit = "5071da7",\n    druidRight = 12.3456,\n    druidWrong = 0.4321,\n'
        .. '    k = 8,\n    looRight = 61.9012,\n    maxWrong = { priest = 0.9000, shaman = 0.0000, warlock = 0.6000 },\n}\n',
        "GateText: the baseline text, keys and classes sorted")
    local back = load(text)()
    for _, field in ipairs({ "looRight", "baseWrong", "druidRight", "druidWrong", "k", "commit" }) do
        assert(back[field] == sample[field], "GateText: " .. field .. " round-trips")
    end
    for class, value in pairs(sample.maxWrong) do
        assert(back.maxWrong[class] == value, "GateText: maxWrong " .. class .. " round-trips")
    end
    sample.flakes = 1
    assert(not pcall(G.GateText, sample), "GateText: refuses a run with flakes")
    sample.flakes = nil
    sample.k = nil
    local checked, why = pcall(CheckBaseline, sample, "x.lua")
    assert(not checked and why:find("missing k", 1, true), "CheckBaseline: a baseline without k is an error")
    sample.k = 8
    sample.maxWrong = nil
    checked, why = pcall(CheckBaseline, sample, "x.lua")
    assert(not checked and why:find("missing maxWrong", 1, true), "CheckBaseline: a baseline without maxWrong is an error")
    checked, why = pcall(CheckBaseline, nil, "x.lua")
    assert(not checked and why:find("not a table", 1, true), "CheckBaseline: a baseline that is not a table is an error")
    sample.maxWrong = 3
    checked, why = pcall(CheckBaseline, sample, "x.lua")
    assert(not checked and why:find("maxWrong is not a table", 1, true), "CheckBaseline: a maxWrong that is not a table is an error")
end

return G
