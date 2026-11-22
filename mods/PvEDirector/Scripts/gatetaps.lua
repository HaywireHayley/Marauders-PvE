-- Gate superstitions, first pass (#332; docs/lore/fragments/18_gate_superstitions.md, rule 2): "Tap the JTA plate twice
-- on the way out. Once is rude, three's greedy." Taps are presses of Space (the helm boost key, shipspeed.lua calls
-- M.tap on each press at the helm) in the TAP_WINDOW seconds before your ship enters the gate's evac volume (loadout.lua
-- calls M.enter from the same hook that marks the ship as in a gate). Exactly two: a GoldCoin into the gift box
-- (gifts_in.txt, the hand-off defuse.lua uses; claimed in the lobby). One, or three and more: a line on the HUD, no
-- reward. At most one judgement per raid (M.reset, from ShipSpeed.reset), so leaving and re-entering can't farm it.
local M = {}
local log, valid

local CFG = {
    GATE_TAPS = 1,         -- 1 = on, 0 = off (F3 Effects)
    TAP_WINDOW = 6,        -- seconds before the gate that a Space press counts as a tap
    TAP_GIFT = "GoldCoin", -- item row for exactly two taps
}
M.CFG = CFG

local taps = {}    -- os.clock of each recent press
local done = false -- this raid's gate has been judged

function M.init(ctx) log, valid = ctx.log, ctx.valid end

function M.tap()
    local now = os.clock()
    taps[#taps + 1] = now
    while #taps > 0 and now - taps[1] > 30 do table.remove(taps, 1) end
end

function M.reset() taps, done = {}, false end

local function say(pc, msg)
    pcall(function() pc:ClientMessage(msg, FName("Event"), 5.0) end)
end

local function gift(row)
    return pcall(function()
        local f = assert(io.open(require("pvebackend") .. "gifts_in.txt", "a"))
        f:write(row, "\n")
        f:close()
    end)
end

-- pc: the local controller that just entered the gate's evac volume.
function M.enter(pc)
    if CFG.GATE_TAPS == 0 or done or not valid(pc) then return end
    done = true
    local now, n = os.clock(), 0
    for _, t in ipairs(taps) do
        if now - t <= CFG.TAP_WINDOW then n = n + 1 end
    end
    taps = {}
    if n == 2 then
        local ok = gift(CFG.TAP_GIFT)
        say(pc, ok and "Twice. The gate approves. Something is waiting in your gift box." or "Twice. The gate approves.")
    elseif n == 1 then
        say(pc, "Once is rude.")
    elseif n >= 3 then
        say(pc, "Three's greedy.")
    else
        say(pc, "You go through without a word.")
    end
    if log then
        log(("gate taps: %d in the last %d s%s"):format(n, CFG.TAP_WINDOW, n == 2 and (" -> " .. CFG.TAP_GIFT .. " gift") or ""))
    end
end

return M
