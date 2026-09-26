-- sha512.lua — pure-arithmetic SHA-512 (FIPS 180-4) for the DCS Mission Editor.
--
-- The ME runs PUC Lua 5.1: no `bit`/`bit32`, no 64-bit integers. Every 64-bit
-- word is a (hi, lo) pair of 32-bit values held in doubles, and XOR/AND work a
-- byte at a time through 256x256 lookup tables built on first use. Slow next
-- to native code, but ed25519.lua only hashes a few hundred bytes per
-- signature, so it doesn't matter.
--
--   M.digest(msg) -> 64-byte binary string
--   M.hex(msg)    -> 128-char lowercase hex

local M = {}

local floor = math.floor
local P32 = 4294967296

-- 8-bit XOR / AND tables, index a * 256 + b. Built lazily (65536 entries each).
local X8, A8
local function build_tables()
    X8, A8 = {}, {}
    local x4, a4 = {}, {}
    for a = 0, 15 do
        for b = 0, 15 do
            local x, n, p, aa, bb = 0, 0, 1, a, b
            for _ = 1, 4 do
                local ab, bbit = aa % 2, bb % 2
                if ab ~= bbit then x = x + p end
                if ab == 1 and bbit == 1 then n = n + p end
                aa = (aa - ab) / 2; bb = (bb - bbit) / 2; p = p * 2
            end
            x4[a * 16 + b] = x; a4[a * 16 + b] = n
        end
    end
    for a = 0, 255 do
        local ah, al = floor(a / 16), a % 16
        for b = 0, 255 do
            local bh, bl = floor(b / 16), b % 16
            X8[a * 256 + b] = x4[ah * 16 + bh] * 16 + x4[al * 16 + bl]
            A8[a * 256 + b] = a4[ah * 16 + bh] * 16 + a4[al * 16 + bl]
        end
    end
end

-- 32-bit bitwise ops on non-negative integers < 2^32.
local function op32(t, a, b)
    local r, m = 0, 1
    for _ = 1, 4 do
        local ab, bb = a % 256, b % 256
        r = r + t[ab * 256 + bb] * m
        a = (a - ab) / 256; b = (b - bb) / 256; m = m * 256
    end
    return r
end
local function xor32(a, b) return op32(X8, a, b) end
local function and32(a, b) return op32(A8, a, b) end
local function not32(a) return P32 - 1 - a end

-- 64-bit rotate right / shift right by n (0 < n < 64) on (hi, lo).
local function rotr(hi, lo, n)
    if n >= 32 then hi, lo = lo, hi; n = n - 32 end
    if n == 0 then return hi, lo end
    local d, u = 2 ^ n, 2 ^ (32 - n)
    return floor(hi / d) + (lo % d) * u, floor(lo / d) + (hi % d) * u
end
local function shr(hi, lo, n)   -- n < 32
    local d, u = 2 ^ n, 2 ^ (32 - n)
    return floor(hi / d), floor(lo / d) + (hi % d) * u
end

local K = {
    0x428a2f98, 0xd728ae22, 0x71374491, 0x23ef65cd,
    0xb5c0fbcf, 0xec4d3b2f, 0xe9b5dba5, 0x8189dbbc,
    0x3956c25b, 0xf348b538, 0x59f111f1, 0xb605d019,
    0x923f82a4, 0xaf194f9b, 0xab1c5ed5, 0xda6d8118,
    0xd807aa98, 0xa3030242, 0x12835b01, 0x45706fbe,
    0x243185be, 0x4ee4b28c, 0x550c7dc3, 0xd5ffb4e2,
    0x72be5d74, 0xf27b896f, 0x80deb1fe, 0x3b1696b1,
    0x9bdc06a7, 0x25c71235, 0xc19bf174, 0xcf692694,
    0xe49b69c1, 0x9ef14ad2, 0xefbe4786, 0x384f25e3,
    0x0fc19dc6, 0x8b8cd5b5, 0x240ca1cc, 0x77ac9c65,
    0x2de92c6f, 0x592b0275, 0x4a7484aa, 0x6ea6e483,
    0x5cb0a9dc, 0xbd41fbd4, 0x76f988da, 0x831153b5,
    0x983e5152, 0xee66dfab, 0xa831c66d, 0x2db43210,
    0xb00327c8, 0x98fb213f, 0xbf597fc7, 0xbeef0ee4,
    0xc6e00bf3, 0x3da88fc2, 0xd5a79147, 0x930aa725,
    0x06ca6351, 0xe003826f, 0x14292967, 0x0a0e6e70,
    0x27b70a85, 0x46d22ffc, 0x2e1b2138, 0x5c26c926,
    0x4d2c6dfc, 0x5ac42aed, 0x53380d13, 0x9d95b3df,
    0x650a7354, 0x8baf63de, 0x766a0abb, 0x3c77b2a8,
    0x81c2c92e, 0x47edaee6, 0x92722c85, 0x1482353b,
    0xa2bfe8a1, 0x4cf10364, 0xa81a664b, 0xbc423001,
    0xc24b8b70, 0xd0f89791, 0xc76c51a3, 0x0654be30,
    0xd192e819, 0xd6ef5218, 0xd6990624, 0x5565a910,
    0xf40e3585, 0x5771202a, 0x106aa070, 0x32bbd1b8,
    0x19a4c116, 0xb8d2d0c8, 0x1e376c08, 0x5141ab53,
    0x2748774c, 0xdf8eeb99, 0x34b0bcb5, 0xe19b48a8,
    0x391c0cb3, 0xc5c95a63, 0x4ed8aa4a, 0xe3418acb,
    0x5b9cca4f, 0x7763e373, 0x682e6ff3, 0xd6b2b8a3,
    0x748f82ee, 0x5defb2fc, 0x78a5636f, 0x43172f60,
    0x84c87814, 0xa1f0ab72, 0x8cc70208, 0x1a6439ec,
    0x90befffa, 0x23631e28, 0xa4506ceb, 0xde82bde9,
    0xbef9a3f7, 0xb2c67915, 0xc67178f2, 0xe372532b,
    0xca273ece, 0xea26619c, 0xd186b8c7, 0x21c0c207,
    0xeada7dd6, 0xcde0eb1e, 0xf57d4f7f, 0xee6ed178,
    0x06f067aa, 0x72176fba, 0x0a637dc5, 0xa2c898a6,
    0x113f9804, 0xbef90dae, 0x1b710b35, 0x131c471b,
    0x28db77f5, 0x23047d84, 0x32caab7b, 0x40c72493,
    0x3c9ebe0a, 0x15c9bebc, 0x431d67c4, 0x9c100d4c,
    0x4cc5d4be, 0xcb3e42b6, 0x597f299c, 0xfc657e2a,
    0x5fcb6fab, 0x3ad6faec, 0x6c44198c, 0x4a475817,
}

local IV = {
    0x6a09e667, 0xf3bcc908, 0xbb67ae85, 0x84caa73b,
    0x3c6ef372, 0xfe94f82b, 0xa54ff53a, 0x5f1d36f1,
    0x510e527f, 0xade682d1, 0x9b05688c, 0x2b3e6c1f,
    0x1f83d9ab, 0xfb41bd6b, 0x5be0cd19, 0x137e2179,
}

-- Read the 32-bit big-endian word at 1-based byte offset i of string s.
local function be32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
end

local function put32(v)
    local d = v % 256; v = (v - d) / 256
    local c = v % 256; v = (v - c) / 256
    local b = v % 256; local a = (v - b) / 256
    return string.char(a, b, c, d)
end

local Wh, Wl = {}, {}

local function block(h, s, off)
    for t = 1, 16 do
        Wh[t] = be32(s, off + (t - 1) * 8)
        Wl[t] = be32(s, off + (t - 1) * 8 + 4)
    end
    for t = 17, 80 do
        -- s0 = rotr1 ^ rotr8 ^ shr7 of W[t-15]; s1 = rotr19 ^ rotr61 ^ shr6 of W[t-2]
        local ah, al = rotr(Wh[t - 15], Wl[t - 15], 1)
        local bh, bl = rotr(Wh[t - 15], Wl[t - 15], 8)
        local ch, cl = shr(Wh[t - 15], Wl[t - 15], 7)
        local s0h, s0l = xor32(xor32(ah, bh), ch), xor32(xor32(al, bl), cl)
        ah, al = rotr(Wh[t - 2], Wl[t - 2], 19)
        bh, bl = rotr(Wh[t - 2], Wl[t - 2], 61)
        ch, cl = shr(Wh[t - 2], Wl[t - 2], 6)
        local s1h, s1l = xor32(xor32(ah, bh), ch), xor32(xor32(al, bl), cl)
        local lo = Wl[t - 16] + s0l + Wl[t - 7] + s1l
        local carry = floor(lo / P32)
        Wl[t] = lo - carry * P32
        Wh[t] = (Wh[t - 16] + s0h + Wh[t - 7] + s1h + carry) % P32
    end

    local ah, al, bh, bl, chh, cl, dh, dl = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
    local eh, el, fh, fl, gh, gl, hh, hl = h[9], h[10], h[11], h[12], h[13], h[14], h[15], h[16]
    for t = 1, 80 do
        -- S1 = rotr14 ^ rotr18 ^ rotr41 of e; ch = (e & f) ^ (~e & g)
        local r1h, r1l = rotr(eh, el, 14)
        local r2h, r2l = rotr(eh, el, 18)
        local r3h, r3l = rotr(eh, el, 41)
        local S1h, S1l = xor32(xor32(r1h, r2h), r3h), xor32(xor32(r1l, r2l), r3l)
        local cHh = xor32(and32(eh, fh), and32(not32(eh), gh))
        local cHl = xor32(and32(el, fl), and32(not32(el), gl))
        local lo = hl + S1l + cHl + K[2 * t] + Wl[t]
        local carry = floor(lo / P32)
        local t1l = lo - carry * P32
        local t1h = (hh + S1h + cHh + K[2 * t - 1] + Wh[t] + carry) % P32
        -- S0 = rotr28 ^ rotr34 ^ rotr39 of a; maj = (a & b) ^ (a & c) ^ (b & c)
        r1h, r1l = rotr(ah, al, 28)
        r2h, r2l = rotr(ah, al, 34)
        r3h, r3l = rotr(ah, al, 39)
        local S0h, S0l = xor32(xor32(r1h, r2h), r3h), xor32(xor32(r1l, r2l), r3l)
        local mjh = xor32(xor32(and32(ah, bh), and32(ah, chh)), and32(bh, chh))
        local mjl = xor32(xor32(and32(al, bl), and32(al, cl)), and32(bl, cl))
        lo = S0l + mjl
        carry = floor(lo / P32)
        local t2l = lo - carry * P32
        local t2h = (S0h + mjh + carry) % P32

        hh, hl, gh, gl, fh, fl = gh, gl, fh, fl, eh, el
        lo = dl + t1l; carry = floor(lo / P32)
        el = lo - carry * P32; eh = (dh + t1h + carry) % P32
        dh, dl, chh, cl, bh, bl = chh, cl, bh, bl, ah, al
        lo = t1l + t2l; carry = floor(lo / P32)
        al = lo - carry * P32; ah = (t1h + t2h + carry) % P32
    end

    local v = { ah, al, bh, bl, chh, cl, dh, dl, eh, el, fh, fl, gh, gl, hh, hl }
    for i = 1, 16, 2 do
        local lo = h[i + 1] + v[i + 1]
        local carry = floor(lo / P32)
        h[i + 1] = lo - carry * P32
        h[i] = (h[i] + v[i] + carry) % P32
    end
end

function M.digest(msg)
    if not X8 then build_tables() end
    msg = tostring(msg)
    local len = #msg
    -- Pad: 0x80, zeros, then the bit length as a 128-bit big-endian integer.
    local zeros = (111 - len) % 128
    local bits = len * 8
    local s = msg .. '\128' .. string.rep('\0', zeros)
        .. string.rep('\0', 8) .. put32(floor(bits / P32)) .. put32(bits % P32)
    local h = {}
    for i = 1, 16 do h[i] = IV[i] end
    for off = 1, #s, 128 do block(h, s, off) end
    local out = {}
    for i = 1, 16 do out[i] = put32(h[i]) end
    return table.concat(out)
end

function M.hex(msg)
    return (M.digest(msg):gsub('.', function(c) return string.format('%02x', c:byte()) end))
end

return M
