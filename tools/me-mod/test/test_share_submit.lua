-- test_share_submit.lua — pure pieces of the community upload client:
-- validation, JSON encoding, multipart body, reply interpretation, and the
-- tick-pumped job over a fake transport.
package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

package.preload['lfs'] = function()
    return { writedir = function() return '' end, mkdir = function() return true end,
             attributes = function() return nil end }
end

local cfg   = require('dcs_sms_me.community_config')
local share = require('dcs_sms_me.share_submit')

local failures = 0
local function check(n, ok, msg) if ok then print('PASS '..n) else print('FAIL '..n..': '..tostring(msg)); failures=failures+1 end end

local PNG = '\137PNG\r\n\26\n' .. 'pixels'
local PREFAB = 'return {\n  meta = { name = "Test" },\n}\n'

local function form(over)
    local f = { name = 'Test Site', author = 'Shuffle', description = 'A test.',
                tags = { 'fob' }, prefab = PREFAB, prefab_name = 'Test Site.prefab',
                images = { { name = 'Screen_260926_120000.png', bytes = PNG } }, client = 'me-mod 0.29.0' }
    for k, v in pairs(over or {}) do f[k] = v end
    return f
end

-- ---- parse_tags ----
local tags = share.parse_tags(' FOB, props ,fob,, ')
check('parse_tags lowercases, trims, de-dupes', #tags == 2 and tags[1] == 'fob' and tags[2] == 'props',
      table.concat(tags, '|'))

-- ---- validate ----
check('valid form passes', share.validate(form()) == true)
local _, e = share.validate(form({ author = '  ' }))
check('blank author rejected', e == 'Author is required.', e)
_, e = share.validate(form({ name = string.rep('x', 81) }))
check('long name rejected', e and e:find('too long', 1, true), e)
_, e = share.validate(form({ prefab = '' }))
check('empty prefab rejected', e and e:find('empty', 1, true), e)
_, e = share.validate(form({ images = { { name = 'evil.exe', bytes = 'MZ' } } }))
check('non-image extension rejected', e and e:find('PNG or JPEG', 1, true), e)
local seven = {}
for i = 1, 7 do seven[i] = { name = i .. '.png', bytes = PNG } end
_, e = share.validate(form({ images = seven }))
check('too many images rejected', e and e:find('At most 6', 1, true), e)
_, e = share.validate(form({ images = { { name = 'big.jpg', bytes = string.rep('x', share.CAPS.image_bytes + 1) } } }))
check('oversized image rejected', e and e:find('8 MB', 1, true), e)

-- ---- json_encode ----
check('json: escapes quotes, backslashes, newlines, control chars',
      share.json_encode('a"b\\c\nd\1') == '"a\\"b\\\\c\\nd\\u0001"', share.json_encode('a"b\\c\nd\1'))
check('json: UTF-8 passes through', share.json_encode('Café') == '"Café"')
check('json: array', share.json_encode({ 'a', 'b' }) == '["a","b"]')
check('json: empty table is []', share.json_encode({}) == '[]')
check('json: object keys sorted', share.json_encode({ b = 1, a = true }) == '{"a":true,"b":1}',
      share.json_encode({ b = 1, a = true }))

-- ---- build_multipart ----
local body, ctype = share.build_multipart(form(), 'BOUNDARY')
check('content type carries boundary', ctype == 'multipart/form-data; boundary=BOUNDARY', ctype)
check('meta part is JSON with trimmed fields',
      body:find('name="meta"\r\nContent-Type: application/json\r\n\r\n{"author":"Shuffle",', 1, true) ~= nil, body:sub(1, 200))
check('prefab part carries exact bytes',
      body:find('\r\n\r\n' .. PREFAB .. '\r\n--BOUNDARY', 1, true) ~= nil)
check('prefab filename sanitised', body:find('filename="Test_Site.prefab"', 1, true) ~= nil)
check('image part typed + named',
      body:find('name="image"; filename="Screen_260926_120000.png"\r\nContent-Type: image/png', 1, true) ~= nil)
check('body ends with closing boundary', body:sub(-14) == '--BOUNDARY--\r\n', body:sub(-14))
-- A boundary that occurs in the payload is replaced.
local b2, c2 = share.build_multipart(form({ prefab = 'contains BOUNDARY inside' }), 'BOUNDARY')
check('colliding boundary replaced', c2 ~= 'multipart/form-data; boundary=BOUNDARY'
      and b2:find('contains BOUNDARY inside', 1, true) ~= nil, c2)

-- ---- interpret ----
local r = share.interpret({ status = 202, body = '{"submission_id":"x","pr_url":"https://github.com/o/r/pull/7"}' })
check('202 -> ok with PR url', r.ok and r.pr_url == 'https://github.com/o/r/pull/7', r.message)
r = share.interpret({ status = 409, body = '{"error":"dup","existing":"2 x ZSU"}' })
check('409 names the existing entry', not r.ok and r.message:find('2 x ZSU', 1, true), r.message)
r = share.interpret({ status = 409, body = '{"error":"pending","existing":"x (awaiting review)","pr_url":"https://github.com/o/r/pull/3"}' })
check('409 with pr_url -> awaiting review + link', not r.ok
      and r.message == 'Already submitted and awaiting review: https://github.com/o/r/pull/3', r.message)
r = share.interpret({ status = 429, body = '{"error":"slow"}' })
check('429 -> try again later', not r.ok and r.message:find('try again', 1, true), r.message)
r = share.interpret({ status = 413, body = '{"error":"prefab is larger than 2 MB"}' })
check('413 carries the worker reason', not r.ok and r.message:find('2 MB', 1, true), r.message)
r = share.interpret({ status = 502, body = 'not json' })
check('unparseable error body still yields a message', not r.ok and r.message:find('502', 1, true), r.message)

-- ---- job over a fake transport ----
local function fake_transport(script)
    local t = { posted = nil, closed = false }
    function t:post(url, headers, body)
        t.posted = { url = url, headers = headers, body = body }
        local i = 0
        return {
            poll = function() i = i + 1; return script[i][1], script[i][2] end,
            progress = function() return math.min(i, 2), 2 end,
            close = function() t.closed = true end,
        }
    end
    return t
end

cfg.SUBMIT_URL = ''
local j = share.new(fake_transport({}))
local ok, err = j:start(form())
check('unconfigured endpoint refuses to start', not ok and err:find('not configured', 1, true), err)

cfg.SUBMIT_URL = 'https://ingest.example/v1/submit'
local t = fake_transport({ { 'pending' }, { 'pending' },
    { 'done', { status = 202, body = '{"pr_url":"https://github.com/o/r/pull/9"}' } } })
j = share.new(t)
ok, err = j:start(form())
check('start ok when configured + valid', ok == true, err)
check('posts to SUBMIT_URL with multipart content type', t.posted.url == cfg.SUBMIT_URL
      and t.posted.headers['Content-Type']:match('^multipart/form%-data; boundary=') ~= nil)
check('step returns running while pending', j:step() == 'running' and j:step() == 'running')
check('progress readable mid-upload', j:progress() == 1)
check('step returns done on reply', j:step() == 'done')
check('result carries the PR url', j.result.ok and j.result.pr_url == 'https://github.com/o/r/pull/9')

ok, err = share.new(fake_transport({})):start(form({ description = '' }))
check('invalid form refused before any request', not ok and err == 'Description is required.', err)

t = fake_transport({ { 'error', 'connect: refused' } })
j = share.new(t); j:start(form())
check('transport error surfaces as error state', j:step() == 'error' and j.error == 'connect: refused', j.error)

t = fake_transport({ { 'pending' } })
j = share.new(t); j:start(form()); j:step(); j:cancel()
check('cancel closes the socket and idles the job', t.closed and j.state == 'idle' and j:step() == 'idle')

if failures > 0 then os.exit(1) end
print('All share_submit tests passed.')
