-- test_share_identity.lua — the per-install submitter keypair: create/load
-- round trip, corrupt-file safety, fingerprint, signed-message format.
package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

package.preload['lfs'] = function()
    return { writedir = function() return '' end, mkdir = function() return true end,
             attributes = function() return nil end }
end

local identity = require('dcs_sms_me.share_identity')
local ed       = require('dcs_sms_me.ed25519')
local b64      = require('dcs_sms_me.base64')

local failures = 0
local function check(n, ok, msg) if ok then print('PASS '..n) else print('FAIL '..n..': '..tostring(msg)); failures=failures+1 end end

local function tmp_root()
    local p = os.tmpname(); os.remove(p)
    return p .. '_'
end

-- ---- create / load round trip ----
local root = tmp_root()
local ticks = 0
local id, err = identity.load_or_create(root, function() ticks = ticks + 1 end)
check('first use creates an identity', id ~= nil, err)
check('keygen reports progress through tick', ticks > 0, ticks)
check('seed and public key are 32 bytes', #id.seed == 32 and #id.pub == 32)
check('public key matches the seed', ed.public_key(id.seed) == id.pub)
local again = identity.load_or_create(root)
check('second use loads the same identity', again and again.seed == id.seed and again.pub == id.pub)
local f = io.open(root .. identity.FILE, 'rb'); local text = f:read('*a'); f:close()
check('file records the fingerprint', text:find(identity.fingerprint(id.pub), 1, true) ~= nil)
check('file carries a keep-a-copy note', text:find('Keep a copy', 1, true) ~= nil)

-- ---- a corrupt identity is never silently replaced ----
f = io.open(root .. identity.FILE, 'wb'); f:write('{ not json'); f:close()
local bad, berr = identity.load_or_create(root)
check('corrupt identity.json is an error, not a new key', bad == nil and berr:find('not valid JSON', 1, true), berr)
f = io.open(root .. identity.FILE, 'rb'); text = f:read('*a'); f:close()
check('corrupt file left untouched', text == '{ not json', text)
f = io.open(root .. identity.FILE, 'wb'); f:write('{"version":1,"public":"AAAA","seed":"AAAA"}'); f:close()
bad, berr = identity.load(root)
check('wrong-length keys rejected', bad == nil and berr:find('incomplete', 1, true), berr)
os.remove(root .. identity.FILE)

-- ---- fresh seeds differ ----
check('two generated seeds differ', identity.new_seed() ~= identity.new_seed())

-- ---- fingerprint ----
local fp = identity.fingerprint(id.pub)
check('fingerprint format', fp:match('^sms:%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$') ~= nil, fp)

-- ---- signed message + headers ----
check('message format', identity.message('PUB', 1790000000, 'abc', '{"a":1}')
      == 'dcs-sms-submit/1\nPUB\n1790000000\nabc\n{"a":1}')
local h = identity.sign_headers(id, '{"name":"x"}', 1790000000.7)
check('headers carry base64 pubkey', b64.decode(h['X-SMS-PubKey']) == id.pub)
check('timestamp is whole seconds', h['X-SMS-Timestamp'] == '1790000000', h['X-SMS-Timestamp'])
check('nonce is 32 hex chars', h['X-SMS-Nonce']:match('^%x+$') and #h['X-SMS-Nonce'] == 32, h['X-SMS-Nonce'])
local sig = b64.decode(h['X-SMS-Signature'])
check('signature is 64 bytes and deterministic for the same message', #sig == 64
      and sig == ed.sign(id.seed, id.pub, identity.message(h['X-SMS-PubKey'], 1790000000, h['X-SMS-Nonce'], '{"name":"x"}')))
check('nonces differ between requests', identity.sign_headers(id, '{}', 1)['X-SMS-Nonce'] ~= identity.sign_headers(id, '{}', 1)['X-SMS-Nonce'])

if failures > 0 then os.exit(1) end
print('All share_identity tests passed.')
