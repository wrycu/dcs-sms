-- test_community_transport.lua
-- Drives community_transport's non-blocking HTTPS state machine through a
-- MOCK LuaSocket + LuaSec, with no real network. The mocks script each
-- socket/ssl call so the test exercises every stage transition — including the
-- "still pending" branches (timeout / wantread / wantwrite), partial send,
-- partial-receive accumulation, SNI, and the cert-verify params — that a live
-- smoke test can't deterministically hit. One poll() must advance the machine
-- exactly one step and never block.
package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

-- Stub lfs so paths (required by the transport) loads in the bare VM.
package.preload['lfs'] = function()
    return { writedir = function() return '' end, mkdir = function() return true end,
             attributes = function() return nil end }
end

-- Per-request scenario the mocks read (response split + status line).
local scenario = {}
local captured  = { wrap_params = nil, sni_host = nil, sent = nil }

-- Mock raw TCP socket. connect() reports "still connecting" once (timeout),
-- then "already connected" — both must be treated as pending, not errors.
-- When sock_connect_script is set, connect() replays it instead: each entry is
-- { ok, err } where ok=true means success (returns 1) and ok=false returns
-- (nil, err). This lets a test drive Winsock-specific "still connecting" codes.
local sock_connect_script
local function new_sock()
    local connects = 0
    return {
        settimeout = function() end,
        connect = function(_, host, port)
            connects = connects + 1
            if sock_connect_script then
                captured.sock_connects = connects
                local r = sock_connect_script[connects] or sock_connect_script[#sock_connect_script]
                if r[1] then return 1 end
                return nil, r[2]
            end
            if connects == 1 then return nil, 'timeout' end
            return nil, 'already connected'
        end,
        close = function() end,
    }
end

-- Mock TLS connection. Each verb yields a "want*"/timeout pending step before
-- succeeding, and send() reports a partial write before completing.
local function new_conn()
    local hs, sends, recvs = 0, 0, 0
    return {
        sni = function(_, host) captured.sni_host = host end,
        settimeout = function() end,
        dohandshake = function()
            hs = hs + 1
            if hs == 1 then return nil, 'wantread' end   -- pending
            return 1                                      -- handshake complete
        end,
        -- Honours LuaSocket's send(data, i, j) range. Records every byte that
        -- actually went out in captured.wire, so tests can prove nothing was
        -- skipped or sent twice.
        send = function(_, data, from, to)
            sends = sends + 1
            from = from or 1; to = to or #data
            captured.wire = captured.wire or {}
            captured.send_ranges = captured.send_ranges or {}
            captured.send_ranges[#captured.send_ranges + 1] = to - from + 1
            if sends == 1 then return nil, 'wantwrite' end          -- pending, nothing sent
            if sends == 2 then                                      -- would-block after a partial write
                local mid = from + math.floor((to - from) / 2)
                captured.wire[#captured.wire + 1] = data:sub(from, mid)
                return nil, 'wantwrite', mid
            end
            captured.wire[#captured.wire + 1] = data:sub(from, to)
            captured.sent = to
            return to
        end,
        receive = function(_, pat)
            recvs = recvs + 1
            captured.recv_pat = pat
            if recvs == 1 then return nil, 'wantread', '' end          -- pending, no bytes
            if recvs == 2 then return scenario.chunk, nil end           -- full chunk read → pending
            if recvs == 3 then return nil, 'timeout', scenario.part1 end -- partial → pending
            return nil, 'closed', scenario.part2                       -- server closed → done
        end,
        close = function() end,
    }
end

package.preload['socket'] = function() return { tcp = function() return new_sock() end } end
package.preload['ssl']    = function()
    return { wrap = function(sock, params) captured.wrap_params = params; return new_conn() end }
end

-- Stub the CA-bundle probe: the real one hits the filesystem and the bare test
-- VM has no installed payload (community_ca has its own unit test). Setting
-- ca_stub.path = nil simulates "no readable CA bundle anywhere" — the state
-- that used to reach OpenSSL and come back as the unactionable
-- "ssl.wrap: error loading CA locations ((null))".
local ca_stub = { path = 'C:\\SG\\DCS\\dcs-sms\\lib\\cacert.pem' }
package.preload['dcs_sms_me.community_ca'] = function()
    return {
        resolve = function()
            if ca_stub.path then return ca_stub.path end
            return nil, { 'C:\\SG\\DCS\\dcs-sms\\lib\\cacert.pem', 'D:\\DCS\\MissionEditor\\modules\\dcs_sms_me\\cacert.pem' }
        end,
    }
end

local paths     = require('dcs_sms_me.paths')
local transport = require('dcs_sms_me.community_transport')

local failures = 0
local function check(n, ok, msg) if ok then print('PASS '..n) else print('FAIL '..n..': '..tostring(msg)); failures=failures+1 end end

-- Pump poll() to completion (bounded), recording the status sequence.
local function drive(req, max)
    local seq, body, err = {}, nil, nil
    for _ = 1, (max or 50) do
        local status, payload = req.poll()
        seq[#seq+1] = status
        if status == 'done'  then body = payload; break end
        if status == 'error' then err  = payload; break end
    end
    return seq, body, err
end

-- available() is true once the (mock) ssl module loads.
check('available() true with ssl present', transport.available() == true)

-- ---- Happy path: 200 with a body split across two partial receives ----------
scenario = {
    chunk = 'HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nServer: mock\r\n\r\nHEL',
    part1 = 'LO-',
    part2 = 'WORLD',
}
captured = {}
local req = transport.request(nil, 'https://raw.githubusercontent.com/owner/repo/main/index.json')
local seq, body, err = drive(req)

check('completes with done (not error)', body ~= nil and err == nil, err)
check('body = stripped, reassembled payload', body == 'HELLO-WORLD', body)
check('reads in bounded chunks (receive(n), not *a)', type(captured.recv_pat) == 'number',
      tostring(captured.recv_pat))
-- Every step before the last is pending — one non-blocking step per poll.
local all_pending = true
for i = 1, #seq - 1 do if seq[i] ~= 'pending' then all_pending = false end end
check('each poll advanced exactly one pending step', all_pending and seq[#seq] == 'done',
      table.concat(seq, ','))
check('multiple pending steps were taken (machine really stepped)', #seq >= 8, #seq)
-- SNI is required for GitHub's SDN; cert verification must be real.
check('SNI set to the host', captured.sni_host == 'raw.githubusercontent.com', captured.sni_host)
check('TLS verify = peer (cert checked)', captured.wrap_params and captured.wrap_params.verify == 'peer')
check('cafile points at the bundled CA bundle',
      captured.wrap_params and tostring(captured.wrap_params.cafile):match('cacert%.pem$') ~= nil,
      captured.wrap_params and captured.wrap_params.cafile)
check('full request was sent before recv', captured.sent ~= nil and captured.sent > 0)

-- ---- Error path: non-200 status is surfaced as an error ---------------------
scenario = { part1 = 'HTTP/1.0 404 Not Found\r\n\r\n', part2 = '' }
captured = {}
local req404 = transport.request(nil, 'https://raw.githubusercontent.com/owner/repo/main/missing.json')
local _, body404, err404 = drive(req404)
check('404 yields no body', body404 == nil)
check('404 surfaced as HTTP 404 error', type(err404) == 'string' and err404:find('404', 1, true) ~= nil, err404)

-- ---- Winsock quirk: a non-blocking connect in progress can report itself as
-- "Invalid argument" (WSAEINVAL — Microsoft reports WSAEALREADY this way for
-- backward compatibility, and some LSPs do too). It must be treated as "still
-- connecting", NOT a fatal error. Two real users hit this on the Community tab.
sock_connect_script = {
    { false, 'timeout' },           -- 1st call: would-block
    { false, 'Invalid argument' },  -- 2nd call: in-progress, reported as EINVAL
    { true },                       -- 3rd call: connected
}
scenario = {
    chunk = 'HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\nHEL',
    part1 = 'LO-',
    part2 = 'WORLD',
}
captured = {}
local reqinval = transport.request(nil, 'https://raw.githubusercontent.com/owner/repo/main/index.json')
local seqinval, bodyinval, errinval = drive(reqinval)
check('connect "Invalid argument" treated as pending, not fatal',
      bodyinval == 'HELLO-WORLD' and errinval == nil, errinval or table.concat(seqinval, ','))
-- Pin the intent (not just the outcome): the EINVAL poll must RE-CALL connect,
-- so connect runs 3 times (timeout → "Invalid argument" → connected). A
-- regression that treats EINVAL as fatal would abort after the 2nd call.
check('EINVAL connect was re-polled, not aborted (connect called 3x)',
      captured.sock_connects == 3, captured.sock_connects)
sock_connect_script = nil

-- ---- No readable CA bundle: say what's wrong, don't let OpenSSL mumble ------
-- Regression guard for the Community tab's "Refresh failed: ssl.wrap: error
-- loading CA locations ((null))": OpenSSL raises an unopenable cafile as a
-- system error, whose reason string LuaSec prints as "(null)". We must catch it
-- before ssl.wrap and name both the file and the fix.
ca_stub.path = nil
captured = {}
local reqnoca = transport.request(nil, 'https://raw.githubusercontent.com/owner/repo/main/index.json')
local _, bodynoca, errnoca = drive(reqnoca)
check('missing CA bundle yields no body', bodynoca == nil, bodynoca)
check('missing CA bundle error names the file and the fix',
      type(errnoca) == 'string' and errnoca:find('cacert.pem', 1, true) ~= nil
      and errnoca:find('install-me-mod', 1, true) ~= nil, errnoca)
check('missing CA bundle never reaches ssl.wrap (so never yields "(null)")',
      captured.wrap_params == nil and tostring(errnoca):find('null', 1, true) == nil, errnoca)
ca_stub.path = 'C:\\SG\\DCS\\dcs-sms\\lib\\cacert.pem'

-- ---- Guard: a non-https URL fails immediately, without touching a socket ----
local reqbad = transport.request(nil, 'http://insecure.example/x')
local sbad, pbad = reqbad.poll()
check('non-https URL rejected', sbad == 'error' and tostring(pbad):find('https', 1, true) ~= nil, pbad)

-- ---- GET: a would-block after a partial write must not resend those bytes ---
scenario = { part1 = 'HTTP/1.0 200 OK\r\n\r\nok', part2 = '' }
captured = {}
drive(transport.request(nil, 'https://raw.githubusercontent.com/o/r/main/index.json'))
local wire_get = table.concat(captured.wire or {})
check('GET request goes out exactly once (partial write kept)',
      wire_get:match('^GET /o/r/main/index%.json HTTP/1%.0\r\n') ~= nil
      and select(2, wire_get:gsub('GET ', '')) == 1 and wire_get:sub(-4) == '\r\n\r\n', wire_get)

local ua = 'User-Agent: dcs-sms/' .. require('dcs_sms_me.version') .. '\r\n'
check('GET User-Agent carries the mod version', wire_get:find(ua, 1, true) ~= nil, wire_get)

-- ---- POST: body delivered byte-exact, in bounded chunks, any status returned
local big = string.rep('0123456789abcdef', 12000)   -- 192,000 bytes > SEND_CHUNK
scenario = { part1 = 'HTTP/1.0 202 Accepted\r\nContent-Type: application/json\r\n\r\n{"pr_url":"u"}', part2 = '' }
captured = {}
local reqp = transport.post(nil, 'https://ingest.example.workers.dev/v1/submit',
    { ['Content-Type'] = 'multipart/form-data; boundary=XYZ' }, big)
local seqp, resp, errp = drive(reqp, 200)
check('POST completes', resp ~= nil and errp == nil, errp or table.concat(seqp, ','))
check('POST done carries status + body', resp and resp.status == 202 and resp.body == '{"pr_url":"u"}',
      resp and (tostring(resp.status) .. ' ' .. tostring(resp.body)))
local wire = table.concat(captured.wire or {})
local head, sent_body = wire:match('^(.-)\r\n\r\n(.*)$')
check('POST request line + host', head and head:match('^POST /v1/submit HTTP/1%.0\r\nHost: ingest%.example%.workers%.dev\r\n') ~= nil, head)
check('POST Content-Length matches body', head and head:find('Content-Length: ' .. #big, 1, true) ~= nil, head)
check('POST User-Agent carries the mod version', head and head:find(ua, 1, true) ~= nil, head)
check('POST caller headers included', head and head:find('Content-Type: multipart/form-data; boundary=XYZ', 1, true) ~= nil, head)
check('POST body arrives byte-exact (no gaps, no duplicates)', sent_body == big,
      sent_body and #sent_body)
local max_range = 0
for _, n in ipairs(captured.send_ranges or {}) do if n > max_range then max_range = n end end
check('POST writes are bounded per poll', max_range <= 65536, max_range)
local sent_n, total_n = reqp.progress()
check('progress() reports all bytes sent', sent_n == total_n and total_n == #wire, sent_n .. '/' .. total_n)

-- 4xx is a result the caller reads, not a transport error.
scenario = { part1 = 'HTTP/1.0 429 Too Many Requests\r\nRetry-After: 60\r\n\r\n{"error":"slow down"}', part2 = '' }
captured = {}
local _, resp429, err429 = drive(transport.post(nil, 'https://ingest.example/v1/submit', {}, 'x'))
check('POST 429 returned as done, not error', err429 == nil and resp429 and resp429.status == 429
      and resp429.body == '{"error":"slow down"}', err429)

if failures > 0 then os.exit(1) end
print('All community_transport tests passed.')
