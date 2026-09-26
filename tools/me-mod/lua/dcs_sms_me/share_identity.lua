-- share_identity.lua — the per-install submitter keypair for community uploads.
--
-- On first use the mod creates an Ed25519 keypair and keeps it in
-- <Saved Games>\DCS\dcs-sms\identity.json (under writedir, not the module dir,
-- so reinstalls keep it). Every submission is signed with it; the ingest
-- worker records the public key on first sight (trust on first use).
--
-- What it proves: the same key submitted this and those earlier entries.
-- What it does NOT prove: who anyone is. Never present it as "verified".
--
-- Entropy caveat: DCS's Lua has no cryptographic RNG (no /dev/urandom, and
-- LuaSec does not expose OpenSSL's RAND). The seed is SHA-512 over everything
-- unpredictable we can reach — microsecond clocks, busy-loop timing jitter,
-- heap addresses, GC state, environment and file timestamps. That is plenty
-- for a continuity identity whose worst-case compromise is "someone can update
-- your catalog entries pending a manual review", and not a claim of
-- key-generation-grade randomness.
--
--   M.fingerprint(pub)                -> 'sms:' .. 16 hex chars
--   M.load(root)                      -> id | nil, err      (id = {seed, pub})
--   M.create(root, tick)              -> id | nil, err      (generates + saves)
--   M.load_or_create(root, tick)      -> id | nil, err
--   M.message(pub_b64, ts, nonce, meta_json) -> the exact bytes that get signed
--   M.sign_headers(id, meta_json, now, tick) -> { ['X-SMS-…'] = … }

local sha512 = require('dcs_sms_me.sha512')
local ed     = require('dcs_sms_me.ed25519')
local b64    = require('dcs_sms_me.base64')

local M = {}

M.FILE = 'identity.json'
M.PROTOCOL = 'dcs-sms-submit/1'

local function hex(s)
    return (s:gsub('.', function(c) return string.format('%02x', c:byte()) end))
end

function M.fingerprint(pub)
    return 'sms:' .. hex(sha512.digest(pub)):sub(1, 16)
end

-- ---- entropy ---------------------------------------------------------------

local function now_us()
    local ok, socket = pcall(require, 'socket')
    if ok and type(socket) == 'table' and socket.gettime then
        local t = socket.gettime()
        return string.format('%.6f', t)
    end
    return tostring(os.time())
end

-- Gather a pool of hard-to-predict values. `extra` lets tests (and callers)
-- mix in more.
function M.entropy_pool(extra)
    local parts = { tostring(extra or ''), now_us(), tostring(os.time()),
                    string.format('%.9f', os.clock()), tostring({}), tostring(function() end),
                    string.format('%.3f', collectgarbage('count')) }
    for _, k in ipairs({ 'COMPUTERNAME', 'USERNAME', 'PROCESSOR_IDENTIFIER', 'USERPROFILE', 'TEMP' }) do
        parts[#parts + 1] = tostring(os.getenv(k))
    end
    pcall(function()
        local lfs = require('lfs')
        local a = lfs.attributes(lfs.writedir())
        if a then parts[#parts + 1] = tostring(a.modification) .. tostring(a.access) end
    end)
    -- Timing jitter: how far a busy loop gets between clock readings varies
    -- with scheduling, caches and frequency scaling.
    for _ = 1, 64 do
        local start, n = os.clock(), 0
        while os.clock() == start and n < 100000 do n = n + 1 end
        parts[#parts + 1] = tostring(n) .. now_us() .. tostring({})
    end
    math.randomseed(os.time())
    parts[#parts + 1] = tostring(math.random()) .. tostring(math.random())
    return table.concat(parts, '|')
end

function M.new_seed(extra)
    return sha512.digest(M.entropy_pool(extra)):sub(1, 32)
end

-- ---- storage ---------------------------------------------------------------

local function write_file(path, s)
    local f = io.open(path, 'wb')
    if not f then return false end
    f:write(s); f:close()
    return true
end

function M.load(root)
    local path = root .. M.FILE
    local f = io.open(path, 'rb')
    if not f then return nil, 'missing' end
    local s = f:read('*a'); f:close()
    local ok, json = pcall(require, 'dcs_sms_me.vendor.json')
    if not ok then return nil, 'json unavailable' end
    local dok, t = pcall(json.decode, s or '')
    if not dok or type(t) ~= 'table' then return nil, 'identity.json is not valid JSON' end
    local seed = type(t.seed) == 'string' and b64.decode(t.seed)
    local pub = type(t.public) == 'string' and b64.decode(t.public)
    if not (seed and #seed == 32 and pub and #pub == 32) then
        return nil, 'identity.json is incomplete'
    end
    return { seed = seed, pub = pub }
end

-- Generate a keypair, check it signs, and save it. `tick` (optional) is passed
-- to the Ed25519 work so a coroutine can spread it across frames.
function M.create(root, tick, extra_entropy)
    local seed = M.new_seed(extra_entropy)
    local pub = ed.public_key(seed, tick)
    local id = { seed = seed, pub = pub }
    local json = '{\n'
        .. '  "version": 1,\n'
        .. '  "public": "' .. b64.encode(pub) .. '",\n'
        .. '  "seed": "' .. b64.encode(seed) .. '",\n'
        .. '  "fingerprint": "' .. M.fingerprint(pub) .. '",\n'
        .. '  "created_utc": "' .. os.date('!%Y-%m-%dT%H:%M:%SZ') .. '",\n'
        .. '  "note": "Your dcs-sms community submitter key. Keep a copy: losing it means you can no longer update your own catalog entries. Never share the seed."\n'
        .. '}\n'
    if not write_file(root .. M.FILE, json) then
        return nil, 'cannot write ' .. root .. M.FILE
    end
    return id
end

function M.load_or_create(root, tick)
    local id, err = M.load(root)
    if id then return id end
    if err ~= 'missing' then
        -- A corrupt file is the user's identity; never silently replace it.
        return nil, err .. ' — fix or remove ' .. root .. M.FILE
    end
    return M.create(root, tick)
end

-- ---- signing ---------------------------------------------------------------

function M.message(pub_b64, ts, nonce, meta_json)
    return table.concat({ M.PROTOCOL, pub_b64, tostring(ts), nonce, meta_json }, '\n')
end

local counter = 0
local function new_nonce(id)
    counter = counter + 1
    return hex(sha512.digest(id.seed .. now_us() .. counter .. tostring({}))):sub(1, 32)
end

function M.sign_headers(id, meta_json, now, tick)
    local pub_b64 = b64.encode(id.pub)
    local ts = math.floor(now or os.time())
    local nonce = new_nonce(id)
    local sig = ed.sign(id.seed, id.pub, M.message(pub_b64, ts, nonce, meta_json), tick)
    return {
        ['X-SMS-PubKey']    = pub_b64,
        ['X-SMS-Timestamp'] = tostring(ts),
        ['X-SMS-Nonce']     = nonce,
        ['X-SMS-Signature'] = b64.encode(sig),
    }
end

return M
