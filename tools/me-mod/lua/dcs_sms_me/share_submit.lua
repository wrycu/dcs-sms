-- share_submit.lua — upload one prefab to the community ingest worker.
--
-- Pure pieces (unit-tested): local pre-flight validation mirroring the
-- worker's caps, a minimal JSON encoder for the `meta` part (vendor/json.lua is
-- decode-only), the multipart/form-data body builder, and the mapping from the
-- worker's HTTP reply to a user-facing result.
--
-- The upload itself is a job pumped one step per UpdateManager tick, exactly
-- like community_fetch: the transport never blocks the editor.
--
-- No request signing yet — see docs/superpowers/specs/2026-09-19-community-prefab-upload.md.
-- The shared-key HMAC and Ed25519 identity layers are extra headers on this
-- same POST when they land.

local cfg = require('dcs_sms_me.community_config')

local M = {}

-- Mirror of the worker's caps (tools/ingest-worker/src/submission.js). Checked
-- locally so an oversized submission fails before the round trip; the worker
-- enforces them regardless.
M.CAPS = {
    prefab_bytes = 2 * 1024 * 1024,
    image_bytes  = 8 * 1024 * 1024,
    images       = 6,
    body_bytes   = 24 * 1024 * 1024,
    name         = 80,
    author       = 64,
    description  = 2000,
    tags         = 10,
    tag          = 32,
}

local function trim(s) return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', '')) end

-- 'FOB, props ,fob' -> { 'fob', 'props' }
function M.parse_tags(text)
    local out, seen = {}, {}
    for raw in tostring(text or ''):gmatch('[^,]+') do
        local t = trim(raw):lower()
        if t ~= '' and not seen[t] then seen[t] = true; out[#out + 1] = t end
    end
    return out
end

local function ext_of(name)
    local e = tostring(name or ''):match('%.([^.\\/]+)$')
    return e and e:lower() or ''
end

M.IMAGE_EXTS = { png = true, jpg = true, jpeg = true }

-- Validate the form before building anything. `f` = { name, author,
-- description, tags (list), prefab (bytes), images = { {name, bytes} } }.
-- Returns true, or nil + a message fit for the status bar.
function M.validate(f)
    local function need(key, label, max)
        local v = trim(f[key])
        if v == '' then return nil, label .. ' is required.' end
        if #v > max then return nil, label .. ' is too long (max ' .. max .. ' characters).' end
        return true
    end
    local ok, err = need('name', 'Name', M.CAPS.name);                     if not ok then return nil, err end
    ok, err = need('author', 'Author', M.CAPS.author);                     if not ok then return nil, err end
    ok, err = need('description', 'Description', M.CAPS.description);      if not ok then return nil, err end
    local tags = f.tags or {}
    if #tags > M.CAPS.tags then return nil, 'At most ' .. M.CAPS.tags .. ' tags.' end
    for _, t in ipairs(tags) do
        if #t > M.CAPS.tag then return nil, 'Tag "' .. t .. '" is too long.' end
    end
    if type(f.prefab) ~= 'string' or f.prefab == '' then return nil, 'The prefab file is empty.' end
    if #f.prefab > M.CAPS.prefab_bytes then return nil, 'The prefab is larger than 2 MB.' end
    local images = f.images or {}
    if #images > M.CAPS.images then return nil, 'At most ' .. M.CAPS.images .. ' images.' end
    local total = #f.prefab
    for _, img in ipairs(images) do
        if not M.IMAGE_EXTS[ext_of(img.name)] then
            return nil, tostring(img.name) .. ' is not a PNG or JPEG.'
        end
        if #img.bytes > M.CAPS.image_bytes then return nil, tostring(img.name) .. ' is larger than 8 MB.' end
        total = total + #img.bytes
    end
    if total > M.CAPS.body_bytes then return nil, 'The submission is larger than 24 MB.' end
    return true
end

-- ---- JSON encode (strings, numbers, booleans, arrays, objects) -------------

local ESC = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
              ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }

local function encode_string(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        return ESC[c] or string.format('\\u%04x', c:byte())
    end) .. '"'
end

local function is_array(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    for i = 1, n do if t[i] == nil then return false end end
    return true
end

function M.json_encode(v)
    local t = type(v)
    if t == 'string' then return encode_string(v) end
    if t == 'number' then return string.format('%.14g', v) end
    if t == 'boolean' then return tostring(v) end
    if t == 'table' then
        local parts = {}
        if next(v) == nil then return '[]' end
        if is_array(v) then
            for _, x in ipairs(v) do parts[#parts + 1] = M.json_encode(x) end
            return '[' .. table.concat(parts, ',') .. ']'
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)   -- stable output
        for _, k in ipairs(keys) do
            parts[#parts + 1] = encode_string(k) .. ':' .. M.json_encode(v[k])
        end
        return '{' .. table.concat(parts, ',') .. '}'
    end
    return 'null'
end

-- ---- multipart/form-data --------------------------------------------------

local CONTENT_TYPES = { png = 'image/png', jpg = 'image/jpeg', jpeg = 'image/jpeg' }

local function random_boundary()
    local hex = {}
    for i = 1, 24 do hex[i] = string.format('%x', math.random(0, 15)) end
    return '----dcs-sms-' .. table.concat(hex)
end

-- Filenames go into a quoted header; keep them to a safe charset.
local function safe_filename(name)
    local base = tostring(name or 'file'):match('([^\\/]+)$') or 'file'
    return (base:gsub('[^%w%._%-]', '_'))
end

-- Build the request body. `f` as for validate(); `boundary` is optional (tests
-- pass a fixed one). Returns body, content_type.
function M.build_multipart(f, boundary)
    local meta = M.json_encode({
        name        = trim(f.name),
        author      = trim(f.author),
        description = trim(f.description),
        tags        = f.tags or {},
        client      = f.client or '',
    })
    -- A boundary must not occur inside any part. Random 96-bit boundaries make
    -- that astronomically unlikely; check anyway, it's cheap next to the upload.
    local contents = { meta, f.prefab }
    for _, img in ipairs(f.images or {}) do contents[#contents + 1] = img.bytes end
    local function collides(b)
        for _, c in ipairs(contents) do
            if c:find(b, 1, true) then return true end
        end
        return false
    end
    boundary = boundary or random_boundary()
    while collides(boundary) do boundary = random_boundary() end

    local out = {}
    local function part(disposition, ctype, bytes)
        out[#out + 1] = '--' .. boundary .. '\r\n'
        out[#out + 1] = 'Content-Disposition: form-data; ' .. disposition .. '\r\n'
        if ctype then out[#out + 1] = 'Content-Type: ' .. ctype .. '\r\n' end
        out[#out + 1] = '\r\n'
        out[#out + 1] = bytes
        out[#out + 1] = '\r\n'
    end
    part('name="meta"', 'application/json', meta)
    part('name="prefab"; filename="' .. safe_filename(f.prefab_name or 'prefab.prefab') .. '"',
         'application/octet-stream', f.prefab)
    for _, img in ipairs(f.images or {}) do
        part('name="image"; filename="' .. safe_filename(img.name) .. '"',
             CONTENT_TYPES[ext_of(img.name)] or 'application/octet-stream', img.bytes)
    end
    out[#out + 1] = '--' .. boundary .. '--\r\n'
    return table.concat(out), 'multipart/form-data; boundary=' .. boundary
end

-- ---- reply interpretation -------------------------------------------------

-- Pull a string field out of the worker's small JSON reply without depending
-- on the decoder accepting every shape the worker might send.
local function field(body, key)
    local ok, json = pcall(require, 'dcs_sms_me.vendor.json')
    if ok and json and json.decode then
        local dok, t = pcall(json.decode, body or '')
        if dok and type(t) == 'table' and type(t[key]) == 'string' then return t[key] end
    end
    return nil
end

-- Map a transport result to { ok, pr_url?, message }.
function M.interpret(resp)
    local status, body = resp and resp.status or 0, resp and resp.body or ''
    if status == 202 or status == 200 then
        local url = field(body, 'pr_url')
        return { ok = true, pr_url = url,
                 message = 'Submitted for review.' .. (url and (' ' .. url) or '') }
    end
    local err = field(body, 'error')
    if status == 409 then
        -- pr_url present = an identical prefab is in an open PR, not merged yet.
        local pending = field(body, 'pr_url')
        if pending then
            return { ok = false, message = 'Already submitted and awaiting review: ' .. pending }
        end
        local existing = field(body, 'existing')
        return { ok = false, message = 'Already in the catalog'
                 .. (existing and (' as "' .. existing .. '"') or '') .. '.' }
    end
    if status == 429 then
        return { ok = false, message = 'Too many submissions from this connection — try again in an hour.' }
    end
    if status == 413 or status == 400 then
        return { ok = false, message = 'Rejected: ' .. (err or ('HTTP ' .. status)) }
    end
    return { ok = false, message = 'Submission failed: ' .. (err or ('HTTP ' .. tostring(status))) }
end

-- ---- job -------------------------------------------------------------------

local Job = {}
Job.__index = Job

-- `transport` must provide :post(url, headers, body) (community_transport).
function M.new(transport)
    return setmetatable({ transport = transport, state = 'idle', req = nil,
                          result = nil, error = nil }, Job)
end

-- Start uploading form `f`. Returns true, or nil + message (validation or
-- configuration failure — nothing was sent).
function Job:start(f)
    local ok, err = M.validate(f)
    if not ok then return nil, err end
    local url = cfg.SUBMIT_URL
    if type(url) ~= 'string' or url == '' then
        return nil, 'Community uploads are not configured in this build.'
    end
    local body, ctype = M.build_multipart(f)
    self.req = self.transport:post(url, { ['Content-Type'] = ctype }, body)
    self.state = 'running'; self.result = nil; self.error = nil
    return true
end

-- Advance one non-blocking step. Returns the state: 'running' | 'done' | 'error' | 'idle'.
function Job:step()
    if self.state ~= 'running' or not self.req then return self.state end
    local ok, status, payload = pcall(self.req.poll)
    if not ok then
        self.state = 'error'; self.error = tostring(status); self.req = nil
    elseif status == 'done' then
        self.result = M.interpret(payload)
        self.state = 'done'; self.req = nil
    elseif status == 'error' then
        self.state = 'error'; self.error = tostring(payload); self.req = nil
    end
    return self.state
end

-- 0..1 upload fraction (bytes handed to the socket), for a progress readout.
function Job:progress()
    if not (self.req and self.req.progress) then return self.state == 'done' and 1 or 0 end
    local sent, total = self.req.progress()
    if not total or total == 0 then return 0 end
    return sent / total
end

-- Abandon an in-flight upload and close its socket.
function Job:cancel()
    if self.req and self.req.close then pcall(self.req.close) end
    self.req = nil; self.state = 'idle'
end

return M
