-- test_share_dialog.lua — pure helpers behind the Share dialog (screenshot
-- listing, remembered author) and the file-row menu's Share entry. The dxgui
-- form itself is covered by the manual smoke (docs/release-gate/me-mod-smoke.md).
package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

package.preload['lfs'] = function()
    return { writedir = function() return '' end, mkdir = function() return true end,
             attributes = function() return nil end }
end

local dialog = require('dcs_sms_me.share_dialog')
local cm     = require('dcs_sms_me.context_menu')

local failures = 0
local function check(n, ok, msg) if ok then print('PASS '..n) else print('FAIL '..n..': '..tostring(msg)); failures=failures+1 end end

-- ---- recent_screenshots over a fake filesystem ----
local files = {
    ['Screen_260901_100000.png'] = 100,
    ['Screen_260926_120000.jpg'] = 300,
    ['Screen_260915_090000.JPEG'] = 200,
    ['notes.txt'] = 999,
    ['clip.mp4'] = 998,
}
local fake_fs = {
    dir = function(_)
        local names = { '.', '..', 'subdir.png' }
        for n in pairs(files) do names[#names + 1] = n end
        local i = 0
        return function() i = i + 1; return names[i] end
    end,
    attributes = function(p)
        local n = p:match('([^\\]+)$')
        if n == 'subdir.png' then return { mode = 'directory', modification = 1000 } end
        if files[n] then return { mode = 'file', modification = files[n] } end
        return nil
    end,
}
local shots = dialog.recent_screenshots('C:\\SG\\Screenshots\\', fake_fs, 12)
check('only image files, directories skipped', #shots == 3, #shots)
check('newest first', shots[1].name == 'Screen_260926_120000.jpg' and shots[3].name == 'Screen_260901_100000.png',
      shots[1] and shots[1].name)
check('full path built from dir', shots[1].path == 'C:\\SG\\Screenshots\\Screen_260926_120000.jpg', shots[1].path)
check('uppercase extensions accepted', shots[2].name == 'Screen_260915_090000.JPEG', shots[2] and shots[2].name)
check('limit applied', #dialog.recent_screenshots('d\\', fake_fs, 2) == 2)
local missing = dialog.recent_screenshots('X:\\nope\\', { dir = function() error('no such dir') end }, 12)
check('missing folder yields empty list, no throw', type(missing) == 'table' and #missing == 0)

-- ---- author persistence ----
local root = os.tmpname()
os.remove(root)
root = root .. '_'
check('no saved author -> empty', dialog.load_author(root) == '')
check('save_author writes', dialog.save_author(root, '  Shuffle  ') == true)
check('load_author trims', dialog.load_author(root) == 'Shuffle', dialog.load_author(root))
os.remove(root .. 'share-author.txt')

-- ---- file-row menu: Share entry ----
local function entry(row, hooks)
    for _, e in ipairs(cm._file_row_entries(row, hooks or {})) do
        if e.label == 'Share to community...' then return e end
    end
end
local shared
local e = entry({ name = 'mine', path = 'p' }, { on_share = function(r) shared = r end })
check('Share entry visible on own prefab', e and e.visible == true)
e.on_click()
check('Share entry calls on_share with the row', shared and shared.name == 'mine')
check('Share hidden on downloaded community prefab', entry({ name = 'c', path = 'p', community = true }).visible == false)
check('Share hidden on error rows', entry({ name = 'x', path = 'p', error = 'bad' }).visible == false)

-- ---- hide() (ME-exit hook in menu.lua) ----
check('hide() with no dialog open is a safe no-op', pcall(dialog.hide))
local menu_src = io.open('../lua/dcs_sms_me/menu.lua'):read('*a')
local list = menu_src:match('local HIDE_ON_EXIT = (%b{})') or ''
local share_at = list:find("'dcs_sms_me.share_dialog'", 1, true)
local pm_at = list:find("'dcs_sms_me.prefab_manager'", 1, true)
check('share dialog hides on ME exit, before its parent Prefab Manager',
      share_at and pm_at and share_at < pm_at, list)

if failures > 0 then os.exit(1) end
print('All share_dialog tests passed.')
