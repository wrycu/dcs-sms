-- community_transport.lua — NON-BLOCKING HTTPS GET/POST for community_fetch
-- and share_submit.
--
-- Satisfies the transport contract: request(url) -> req with :poll() returning
--   'pending'              — not done yet, call again next tick
--   'done', body           — full response body (headers stripped)
--   'error', message       — failed
--
-- post(url, headers, body) -> req with the same :poll(), except 'done' carries
-- { status = <code>, body = <string> } for EVERY HTTP status: the caller needs
-- the server's 4xx replies (duplicate, rate-limited, ...) to tell the user why.
-- 'error' is reserved for network/TLS failures. req.progress() returns
-- (bytes_sent, bytes_total) for an upload progress bar; req.close() drops the
-- connection (used to cancel).
--
-- CRITICAL: the Mission Editor is single-threaded PUC Lua. A blocking socket
-- call freezes (and can CRASH) the editor — so EVERY socket operation here runs
-- with settimeout(0) and the request is advanced ONE non-blocking step per
-- poll() (community_fetch pumps poll() once per UpdateManager tick via a
-- coroutine). We use LuaSocket's raw TCP + LuaSec's ssl.wrap/dohandshake and
-- speak HTTP/1.0 ourselves, rather than the blocking ssl.https/socket.http.
--
-- DCS ships LuaSocket but NOT LuaSec; the LuaSec payload (ssl.dll + ssl.lua +
-- OpenSSL DLLs + cacert.pem) is deployed by `install-me-mod` to dcs-sms\lib\
-- (+ DCS bin) and wired onto package.cpath/path by init.lua. When absent,
-- M.available() is false and the UI degrades to "secure networking
-- unavailable". The CA bundle itself is located by community_ca.lua, which
-- falls back to the copy installed next to the mod when lib\ has none.

local ca = require('dcs_sms_me.community_ca')

-- Sent on every request so server-side logs (GitHub, the ingest worker) can
-- tell which mod release is calling.
local USER_AGENT = 'dcs-sms/' .. tostring(require('dcs_sms_me.version'))
local M = {}

-- Lazy, cached require of LuaSec. false (not nil) once known-missing so the
-- pcall cost is paid at most once.
local ssl
local function load_ssl()
    if ssl ~= nil then return ssl end
    local ok, mod = pcall(require, 'ssl')
    ssl = (ok and type(mod) == 'table') and mod or false
    return ssl
end

function M.available()
    return load_ssl() ~= false
end

-- Parse an https URL into host, port, path. Returns nil on a non-https URL.
local function parse_url(url)
    local host, rest = tostring(url or ''):match('^https://([^/]*)(.*)$')
    if not host or host == '' then return nil end
    local port = 443
    local h, p = host:match('^(.-):(%d+)$')
    if h then host, port = h, tonumber(p) end
    if rest == '' then rest = '/' end
    return host, port, rest
end

-- Split the raw HTTP response into status code + body (strip headers at the
-- first blank line). Returns code (number) and body (string).
local function split_response(raw)
    local head, body = raw:match('^(.-)\r\n\r\n(.*)$')
    if not head then head, body = raw, '' end
    local code = tonumber(head:match('^HTTP/%d%.%d%s+(%d%d%d)')) or 0
    return code, body
end

-- Safety cap so a stuck connection can never spin forever (each poll ≈ one ME
-- tick). ~3600 ticks is well over a minute even at 60 fps.
local MAX_POLLS = 3600

-- Read at most this many bytes per poll. LuaSocket's '*a' pattern drains the
-- whole socket buffer in a single call — on a fast/large download that is the
-- entire response in one tick, which freezes the editor for the whole transfer.
-- A bounded receive caps each tick's work so the download spreads across ticks
-- and the editor stays responsive. 16 KB ≈ one TLS record.
local RECV_CHUNK = 16384

-- Write at most this many bytes per poll, for the same reason: a multi-MB
-- upload handed to one send() call would block the tick while the kernel
-- buffer drains. Bounded writes spread it across ticks.
local SEND_CHUNK = 65536

-- An upload of up to 24 MB can legitimately outlast MAX_POLLS on a slow link,
-- so POST gets ~10 minutes of ticks instead of ~1.
local MAX_POLLS_POST = 36000

-- Shared state machine. `build(host, path)` returns the full request bytes;
-- `finish(code, body)` maps the response to the poll() result.
local function open(url, build, finish, max_polls)
    local mod = load_ssl()
    if not mod then
        return { poll = function() return 'error', 'LuaSec not installed (run dcs-sms install-me-mod)' end }
    end
    local socket_ok, socket = pcall(require, 'socket')
    if not socket_ok or type(socket) ~= 'table' then
        return { poll = function() return 'error', 'LuaSocket unavailable' end }
    end
    local host, port, path = parse_url(url)
    if not host then
        return { poll = function() return 'error', 'not an https URL: ' .. tostring(url) end }
    end

    local stage    = 'connect'   -- connect → wrap → handshake → send → recv → done
    local sock, conn
    local request  = build(host, path)
    local sent     = 0
    local chunks   = {}
    local polls    = 0

    local function cleanup()
        if conn then pcall(function() conn:close() end)
        elseif sock then pcall(function() sock:close() end) end
    end

    -- One non-blocking step. Returns ('pending') | ('done', body) | ('error', msg).
    local function step()
        if stage == 'connect' then
            if not sock then
                local s, e = socket.tcp()
                if not s then return 'error', 'tcp(): ' .. tostring(e) end
                sock = s
                sock:settimeout(0)
            end
            local r, e = sock:connect(host, port)
            if r then stage = 'wrap'; return 'pending' end
            -- Non-blocking connect: these all mean "still connecting". We poll by
            -- re-calling connect() each tick; on Windows the in-progress call
            -- reports WSAEALREADY ("Operation already in progress"), but Winsock
            -- remaps that to WSAEINVAL ("Invalid argument") for backward compat
            -- (and some LSPs/VPN/AV shims do the same) — so treat that as
            -- still-connecting too, or the refresh aborts on machines where it
            -- surfaces. The bounded MAX_POLLS budget caps a genuinely stuck connect.
            if e == 'timeout' or e == 'Operation already in progress'
               or e == 'Operation now in progress' or e == 'Invalid argument' then return 'pending' end
            if e == 'already connected' then stage = 'wrap'; return 'pending' end
            return 'error', 'connect: ' .. tostring(e)

        elseif stage == 'wrap' then
            -- Probe the CA bundle ourselves first. OpenSSL reports a cafile it
            -- cannot open as a *system* error, and LuaSec renders those as
            -- "error loading CA locations ((null))" — true but unactionable.
            local cafile, tried = ca.resolve()
            if not cafile then
                pcall(function()
                    log.write('sms.me.community', log.ERROR,
                              'no readable CA bundle; tried: ' .. table.concat(tried, ' | '))
                end)
                return 'error', 'CA bundle missing (dcs-sms\\lib\\cacert.pem) — re-run "dcs-sms install-me-mod"'
            end
            local c, e = mod.wrap(sock, {
                mode     = 'client',
                protocol = 'any',
                cafile   = cafile,
                verify   = 'peer',
                options  = 'all',
            })
            if not c then
                local msg = tostring(e)
                -- resolve() just opened that file, so a "(null)" here means
                -- OpenSSL specifically couldn't read it (lock, permissions, AV).
                if msg:find('(null)', 1, true) then
                    msg = msg .. ' — OpenSSL could not read ' .. cafile
                end
                return 'error', 'ssl.wrap: ' .. msg
            end
            conn = c
            pcall(function() conn:sni(host) end)  -- SNI: GitHub needs it
            conn:settimeout(0)
            stage = 'handshake'
            return 'pending'

        elseif stage == 'handshake' then
            local r, e = conn:dohandshake()
            if r then stage = 'send'; return 'pending' end
            if e == 'wantread' or e == 'wantwrite' or e == 'timeout' then return 'pending' end
            return 'error', 'handshake: ' .. tostring(e)

        elseif stage == 'send' then
            -- send() returns the index of the last byte written; on would-block
            -- it returns (nil, err, last_index_written) — keep that partial
            -- progress, or the bytes already sent go out a second time.
            local i, e, partial = conn:send(request, sent + 1, math.min(sent + SEND_CHUNK, #request))
            if i then
                sent = i
                if sent >= #request then stage = 'recv' end
                return 'pending'
            end
            if e == 'wantwrite' or e == 'wantread' or e == 'timeout' then
                if type(partial) == 'number' and partial > sent then sent = partial end
                return 'pending'
            end
            return 'error', 'send: ' .. tostring(e)

        elseif stage == 'recv' then
            -- Read at most RECV_CHUNK bytes per poll (NOT '*a', which drains the
            -- whole buffer in one call and stalls the tick for the full
            -- transfer). receive(n) returns: n bytes as `data` with no error
            -- (more may remain → yield); or a short `partial` with
            -- wantread/wantwrite/timeout (would block → yield); or `closed` with
            -- the final partial (HTTP/1.0 Connection: close → body complete).
            local data, e, partial = conn:receive(RECV_CHUNK)
            if data and #data > 0 then chunks[#chunks + 1] = data end
            if partial and #partial > 0 then chunks[#chunks + 1] = partial end
            if e == 'closed' then
                cleanup()
                return finish(split_response(table.concat(chunks)))
            end
            if e == nil or e == 'wantread' or e == 'wantwrite' or e == 'timeout' then
                return 'pending'
            end
            return 'error', 'recv: ' .. tostring(e)
        end
        return 'error', 'bad stage'
    end

    local req = {}
    function req.progress() return sent, #request end
    function req.close() cleanup() end
    function req.poll()
        polls = polls + 1
        if polls > max_polls then cleanup(); return 'error', 'timed out' end
        local ok, status, payload = pcall(step)
        if not ok then
            cleanup()
            return 'error', 'transport: ' .. tostring(status)
        end
        return status, payload
    end
    return req
end

function M.request(_, url)
    return open(url, function(host, path)
        return string.format(
            'GET %s HTTP/1.0\r\nHost: %s\r\nUser-Agent: %s\r\nAccept: */*\r\nConnection: close\r\n\r\n',
            path, host, USER_AGENT)
    end, function(code, body)
        if code ~= 200 then return 'error', 'HTTP ' .. tostring(code) end
        return 'done', body
    end, MAX_POLLS)
end

-- `headers` is a { [name] = value } map; Host, Content-Length and Connection
-- are set here and must not be passed in.
function M.post(_, url, headers, body)
    body = body or ''
    return open(url, function(host, path)
        local lines = {
            'POST ' .. path .. ' HTTP/1.0',
            'Host: ' .. host,
            'User-Agent: ' .. USER_AGENT,
            'Accept: application/json',
            'Content-Length: ' .. #body,
            'Connection: close',
        }
        local names = {}
        for k in pairs(headers or {}) do names[#names + 1] = k end
        table.sort(names)   -- deterministic header order (tests, debugging)
        for _, k in ipairs(names) do lines[#lines + 1] = k .. ': ' .. tostring(headers[k]) end
        return table.concat(lines, '\r\n') .. '\r\n\r\n' .. body
    end, function(code, resp)
        if code == 0 then return 'error', 'malformed HTTP response' end
        return 'done', { status = code, body = resp }
    end, MAX_POLLS_POST)
end

return M
