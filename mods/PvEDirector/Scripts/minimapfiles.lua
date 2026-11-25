-- The minimap's floor plans on disk (assets/minimap/<place>.png and .txt): reading their size, and writing a scanned
-- floor as a PNG. Moved out of minimap.lua (1600+ lines), which keeps the scanning, layout and drawing.
local PROJECT = require("pveproject")
local M = {}
local DIR = PROJECT .. "assets/minimap/"
M.DIR = DIR

function M.planPath(p) return DIR .. p.key .. ".png" end

function M.readPlan(p)
    local f = io.open(DIR .. p.key .. ".txt", "r")
    if not f then return false end
    local w, h = f:read("n", "n")
    f:close()
    if not w or not h then return false end
    p.plan = { w = w, h = h }
    return true
end

-- Lua has no image writer and ImportFileAsTexture2D reads PNG (not BMP), so this is a PNG with its data stored uncompressed.
local crcTable
local function crc32(data)
    if not crcTable then
        crcTable = {}
        for i = 0, 255 do
            local c = i
            for _ = 1, 8 do c = c & 1 == 1 and 0xEDB88320 ~ (c >> 1) or c >> 1 end
            crcTable[i] = c
        end
    end
    local c = 0xFFFFFFFF
    for i = 1, #data do c = crcTable[(c ~ data:byte(i)) & 255] ~ (c >> 8) end
    return c ~ 0xFFFFFFFF
end

local function adler32(data)
    local a, b = 1, 0
    for i = 1, #data do
        a = (a + data:byte(i)) % 65521
        b = (b + a) % 65521
    end
    return b << 16 | a
end

local function pngChunk(kind, data)
    return string.pack(">I4", #data) .. kind .. data .. string.pack(">I4", crc32(kind .. data))
end

local function encodePng(w, h, raw)
    local parts = { string.char(0x78, 0x01) } -- zlib header, then stored blocks
    local at, size = 1, #raw
    while at <= size do
        local n = math.min(65535, size - at + 1)
        parts[#parts + 1] = string.pack("<BI2I2", at + n > size and 1 or 0, n, ~n & 0xFFFF)
        parts[#parts + 1] = raw:sub(at, at + n - 1)
        at = at + n
    end
    parts[#parts + 1] = string.pack(">I4", adler32(raw))
    return string.char(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A) .. pngChunk("IHDR", string.pack(">I4I4BBBBB", w, h, 8, 6, 0, 0, 0))
        .. pngChunk("IDAT", table.concat(parts)) .. pngChunk("IEND", "")
end

-- Top of the image = +X, right = +Y. Off the floor is transparent.
function M.writePlan(p, scan)
    local w, h, cells = scan.w, scan.h, scan.cells
    local lo, hi = scan.lo, scan.hi
    if hi <= lo then hi = lo + 1 end
    local rows = {}
    for y = 0, h - 1 do
        local row = { string.char(0) } -- PNG filter byte: none
        for x = 0, w - 1 do
            local z = cells[y * w + x]
            local px = string.char(0, 0, 0, 0)
            if z then
                local edge = not (cells[y * w + x - 1] and cells[y * w + x + 1] and cells[(y - 1) * w + x] and cells[(y + 1) * w + x])
                local lift = (z - lo) / (hi - lo)
                if edge then px = string.char(150, 185, 205, 255)
                else px = string.char(48 + math.floor(lift * 40), 66 + math.floor(lift * 48), 84 + math.floor(lift * 56), 255) end
            end
            row[#row + 1] = px
        end
        rows[#rows + 1] = table.concat(row)
    end
    local f = io.open(M.planPath(p), "wb")
    if not f then return false end
    f:write(encodePng(w, h, table.concat(rows)))
    f:close()
    f = io.open(DIR .. p.key .. ".txt", "w")
    if f then
        f:write(w, " ", h, "\n")
        f:close()
    end
    p.plan = { w = w, h = h }
    return true
end

return M
