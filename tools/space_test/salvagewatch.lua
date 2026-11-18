-- TEST (test installs only, tools/space_test): the salvage log. It switches itself on the first time you are in a space raid (or F9
-- "Log salvage"). Do the whole chain in one run: look at the wrecks, fly to one, press R, look at the hold, loot or purge it, dock,
-- and see whether the salvage is still there. bridge/salvage.txt gets (t is seconds since the game started):
--   WORLD   the level changed
--   SHIP    your frigate and the hold (RaidSpaceshipInside) found: class, where, authority
--   PROPS   every property of their classes with its type and offset (the frigate holds the wreck it sees at +0xD08: this names it)
--   ALL     every plain value (numbers, true or false, text) an object holds when first seen
--   CHG     a value changed (frigate, hold, a wreck): the salvage flags, the dock flags, what the scan sees
--   REF     an object pointer property changed (which wreck the frigate sees, which salvage the hold holds)
--   WRECK   a salvageable actor (wreck, inside salvage, level node) appeared (NEW) or is gone (GONE, with where it was last and how
--           far from the frigate), and MOVE / HIDE / ATTACH when it moved, was hidden or was attached to something
--   REACH   the nearest outside wreck and its distance to the frigate; the frigate's salvage scan only sees 1500 cm
--   DOCK    the hold's docked flag changed: ACTOR lines (every salvage actor: where, hidden, attached) and SNAPs follow at 0.5, 3 and 10 s
--   KEY     R was pressed: how far the nearest wreck was; SNAP lines follow 0.5 s and 3 s later
--   SNAP    every value of the frigate and the hold at that moment (also when a wreck is gone)
--   FUNCS   every function of the classes involved; Blueprint ones, and native ones named like salvage, dock, purge, unload, loot,
--           wreck or OnRep_, are hooked
--   CALL    one of those functions ran (the first 30 times each), with its arguments
--   DESTROY / ENDPLAY / HIDDEN / ATTACH   the engine was asked to destroy, end, hide or attach something named *salvage*
--   PARAMS  a Blueprint function and where its bytecode is (for tools\kdis_salvage.py, which reads it while this game session is open)
--   MENU    a line from the test menu (spawned a wreck, removed it)
-- Reading it: R with no CALL of ServerOnSalvage means the key never reached the frigate; CALLs but no CHG on SalvageFull means the
-- server half stopped; a wreck that is GONE right after a dock, with a DESTROY line before it, shows what removes it (#74).
-- Object pointers are only read from the frigate and the hold (which live all raid), with bridge/salvage_crumb.txt naming the one being
-- read: a freshly made object's pointer can crash the game. Wrecks are read for numbers, flags and text only.
local PROJECT = require("pveproject")
local T = {}

local OUT = PROJECT .. "bridge/salvage.txt"
local CRUMB = PROJECT .. "bridge/salvage_crumb.txt"
local LINE_CAP = 12000
local PER_FN = 30
local HOOKS_PER_CLASS = 150
local SCAN_REACH = 1500 -- cm, the frigate's salvage scan (NOTES.md, "Missing prompts, salvage")
local WATCH_WRECKS = 6
local TYPES = { FloatProperty = true, DoubleProperty = true, IntProperty = true, Int64Property = true, UInt32Property = true,
    UInt16Property = true, ByteProperty = true, BoolProperty = true, EnumProperty = true, StrProperty = true }
local SKIP_FN = { "tick", "update", "anim", "ubergraph_" }
local KEYWORDS = { "salvage", "savage", "dock", "purge", "unload", "loot", "wreck", "onrep_" }
-- wreck = outside, salvageable from the frigate; inside = what lands in the hold; node = the level's spawner of wrecks
local KINDS = {
    { "SIGISSpaceSalvageableActor", "wreck" },
    { "SIGISSpaceSalvageableInsideActor", "inside" },
    { "SubNodeActor_SpaceSalvage_C", "node" },
}

local on, lines, registered, autoDone = false, 0, false, false
local last, hooked, hookedClasses, propsDone = {}, {}, {}, {}
local tracked, newLines, objNames, refLast, refCounts = {}, 0, {}, {}, {}
local nextAuto, nextPoll, nextSlow, hotUntil = 0, 0, 0, 0
local keyAt, keySeen, snaps = 0, 0, {}
local dockState, dockSnaps, firstSweep = nil, {}, true
local worldName, pawnClass, interior, frigate, lastReach, reachLines = nil, nil, nil, nil, nil, 0

local function valid(o)
    local ok, v = pcall(function() return o ~= nil and o:IsValid() end)
    return ok and v
end

local function put(text)
    if lines >= LINE_CAP then return end
    lines = lines + 1
    local f = io.open(OUT, "a")
    if f then
        f:write(text, "\n")
        if lines == LINE_CAP then f:write("line cap reached, logging stopped\n") end
        f:close()
    end
end

local function nameOf(o)
    local n = "?"
    pcall(function() n = o:GetFName():ToString() end)
    return n
end

local function className(o)
    local n = "?"
    pcall(function() n = o:GetClass():GetFName():ToString() end)
    return n
end

local function authority(o)
    local ok, v = pcall(function() return o:HasAuthority() end)
    return ok and tostring(v) or "?"
end

local function loc(o)
    local ok, l = pcall(function() return o:K2_GetActorLocation() end)
    if ok and l then return { X = l.X, Y = l.Y, Z = l.Z } end
    return nil
end

local function dist(a, b)
    if not (a and b) then return nil end
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function where(l) return l and ("%.0f %.0f %.0f"):format(l.X, l.Y, l.Z) or "?" end

local function ref(o) return valid(o) and (className(o) .. ":" .. nameOf(o)) or "none" end

-- Every plain value the object holds (own class and the classes above it, down to Actor): name -> text, and the names in order.
local function scalars(obj)
    local out, order = {}, {}
    pcall(function()
        local c = obj:GetClass()
        for _ = 1, 8 do
            if not valid(c) then break end
            local cn = c:GetFName():ToString()
            if cn == "Actor" or cn == "Object" then break end
            c:ForEachProperty(function(p)
                local ty, nm = "", ""
                pcall(function() ty = p:GetClass():GetFName():ToString() end)
                if TYPES[ty] then
                    pcall(function() nm = p:GetFName():ToString() end)
                    if nm ~= "" and out[nm] == nil then
                        local ok, v = pcall(function() return obj[nm] end)
                        if ok then
                            local tv = type(v)
                            if tv == "number" then out[nm] = ("%.4g"):format(v)
                            elseif tv == "boolean" or tv == "string" then out[nm] = tostring(v) end
                            if out[nm] then order[#order + 1] = nm end
                        end
                    end
                end
            end)
            c = c:GetSuperStruct()
        end
    end)
    return out, order
end

local function dumpVals(prefix, tag, vals, order)
    local parts = {}
    for _, nm in ipairs(order) do
        parts[#parts + 1] = nm .. "=" .. vals[nm]
        if #parts == 8 then
            put(("  %s %s | %s"):format(prefix, tag, table.concat(parts, " ")))
            parts = {}
        end
    end
    if #parts > 0 then put(("  %s %s | %s"):format(prefix, tag, table.concat(parts, " "))) end
end

-- First sight: all the values. After that: only what changed.
local function watch(obj, tag)
    local key = "?"
    pcall(function() key = tostring(obj:GetAddress()) end)
    local now, order = scalars(obj)
    local prev = last[key]
    if not prev then
        last[key] = { vals = now, counts = {} }
        dumpVals("ALL", tag, now, order)
        return
    end
    for _, nm in ipairs(order) do
        local was = prev.vals[nm]
        if was ~= now[nm] then
            local n = (prev.counts[nm] or 0) + 1
            prev.counts[nm] = n
            if n <= 40 then
                put(("  CHG %.2f %s %s: %s -> %s"):format(os.clock(), tag, nm, tostring(was), now[nm]))
            elseif n == 41 then
                put(("  (%s %s keeps changing: no more lines for it)"):format(tag, nm))
            end
        end
    end
    prev.vals = now
end

local function snap(tag, obj)
    if not valid(obj) then return end
    local vals, order = scalars(obj)
    put(("SNAP %.2f %s"):format(os.clock(), tag))
    dumpVals("VAL", tag, vals, order)
end

-- Every property of the class and the ones above it, with its type and where it sits in the object, once per class. The object pointer
-- ones are kept to be read (refs).
local function listProps(obj, tag)
    local ckey = "?"
    pcall(function() ckey = tostring(obj:GetClass():GetAddress()) end)
    if propsDone[ckey] then objNames[tag] = propsDone[ckey] return end
    local names = {}
    propsDone[ckey] = names
    objNames[tag] = names
    pcall(function()
        local c = obj:GetClass()
        for _ = 1, 8 do
            if not valid(c) then break end
            local cn = c:GetFName():ToString()
            if cn == "Actor" or cn == "Object" then break end
            local parts = {}
            c:ForEachProperty(function(p)
                local ty, nm, off = "?", "?", "?"
                pcall(function() ty = (p:GetClass():GetFName():ToString():gsub("Property$", "")) end)
                pcall(function() nm = p:GetFName():ToString() end)
                pcall(function() off = ("%x"):format(p:GetOffset_Internal()) end)
                parts[#parts + 1] = ("%s(%s@%s)"):format(nm, ty, off)
                if ty == "Object" then names[#names + 1] = nm end
                if #parts == 6 then
                    put(("  PROPS %s %s: %s"):format(tag, cn, table.concat(parts, " ")))
                    parts = {}
                end
            end)
            if #parts > 0 then put(("  PROPS %s %s: %s"):format(tag, cn, table.concat(parts, " "))) end
            c = c:GetSuperStruct()
        end
    end)
end

-- Which object each object pointer property of a long lived actor points at, and when that changes.
local function refs(obj, tag)
    for _, nm in ipairs(objNames[tag] or {}) do
        local cf = io.open(CRUMB, "w") -- the name being read when the game dies is the last one here
        if cf then cf:write(tag, " ", nm, "\n") cf:close() end
        local ok, v = pcall(function() return obj[nm] end)
        local text = ok and ref(v) or "unreadable"
        local key = tag .. "." .. nm
        local was = refLast[key]
        if was ~= text and not (was == nil and text == "none") then
            local n = (refCounts[key] or 0) + 1
            refCounts[key] = n
            if n <= 30 then put(("  REF %.2f %s %s: %s -> %s"):format(os.clock(), tag, nm, tostring(was or "unset"), text)) end
        end
        refLast[key] = text
    end
end

local function skipFn(l)
    for _, w in ipairs(SKIP_FN) do
        if l:find(w, 1, true) then return true end
    end
    return l:match("^get") or l:match("^is") or l:match("^can") or l:match("^has") or l:match("^k2_get")
end

local function keyword(l)
    for _, w in ipairs(KEYWORDS) do
        if l:find(w, 1, true) then return true end
    end
    return false
end

local function describe(p)
    local out = "?"
    pcall(function()
        local v = p:get()
        local tv = type(v)
        if tv == "number" or tv == "boolean" or tv == "string" then out = tostring(v)
        elseif tv == "userdata" then
            local okv, isv = pcall(function() return v:IsValid() end)
            if okv and isv then out = className(v) .. ":" .. nameOf(v)
            elseif okv then out = "null object"
            else out = "struct" end
        else out = tv end
    end)
    return out
end

-- List the functions of the object's class (and the classes above it). Blueprint classes (names ending _C): every function but the
-- per frame ones. Native classes: the ones named like salvage, dock, purge, unload, loot, wreck or OnRep_.
local function hookClass(obj, label)
    pcall(function()
        local c = obj:GetClass()
        local ckey = tostring(c:GetAddress())
        if hookedClasses[ckey] then return end
        hookedClasses[ckey] = true
        local names, budget = {}, HOOKS_PER_CLASS
        for _ = 1, 8 do
            if not valid(c) then break end
            local cn = c:GetFName():ToString()
            if cn == "Actor" or cn == "Object" then break end
            local isBp = cn:sub(-2) == "_C"
            c:ForEachFunction(function(fn)
                local fnm = fn:GetFName():ToString()
                local l = fnm:lower()
                names[#names + 1] = cn .. "::" .. fnm
                if isBp then -- where its bytecode is in memory, for tools\kdis_salvage.py (this game session only)
                    local addr
                    pcall(function() addr = math.tointeger(fn:GetAddress()) end)
                    if addr then put(("PARAMS %s::%s() @%x"):format(cn, fnm, addr)) end
                end
                if budget > 0 and ((isBp and not skipFn(l)) or (not isBp and keyword(l))) then
                    local path = fn:GetFullName():match("^%S+%s+(.+)$")
                    if path and hooked[path] == nil then
                        hooked[path] = 0
                        budget = budget - 1
                        local short = cn .. "::" .. fnm
                        local okh, err = pcall(RegisterHook, path, function(self, ...)
                            if not on then return end
                            local n = hooked[path] + 1
                            hooked[path] = n
                            hotUntil = os.clock() + 3
                            if n <= PER_FN then
                                local who = "?"
                                pcall(function() who = self:get():GetFName():ToString() end)
                                local args = {}
                                for i, a in ipairs({ ... }) do args[i] = describe(a) end
                                put(("  CALL %.2f %s #%d on %s (%s)"):format(os.clock(), short, n, who, table.concat(args, ", ")))
                            end
                        end)
                        if not okh then put("  hook failed for " .. short .. ": " .. tostring(err)) end
                    end
                end
            end)
            c = c:GetSuperStruct()
        end
        put(("FUNCS %s: %s"):format(label, table.concat(names, " ")))
    end)
end

-- The engine's own functions that make a salvage actor go away or change, written only for actors named *salvage*: this is what
-- shows who removes a wreck (issue 74, salvage gone on docking). K2_DestroyActor is also what the test menu's Remove uses.
local ENGINE = {
    { "/Script/Engine.Actor:K2_DestroyActor", "DESTROY" }, { "/Script/Engine.Actor:ReceiveEndPlay", "ENDPLAY" },
    { "/Script/Engine.Actor:SetActorHiddenInGame", "HIDDEN" }, { "/Script/Engine.Actor:K2_AttachToActor", "ATTACH" },
    { "/Script/Engine.Actor:K2_DetachFromActor", "DETACH" },
}

local function hookEngine()
    for _, e in ipairs(ENGINE) do
        local path, tag = e[1], e[2]
        if hooked[path] == nil then
            hooked[path] = 0
            local okh, err = pcall(RegisterHook, path, function(self, ...)
                if not on then return end
                local who, cls = "?", "?"
                pcall(function() local o = self:get() who = o:GetFName():ToString() cls = o:GetClass():GetFName():ToString() end)
                if not (who:lower():find("salvage", 1, true) or cls:lower():find("salvage", 1, true)) then return end
                local n = hooked[path] + 1
                hooked[path] = n
                hotUntil = os.clock() + 3
                if n <= PER_FN then
                    local args = {}
                    for i, a in ipairs({ ... }) do args[i] = describe(a) end
                    put(("  %s %.2f #%d on %s (%s) (%s)"):format(tag, os.clock(), n, who, cls, table.concat(args, ", ")))
                end
            end)
            if not okh then put("  engine hook failed for " .. path .. ": " .. tostring(err)) end
        end
    end
end

local function findInterior(pawn)
    local here = valid(pawn) and loc(pawn) or nil
    local best, bd
    for _, ins in ipairs(FindAllOf("RaidSpaceshipInside") or {}) do
        if valid(ins) then
            local ai, pair = false, nil
            pcall(function() ai = ins.IsAnAIShip == true end)
            pcall(function() pair = ins.SpaceshipToPairTo end)
            if not ai and valid(pair) then
                local d = 0
                if here then
                    local il
                    pcall(function() il = ins.InSideComp:K2_GetComponentLocation() end)
                    d = dist(here, il) or 0
                end
                if not bd or d < bd then best, bd = ins, d end
            end
        end
    end
    return best
end

-- Every salvageable actor now alive: new ones and gone ones are written, the nearest few are watched for value changes.
local function sweep(t, fl)
    local seen, list = {}, {}
    for _, k in ipairs(KINDS) do
        for _, a in ipairs(FindAllOf(k[1]) or {}) do
            if valid(a) then
                local addr = tostring(a:GetAddress())
                if not seen[addr] then
                    seen[addr] = true
                    local l = loc(a)
                    local d = dist(l, fl)
                    local e = tracked[addr]
                    if not e then
                        e = { a = a, name = nameOf(a), cls = className(a), kind = k[2], born = t, moves = 0, mloc = l, level = firstSweep }
                        tracked[addr] = e
                        newLines = newLines + 1
                        if newLines <= 60 then
                            put(("WRECK %.2f NEW %s %s (%s) %sat %s, %s from the frigate, authority=%s"):format(t, k[2], e.name, e.cls, e.level and "(in the level) " or "", where(l),
                                d and ("%.0f cm"):format(d) or "? cm", authority(a)))
                        elseif newLines == 61 then
                            put("  (more salvage actors keep appearing: no more NEW lines)")
                        end
                        hookClass(a, k[2] .. " " .. e.cls)
                    end
                    e.seen, e.l, e.d = t, l, d
                    local hidden, parent = "?", "none"
                    pcall(function() hidden = tostring(a.bHidden) end)
                    pcall(function() local p = a:GetAttachParentActor() if valid(p) then parent = ref(p) end end)
                    if e.hidden ~= nil and e.hidden ~= hidden then
                        put(("WRECK %.2f HIDE %s hidden=%s"):format(t, e.name, hidden))
                    end
                    if e.parent ~= nil and e.parent ~= parent then
                        put(("WRECK %.2f ATTACH %s parent %s -> %s"):format(t, e.name, e.parent, parent))
                    end
                    e.hidden, e.parent = hidden, parent
                    if e.mloc and l and dist(e.mloc, l) > 50 and e.moves < 40 then
                        e.moves = e.moves + 1
                        put(("WRECK %.2f MOVE %s %s -> %s"):format(t, e.name, where(e.mloc), where(l)))
                        e.mloc = l
                    end
                    list[#list + 1] = e
                end
            end
        end
    end
    for addr, e in pairs(tracked) do
        if e.seen ~= t then
            tracked[addr] = nil
            put(("WRECK %.2f GONE %s %s (%s) after %.1f s, last at %s, %s from the frigate, hidden=%s parent=%s"):format(t, e.kind, e.name, e.cls,
                t - e.born, where(e.l), e.d and ("%.0f cm"):format(e.d) or "? cm", tostring(e.hidden), tostring(e.parent)))
            snap("frigate", frigate)
            snap("hold", interior)
            hotUntil = os.clock() + 3
        end
    end
    firstSweep = false
    table.sort(list, function(a, b) return (a.d or 1e12) < (b.d or 1e12) end)
    return list
end

-- Where every salvage actor is right now, for the moments that matter (docking).
local function actorLines(t)
    for _, e in pairs(tracked) do
        local ok = valid(e.a)
        local hidden, parent = "?", "none"
        if ok then
            pcall(function() hidden = tostring(e.a.bHidden) end)
            pcall(function() local p = e.a:GetAttachParentActor() if valid(p) then parent = ref(p) end end)
        end
        put(("  ACTOR %.2f %s %s %s valid=%s at %s hidden=%s parent=%s"):format(t, e.kind, e.level and "(level)" or "(menu or pickup)", e.name, tostring(ok),
            ok and where(loc(e.a)) or "?", hidden, parent))
    end
end

local function reach(t, list)
    local nearest
    for _, e in ipairs(list) do
        if e.kind == "wreck" then nearest = e break end
    end
    local d = nearest and nearest.d
    local inScan = d and d <= SCAN_REACH
    local mark = nearest and (nearest.name .. (inScan and " IN" or " out")) or "none"
    if reachLines < 150 and (mark ~= lastReach or (d and nearest.lastD and math.abs(d - nearest.lastD) > 250)) then
        reachLines = reachLines + 1
        put(("REACH %.2f nearest wreck %s %s cm away (the scan sees %d cm)"):format(t, mark, d and ("%.0f"):format(d) or "?", SCAN_REACH))
        if nearest then nearest.lastD = d end
        lastReach = mark
    end
end

local function poll(t, pc)
    local pawn = pc.Pawn
    if t >= nextSlow then
        nextSlow = t + 1
        local wn = "?"
        pcall(function() wn = pc:GetWorld():GetFName():ToString() end)
        if wn ~= worldName then
            worldName = wn
            put(("WORLD %.2f %s"):format(t, wn))
        end
        local pcn = valid(pawn) and className(pawn) or "none"
        if pcn ~= pawnClass then
            pawnClass = pcn
            put(("PAWN %.2f you are %s"):format(t, pcn))
        end
        local ins = findInterior(pawn)
        if ins and (not valid(interior) or tostring(ins:GetAddress()) ~= tostring(interior:GetAddress())) then
            interior = ins
            local pair
            pcall(function() pair = ins.SpaceshipToPairTo end)
            frigate = valid(pair) and pair or nil
            local fl = frigate and loc(frigate)
            put(("SHIP %.2f hold %s (%s) authority=%s | frigate %s (%s) at %s authority=%s"):format(t, nameOf(ins), className(ins),
                authority(ins), frigate and nameOf(frigate) or "none", frigate and className(frigate) or "?", where(fl),
                frigate and authority(frigate) or "?"))
            hookClass(ins, "hold " .. className(ins))
            listProps(ins, "hold")
            if frigate then
                hookClass(frigate, "frigate " .. className(frigate))
                listProps(frigate, "frigate")
            end
            hookEngine()
        end
        if valid(interior) then refs(interior, "hold") end
        if valid(frigate) then refs(frigate, "frigate") end
        local fl = valid(frigate) and loc(frigate) or nil
        local list = sweep(t, fl)
        reach(t, list)
        for i = #list, 1, -1 do list[i].watch = i <= WATCH_WRECKS end
    end
    if valid(interior) then watch(interior, "hold") end
    if valid(frigate) then watch(frigate, "frigate") end
    for _, e in pairs(tracked) do
        if e.watch and e.seen and valid(e.a) then
            if e.fresh then watch(e.a, e.kind .. " " .. e.name) else e.fresh = true end
        end
    end
    if valid(interior) then
        local ok, docked = pcall(function() return interior.is_Currently_Docked end)
        if ok and docked ~= nil and docked ~= dockState then
            if dockState ~= nil then
                put(("DOCK %.2f hold is_Currently_Docked=%s, SalvageFull=%s"):format(t, tostring(docked), tostring(interior.SalvageFull)))
                actorLines(t)
                dockSnaps = { t + 0.5, t + 3.0, t + 10.0 }
                hotUntil = t + 12
            end
            dockState = docked
        end
    end
    if dockSnaps[1] and t >= dockSnaps[1] then
        table.remove(dockSnaps, 1)
        snap("frigate", frigate)
        snap("hold", interior)
        actorLines(t)
    end
    if keyAt ~= keySeen then
        keySeen = keyAt
        local nearest
        for _, e in pairs(tracked) do
            if e.kind == "wreck" and (not nearest or (e.d or 1e12) < (nearest.d or 1e12)) then nearest = e end
        end
        put(("KEY %.2f R pressed. Nearest wreck: %s, %s cm away; hold SalvageFull=%s"):format(keyAt,
            nearest and nearest.name or "none", nearest and nearest.d and ("%.0f"):format(nearest.d) or "?",
            valid(interior) and tostring(interior.SalvageFull) or "?"))
        snaps = { keyAt + 0.5, keyAt + 3.0 }
        hotUntil = keyAt + 4
    end
    if snaps[1] and t >= snaps[1] then
        table.remove(snaps, 1)
        snap("frigate", frigate)
        snap("hold", interior)
    end
end

function T.tick(_, pc)
    if not pc then return end
    local t = os.clock()
    if not on then
        -- Not switched on from F9? It switches itself on the first time you are in a ship with a hold (once per game session).
        if autoDone or t < nextAuto then return end
        nextAuto = t + 1
        local ok, found = pcall(function() return findInterior(pc.Pawn) ~= nil end)
        if ok and found then
            autoDone = true
            print("[PvEDirector] salvage log: you are in a ship, switching the log on by itself\n")
            T.toggle()
        end
        return
    end
    if t < nextPoll then return end
    nextPoll = t + (t < hotUntil and 0.1 or 0.25)
    local ok, err = pcall(poll, t, pc)
    if not ok then put("  poll error: " .. tostring(err)) end
end

local function faceTo(from, to)
    local dx, dy, dz = to.X - from.X, to.Y - from.Y, to.Z - from.Z
    return { Pitch = math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy))), Yaw = math.deg(math.atan(dy, dx)), Roll = 0 }
end

-- Puts the ship at `to`, facing `rot`, and checks where it ended up: K2_TeleportTo says yes while a blocked spot leaves the ship where it was
-- (it checks for overlaps, and a docking arm is full of geometry), so the plain set with teleport on goes first.
local function moveShip(to, rot)
    local tries = {
        { "SetActorLocationAndRotation", function() return frigate:K2_SetActorLocationAndRotation(to, rot, false, {}, true) end },
        { "TeleportTo", function() return frigate:K2_TeleportTo(to, rot) end },
    }
    local notes = {}
    for _, t in ipairs(tries) do
        local ok, r = pcall(t[2])
        local off = dist(loc(frigate), to)
        notes[#notes + 1] = ("%s returned %s, ship %s cm from the spot"):format(t[1], ok and tostring(r) or ("error " .. tostring(r)),
            off and ("%.0f"):format(off) or "?")
        if off and off < 100 then return true, table.concat(notes, "; ") end
    end
    return false, table.concat(notes, "; ")
end

-- Flies your ship to the nearest wreck that was in the level (made by the game's own node, not by this menu), 8 m from it and facing it
-- (the frigate's salvage scan is a trace from its nose), so a wreck the game made can be taken aboard: compare it with the menu's.
function T.gotoWreck()
    if not valid(frigate) then return "No ship found yet (the log starts when you are in one)" end
    local best
    for _, e in pairs(tracked) do
        if e.kind == "wreck" and e.level and valid(e.a) and e.l and (not best or (e.d or 1e12) < (best.d or 1e12)) then best = e end
    end
    if not best then return "No level wreck left in this map" end
    local here = loc(frigate)
    local dx, dy, dz = here.X - best.l.X, here.Y - best.l.Y, here.Z - best.l.Z
    local len = math.sqrt(dx * dx + dy * dy + dz * dz)
    if len < 1 then dx, dy, dz, len = 1, 0, 0, 1 end
    local to = { X = best.l.X + dx / len * 800, Y = best.l.Y + dy / len * 800, Z = best.l.Z + dz / len * 800 }
    local ok, how = moveShip(to, faceTo(to, best.l))
    put(("MENU %.2f ship to the level wreck %s at %s (spot %s): %s | %s"):format(os.clock(), best.name, where(best.l), where(to),
        ok and "moved" or "DID NOT MOVE", how))
    if not ok then return "The ship did not move: see salvage.txt" end
    return ("Ship moved 8 m from %s: press R"):format(best.cls)
end

-- Flies your ship to the nearest docking area that looks usable, 20 m out on the side you are on, facing it: fly in and the ship docks by
-- itself. Every dock of the map is written to the log (DOCKS) with the values it holds, so "usable" can be checked against them.
local BUSY = { "occup", "inuse", "busy", "isdocked", "bdocked", "locked", "disabled" }

function T.gotoDock()
    if not valid(frigate) then return "No ship found yet (the log starts when you are in one)" end
    local here = loc(frigate)
    local best, bd, fallback, fd
    for _, c in ipairs(FindAllOf("RaidDockingComponent") or {}) do
        if valid(c) then
            local at, owner
            pcall(function() at = c:K2_GetComponentLocation() end)
            pcall(function() owner = c:GetOwner() end)
            local d = dist(here, at and { X = at.X, Y = at.Y, Z = at.Z })
            local vals, order = scalars(c)
            local busy
            for _, nm in ipairs(order) do
                if vals[nm] == "true" then
                    for _, w in ipairs(BUSY) do
                        if nm:lower():find(w, 1, true) then busy = nm end
                    end
                end
            end
            put(("DOCKS %.2f %s of %s at %s, %s cm from the ship, looks busy: %s"):format(os.clock(), nameOf(c), ref(owner), where(at),
                d and ("%.0f"):format(d) or "?", tostring(busy)))
            dumpVals("ALL", "dock " .. nameOf(c), vals, order)
            if d then
                local e = { c = c, at = { X = at.X, Y = at.Y, Z = at.Z }, name = ref(owner) }
                if not busy and (not bd or d < bd) then best, bd = e, d end
                if not fallback or d < fd then fallback, fd = e, d end
            end
        end
    end
    local pick = best or fallback
    if not pick then return "No docking area found in this map" end
    local fx, fy, fz = pick.at.X - here.X, pick.at.Y - here.Y, pick.at.Z - here.Z -- from the ship to the dock
    local f
    pcall(function() local v = pick.c:GetForwardVector() f = { X = v.X, Y = v.Y, Z = v.Z } end)
    if not f then
        local len = math.sqrt(fx * fx + fy * fy + fz * fz)
        f = { X = -fx / len, Y = -fy / len, Z = -fz / len }
    elseif f.X * fx + f.Y * fy + f.Z * fz > 0 then -- the dock's forward points away from you: use the side you are on
        f = { X = -f.X, Y = -f.Y, Z = -f.Z }
    end
    local to = { X = pick.at.X + f.X * 2000, Y = pick.at.Y + f.Y * 2000, Z = pick.at.Z + f.Z * 2000 }
    local ok, how = moveShip(to, faceTo(to, pick.at))
    put(("MENU %.2f ship to the dock %s at %s (spot %s): %s | %s%s"):format(os.clock(), pick.name, where(pick.at), where(to),
        ok and "moved" or "DID NOT MOVE", how, best and "" or " (every dock looked busy: nearest used)"))
    if not ok then return "The ship did not move: see salvage.txt" end
    return ("Ship moved 20 m from %s: fly in to dock"):format(pick.name)
end

function T.note(text) if on then put(("MENU %.2f %s"):format(os.clock(), text)) end end

function T.label() return "Log salvage: " .. (on and "ON" or "off") end

function T.toggle()
    if on then
        on = false
        autoDone = true
        put("-- off. How many times each hooked function ran (the first " .. PER_FN .. " are written in full):")
        local keys = {}
        for k, n in pairs(hooked) do
            if n > 0 then keys[#keys + 1] = k end
        end
        table.sort(keys)
        for _, k in ipairs(keys) do put(("  %d x %s"):format(hooked[k], k)) end
        print("[PvEDirector] salvage log off\n")
        return "Salvage log off"
    end
    on = true
    lines, last, tracked, newLines, objNames, refLast, refCounts, snaps = 0, {}, {}, 0, {}, {}, {}, {}
    interior, frigate, worldName, pawnClass, lastReach, reachLines = nil, nil, nil, nil, nil, 0
    dockState, dockSnaps, firstSweep = nil, {}, true
    local f, why = io.open(OUT, "w")
    if f then
        f:write("-- salvage log on (test install). Fly to a wreck, press R, look at the hold, loot or purge, dock. Read the top of salvagewatch.lua for the line kinds.\n")
        f:close()
    else
        print("[PvEDirector] salvage log: could not open " .. OUT .. ": " .. tostring(why) .. "\n")
    end
    if not registered then
        registered = true
        local ok, err = pcall(RegisterKeyBind, Key.R, function() keyAt = os.clock() end)
        if not ok then put("-- could not watch the R key: " .. tostring(err)) end
    end
    print("[PvEDirector] salvage log on: " .. OUT .. "\n")
    return "Salvage log on: bridge\\salvage.txt"
end

return T
