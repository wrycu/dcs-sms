-- ed25519.lua — Ed25519 keypair + signing (RFC 8032) in pure Lua 5.1.
--
-- A port of TweetNaCl's signing path (tweetnacl-js flavour: field elements
-- are 16 limbs of 16 bits held in doubles, carries done with floor/multiply),
-- so it needs no bit library — the DCS Mission Editor runs PUC Lua 5.1, which
-- has none. Signing only: verification happens server-side (the ingest worker
-- uses the platform's native Ed25519).
--
-- NOT constant-time. The only party able to time this code is the user of
-- the machine, who already holds the key (see the upload spec).
--
-- A scalar multiplication costs about a second of PUC-Lua CPU, so the heavy
-- calls take an optional `tick` callback, invoked every few ladder steps. Pass
-- coroutine.yield from inside a coroutine to spread the work across editor
-- frames.
--
--   M.public_key(seed32, tick)            -> 32-byte public key
--   M.sign(seed32, pub32, msg, tick)      -> 64-byte signature
--
-- `seed32` is the 32-byte private seed (RFC 8032 "secret key").

local sha512 = require('dcs_sms_me.sha512')

local M = {}
local floor = math.floor

local function gf(init)
    local r = {}
    for i = 1, 16 do r[i] = (init and init[i]) or 0 end
    return r
end

local D = gf({ 0x78a3, 0x1359, 0x4dca, 0x75eb, 0xd8ab, 0x4141, 0x0a4d, 0x0070, 0xe898, 0x7779, 0x4079, 0x8cc7, 0xfe73, 0x2b6f, 0x6cee, 0x5203 })
local D2 = gf({ 0xf159, 0x26b2, 0x9b94, 0xebd6, 0xb156, 0x8283, 0x149a, 0x00e0, 0xd130, 0xeef3, 0x80f2, 0x198e, 0xfce7, 0x56df, 0xd9dc, 0x2406 })
local BX = gf({ 0xd51a, 0x8f25, 0x2d60, 0xc956, 0xa7b2, 0x9525, 0xc760, 0x692c, 0xdc5c, 0xfdd6, 0xe231, 0xc0a4, 0x53fe, 0xcd6e, 0x36d3, 0x2169 })
local BY = gf({ 0x6658, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666 })
local L = { 0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10 }

local function set(r, a) for i = 1, 16 do r[i] = a[i] end end

local function car(o)
    local c = 1
    for i = 1, 16 do
        local v = o[i] + c + 65535
        c = floor(v / 65536)
        o[i] = v - c * 65536
    end
    o[1] = o[1] + c - 1 + 37 * (c - 1)
end

-- Swap p and q when b == 1.
local function sel(p, q, b)
    if b == 1 then
        for i = 1, 16 do p[i], q[i] = q[i], p[i] end
    end
end

-- Field element -> 32 little-endian bytes (as a 1-based array), fully reduced.
local function pack25519(n)
    local t, m = gf(n), gf()
    car(t); car(t); car(t)
    for _ = 1, 2 do
        m[1] = t[1] - 0xffed
        for i = 2, 15 do
            m[i] = t[i] - 0xffff - (floor(m[i - 1] / 65536) % 2)
            m[i - 1] = m[i - 1] % 65536
        end
        m[16] = t[16] - 0x7fff - (floor(m[15] / 65536) % 2)
        local b = floor(m[16] / 65536) % 2
        m[15] = m[15] % 65536
        sel(t, m, 1 - b)
    end
    local o = {}
    for i = 1, 16 do
        o[2 * i - 1] = t[i] % 256
        o[2 * i] = floor(t[i] / 256)
    end
    return o
end

local function par25519(a) return pack25519(a)[1] % 2 end

local function A(o, a, b) for i = 1, 16 do o[i] = a[i] + b[i] end end
local function Z(o, a, b) for i = 1, 16 do o[i] = a[i] - b[i] end end

local T = {}
local function Mul(o, a, b)
    for i = 1, 31 do T[i] = 0 end
    for i = 1, 16 do
        local ai = a[i]
        if ai ~= 0 then
            for j = 1, 16 do T[i + j - 1] = T[i + j - 1] + ai * b[j] end
        end
    end
    for i = 1, 15 do T[i] = T[i] + 38 * T[i + 16] end
    for i = 1, 16 do o[i] = T[i] end
    car(o); car(o)
end

local function inv25519(i)
    local c = gf(i)
    for a = 253, 0, -1 do
        Mul(c, c, c)
        if a ~= 2 and a ~= 4 then Mul(c, c, i) end
    end
    return c
end

local ONE = gf({ 1 })

-- Extended twisted-Edwards point add: p = p + q. p, q are { X, Y, Z, T }.
local ta, tb, tc, td, te, tf, tg, th, tt = gf(), gf(), gf(), gf(), gf(), gf(), gf(), gf(), gf()
local function add(p, q)
    Z(ta, p[2], p[1]); Z(tt, q[2], q[1]); Mul(ta, ta, tt)
    A(tb, p[1], p[2]); A(tt, q[1], q[2]); Mul(tb, tb, tt)
    Mul(tc, p[4], q[4]); Mul(tc, tc, D2)
    Mul(td, p[3], q[3]); A(td, td, td)
    Z(te, tb, ta); Z(tf, td, tc); A(tg, td, tc); A(th, tb, ta)
    Mul(p[1], te, tf); Mul(p[2], th, tg); Mul(p[3], tg, tf); Mul(p[4], te, th)
end

local function cswap(p, q, b) for i = 1, 4 do sel(p[i], q[i], b) end end

-- Point -> 32-byte encoding (1-based byte array).
local function pack(p)
    local zi = inv25519(p[3])
    local tx, ty = gf(), gf()
    Mul(tx, p[1], zi); Mul(ty, p[2], zi)
    local r = pack25519(ty)
    r[32] = r[32] + par25519(tx) * 128
    return r
end

-- [s]B for the base point B; s is a 32-byte little-endian scalar (1-based).
local function scalarbase(s, tick)
    local p = { gf(), gf(ONE), gf(ONE), gf() }
    local q = { gf(BX), gf(BY), gf(ONE), gf() }
    Mul(q[4], BX, BY)
    for i = 255, 0, -1 do
        local b = floor(s[floor(i / 8) + 1] / 2 ^ (i % 8)) % 2
        cswap(p, q, b)
        add(q, p)
        add(p, p)
        cswap(p, q, b)
        if tick and i % 16 == 0 then tick() end
    end
    return p
end

-- x (64 limbs, 1-based, as produced by the schoolbook product) mod L -> 32 bytes.
local function modL(x)
    for i = 64, 33, -1 do
        local carry = 0
        local j = i - 32
        local k = i - 12
        while j < k do
            x[j] = x[j] + carry - 16 * x[i] * L[j - (i - 32) + 1]
            carry = floor((x[j] + 128) / 256)
            x[j] = x[j] - carry * 256
            j = j + 1
        end
        x[j] = x[j] + carry
        x[i] = 0
    end
    local carry = 0
    for j = 1, 32 do
        x[j] = x[j] + carry - floor(x[32] / 16) * L[j]
        carry = floor(x[j] / 256)
        x[j] = x[j] % 256
    end
    for j = 1, 32 do x[j] = x[j] - carry * L[j] end
    local r = {}
    for i = 1, 32 do
        x[i + 1] = x[i + 1] + floor(x[i] / 256)
        r[i] = x[i] % 256
    end
    return r
end

local function reduce(bytes64)
    local x = {}
    for i = 1, 64 do x[i] = bytes64[i] end
    return modL(x)
end

local function to_bytes(s)
    local t = {}
    for i = 1, #s do t[i] = s:byte(i) end
    return t
end

local function to_string(t, n)
    local parts = {}
    for i = 1, n or #t do parts[i] = string.char(t[i]) end
    return table.concat(parts)
end

-- SHA-512 of the seed, clamped: the secret scalar a (bytes 1..32) and the
-- nonce prefix (bytes 33..64).
local function expand(seed)
    local d = to_bytes(sha512.digest(seed))
    d[1] = d[1] - d[1] % 8
    d[32] = d[32] % 128
    if d[32] < 64 then d[32] = d[32] + 64 end
    return d
end

local function check_seed(seed)
    if type(seed) ~= 'string' or #seed ~= 32 then error('ed25519: seed must be 32 bytes', 3) end
end

function M.public_key(seed, tick)
    check_seed(seed)
    return to_string(pack(scalarbase(expand(seed), tick)), 32)
end

function M.sign(seed, pub, msg, tick)
    check_seed(seed)
    if type(pub) ~= 'string' or #pub ~= 32 then error('ed25519: public key must be 32 bytes', 2) end
    msg = tostring(msg or '')
    local d = expand(seed)
    local prefix = to_string({ unpack(d, 33, 64) }, 32)
    local r = reduce(to_bytes(sha512.digest(prefix .. msg)))
    local R = to_string(pack(scalarbase(r, tick)), 32)
    local h = reduce(to_bytes(sha512.digest(R .. pub .. msg)))
    local x = {}
    for i = 1, 64 do x[i] = 0 end
    for i = 1, 32 do x[i] = r[i] end
    for i = 1, 32 do
        for j = 1, 32 do x[i + j - 1] = x[i + j - 1] + h[i] * d[j] end
    end
    return R .. to_string(modL(x), 32)
end

return M
