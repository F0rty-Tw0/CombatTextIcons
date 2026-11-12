-- The rig the Owner route, saved-state and wiring checks share: a Forever (or other build) namespace with SW:P learned.
-- Loaded by dofile from those files with their T table; returns Rig, SWP and P.
return function(T)
    local SWP, P = 594, 3.011735764150819 -- Shadow Word: Pain as learned in game (school 32)

    -- Forever (opts.interface: another build) with SW:P learned. Grouped unless opts.solo. Owner stubbed active (rig.on;
    -- opts.off starts inactive).
    -- Unless opts.realOwner, Owner.Hit only records its packed arguments in rig.taken. opts.setup(S) runs before load.
    local function Rig(opts)
        opts = opts or {}
        local rig = { draws = {}, log = {}, taken = {}, on = opts.off ~= true }
        rig.ns = T.Boot(function(S)
            S.interface = opts.interface or 16001
            S.group = opts.solo ~= true
            CombatTextIconsCharDB = { learned = { [SWP] = { school = 32, kind = "dot", period = P, misses = 0 } } }
            if opts.setup then opts.setup(S) end
        end)
        rig.S = T.State()
        local ns, S = rig.ns, rig.S
        ns.Teacher.area = "clear"
        ns.Display.Plate = function(plate, texture) rig.draws[#rig.draws + 1] = { plate = plate, texture = texture } end
        ns.Display.Player = function(kind, texture) rig.draws[#rig.draws + 1] = { kind = kind, texture = texture } end
        ns.Debug = function(format, ...) rig.log[#rig.log + 1] = string.format(format, ...) end
        ns.Owner.Active = function() return rig.on end
        ns.Owner.IsActive = function() return rig.on end
        if not opts.realOwner then ns.Owner.Hit = function(...) rig.taken[#rig.taken + 1] = table.pack(...) end end

        -- The plate the client holds for `unit`.
        function rig.Plate(unit) return C_NamePlate.GetNamePlateForUnit(unit) end

        -- Casts `spellID` (SW:P by default) at `t` aimed at `unit`.
        function rig.Cast(t, unit, spellID)
            S.now, S.target = t, unit
            ns.Core.UNIT_SPELLCAST_SUCCEEDED("player", "c", spellID or SWP)
        end

        -- A WOUND event on `unit` at `t`, as the client sends it; returns the texture drawn or nil.
        function rig.Hit(t, unit, amount, school, flag)
            S.now = t
            local before = #rig.draws
            ns.Core.UNIT_COMBAT(unit, "WOUND", flag or "", amount or 31, school or 32)

            return #rig.draws > before and rig.draws[#rig.draws].texture or nil
        end

        -- A hit as Owner releases it.
        function rig.Snap(t, unit, amount, school, isTarget)
            return { kind = "hit", plate = rig.Plate(unit), unit = unit, flagText = "", amount = amount, school = school,
                now = t, isTarget = isTarget, owned = true }
        end

        -- The texture HitRoute.Route draws for a released hit, or nil when it stayed hidden.
        function rig.Route(hit)
            local before = #rig.draws
            ns.HitRoute.Route(hit)

            return #rig.draws > before and rig.draws[#rig.draws].texture or nil
        end

        -- Whether a debug line starts with `prefix`.
        function rig.Logged(prefix)
            for _, line in ipairs(rig.log) do
                if line:sub(1, #prefix) == prefix then return true end
            end

            return false
        end

        -- The last route line ("  ->") of the debug log.
        function rig.LastRoute()
            for index = #rig.log, 1, -1 do
                if rig.log[index]:find("^  %->") then return rig.log[index] end
            end
        end

        return rig
    end

    return Rig, SWP, P
end
