local _, ns = ...

local routeAt

-- Owner sets the clock while a released hit routes, so the hit is judged at the time it happened (spec 7a).
function ns.SetRouteClock(at) routeAt = at end

function ns.Now() return routeAt or GetTime() end
