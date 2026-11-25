-- Impact sound cap (issue: a shotgun's boom cuts out after the first shot). Every pellet that lands makes an impact actor with its own
-- sound (SFX_Bullet_Impact_*, about 0.8 s), and a shotgun lands about 10 per shot, three shots a second: roughly 25 impact sounds
-- playing at once on top of the muzzle boom, a 2.3 s sound. The audio engine plays a fixed number of sounds at once (32 by default);
-- over that it stops the quietest, which is the long boom. A rifle makes one impact per shot and never gets there. Offline the pool of
-- impact actors does not hand them back either (their return timer is client code), so the live count only climbs while you shoot.
--
-- The game gives its impact sounds one shared limit, BaseHitSoundConcurrency (20 at once, stop the farthest then the oldest). This
-- lowers that number, so the impacts stop each other long before they take the boom's place. Measured 2026-11-24 in Spaceport_01 against
-- a tunnel wall with the Liberator: boom clipped from the second shot with 20, never with 6; the impacts still sound like a shotgun
-- hitting concrete, the pellets land together anyway.
--   IMPACT_VOICES   impact sounds that may play at once. 0 = the game's own 20.
-- Read a property every EVERY seconds and written only when it differs: the asset is loaded with the raid, so it is looked up until
-- found, and a new raid that reloads it is caught on the next pass.
local M = {}
local CFG = { IMPACT_VOICES = 6 }
M.CFG = CFG

local PATH = "/Game/Blueprints/Weapons/PooledEffects/BaseHitSoundConcurrency.BaseHitSoundConcurrency"
local STOCK = 20 -- the game's own limit
local EVERY = 2

local X -- log, valid
local nextAt, last = 0, nil

local function apply()
    local c = StaticFindObject(PATH)
    if not (c and c:IsValid()) then return end
    local want = math.floor(CFG.IMPACT_VOICES or 0)
    if want <= 0 then want = STOCK end
    local cur = c.Concurrency.MaxCount
    if cur ~= want then
        c.Concurrency.MaxCount = want
        if last ~= want then
            last = want
            X.log(("impact sounds: at most %d at once (the game's own %d), so a shotgun's impacts stop cutting its boom"):format(want, STOCK))
        end
    end
end

-- From the director's per-frame tick.
function M.frame(pc)
    local now = os.clock()
    if now < nextAt then return end
    nextAt = now + EVERY
    apply()
end

function M.init(ctx) X = ctx end
function M.reset() nextAt, last = 0, nil end

return M
