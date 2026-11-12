-- Combat Text Icons: the route clock. ns.Now() is the time a hit is judged at: GetTime(), or the stamp Owner set while
-- it routes a held hit (ns.SetRouteClock).

local _, ns = ...

local routeAt

-- Owner sets the clock while a released hit routes, so the hit is judged at the time it happened (spec 7a).
function ns.SetRouteClock(at) routeAt = at end

function ns.Now() return routeAt or GetTime() end
