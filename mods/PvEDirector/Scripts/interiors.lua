-- Station and ship interiors seen from open space.
--
-- Raid interiors are always-loaded sublevels at their real coordinates, out in the same space you fly through, each
-- marked by a LevelStreamingVolume. Two kinds of their meshes show from far away:
--   * the black shell (huge thin Cube meshes, M_FullyBlack) wrapped round each one: flat black plates in the sky;
--   * the interior itself: most of its meshes cull within 100 m, but a few hundred never cull (floors, pillars, roofs,
--     big walls) and up to ~9000 more draw out to 300 m. Once the shells were hidden (2026-11-06) these were what hung
--     in the sky: whole station floors and pillars floating in space (user report 2026-11-13, a Space raid).
-- So while the camera is outside a volume (+ CAMERA_MARGIN) both are hidden; collision stays (SetVisibility only).
-- Coming in (usually an airlock transfer, a jump across the map) everything is shown at once, a ~70 ms step the
-- transfer covers; going out it's hidden HIDE_PER_FRAME at a time. Collected once per raid under the loading veil.
local Out = require("outref")
local I = {}

local SHELL_MIN_SCALE = 10      -- a shell piece: the Cube mesh (100 units wide) scaled to 1000+ units along an axis
local MARGIN = 3000             -- a location's pieces can sit this far outside its volume
local CAMERA_MARGIN = 1500      -- shown this far before the camera reaches the volume
local FAR_DRAW = 10000          -- interior meshes drawn farther than this (or never culled) are hidden from outside
local HIDE_PER_FRAME = 1000     -- ~8 ms of SetVisibility calls

local X -- { log, valid }

function I.init(ctx) X = ctx end

local function inBox(p, s, margin)
    return math.abs(p.X - s.at.X) <= s.ext.X + margin and math.abs(p.Y - s.at.Y) <= s.ext.Y + margin
        and math.abs(p.Z - s.at.Z) <= s.ext.Z + margin
end

-- Every location: its shell pieces and its far-drawn interior meshes (those drawn now: collision-only meshes and
-- anything the level hides itself stay hidden). The space map's own level is left alone except for shell cubes.
local function collect(world)
    local valid = X.valid
    local own = world:GetFullName():match("(/Game/[^ ]+)$") or "?" -- "/Game/Maps/Space_Solo_01.Space_Solo_01"
    local locs = {}
    for _, v in ipairs(FindAllOf("LevelStreamingVolume") or {}) do
        if valid(v) then
            local at, ext = {}, {}
            Out.call(v, "GetActorBounds", false, at, ext, false)
            locs[#locs + 1] = { name = v:GetFName():ToString():gsub("^LevelStreamingVolume_", ""),
                at = { X = at.X, Y = at.Y, Z = at.Z }, ext = { X = ext.X, Y = ext.Y, Z = ext.Z }, parts = {}, shown = true }
        end
    end
    local shells, far = 0, 0
    for _, c in ipairs(FindAllOf("StaticMeshComponent") or {}) do
        local mesh = valid(c) and c.StaticMesh
        if mesh and valid(mesh) then
            local at = c:K2_GetComponentLocation()
            local loc
            for _, s in ipairs(locs) do
                if inBox(at, s, MARGIN) then loc = s break end
            end
            -- a mesh of some other level here: this location's interior is on the map this run
            if loc and not c:GetFullName():find(own .. ":", 1, true) then loc.foreign = (loc.foreign or 0) + 1 end
            if mesh:GetFName():ToString() == "Cube" then
                local scale = c:K2_GetComponentScale()
                if math.max(math.abs(scale.X), math.abs(scale.Y), math.abs(scale.Z)) >= SHELL_MIN_SCALE then
                    -- matched on the floor plan too: Rebel Base's lid (a 350x scale cube) sits 20000 above its volume
                    if not loc then
                        for _, s in ipairs(locs) do
                            if inBox({ X = at.X, Y = at.Y, Z = s.at.Z }, s, MARGIN) then loc = s break end
                        end
                    end
                    if loc then
                        loc.parts[#loc.parts + 1] = c
                        shells = shells + 1
                    end
                    loc = nil
                end
            end
            if loc then
                local md = c.CachedMaxDrawDistance or 0
                if (md == 0 or md > FAR_DRAW) and c:IsVisible()
                    and not c:GetFullName():find(own .. ":", 1, true) then
                    loc.parts[#loc.parts + 1] = c
                    far = far + 1
                end
            end
        end
    end
    -- A station that isn't on this run's map (Space_Solo_02 picks its stations per run) still has its airlock chambers
    -- at its spot: StationAirlockDockingAreaAbility_* (RaidFrigateStationDock) belong to the space map's own level, so
    -- they hung in empty space as dark boxes and slabs (issue #9). Hidden for the raid, collision off.
    local orphans = 0
    for _, a in ipairs(FindAllOf("RaidFrigateStationDock") or {}) do
        if valid(a) then
            local at = a:K2_GetActorLocation()
            for _, s in ipairs(locs) do
                if (s.foreign or 0) == 0 and inBox(at, s, MARGIN) then
                    a:SetActorHiddenInGame(true)
                    a:SetActorEnableCollision(false)
                    s.orphans = (s.orphans or 0) + 1
                    orphans = orphans + 1
                    break
                end
            end
        end
    end
    local names = {}
    for _, s in ipairs(locs) do
        names[#names + 1] = ("%s %d%s"):format(s.name, #s.parts, s.orphans and (", not here: " .. s.orphans .. " airlocks hidden") or "")
    end
    X.log(("interiors: %d shell pieces and %d far-drawn interior meshes hidden from space, %d airlocks of absent stations (%s)")
        :format(shells, far, orphans, table.concat(names, ", ")))
    return locs
end

-- Each update (state lives in the raid table): collects once.
function I.update(pc, raid, world)
    if not raid.interiors then raid.interiors = collect(world) end
    I.frame(pc, raid)
end

-- Every frame: show a location the moment the camera is in it, hide the rest a slice at a time.
function I.frame(pc, raid)
    local locs = raid.interiors
    if not locs then return end
    local cam = pc.PlayerCameraManager:GetCameraLocation()
    local budget = HIDE_PER_FRAME
    for _, s in ipairs(locs) do
        local want = inBox(cam, s, CAMERA_MARGIN)
        if want and (not s.shown or s.hiding) then -- (back before it was all hidden: show it all again)
            -- valid(): a part's level can be unloaded mid-raid (a streamed sublevel), and its components go with it
            for _, c in ipairs(s.parts) do if X.valid(c) then c:SetVisibility(true, false) end end
            s.shown, s.hiding = true, nil
        elseif not want and s.shown and budget > 0 then
            local i = s.hiding or 1
            local last = math.min(#s.parts, i + budget - 1)
            for k = i, last do
                local c = s.parts[k]
                if X.valid(c) then c:SetVisibility(false, false) end
            end
            budget = budget - (last - i + 1)
            if last >= #s.parts then s.shown, s.hiding = false, nil else s.hiding = last + 1 end
        end
    end
end

return I
