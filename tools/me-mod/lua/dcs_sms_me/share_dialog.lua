-- share_dialog.lua — "Share to community…" for one prefab in My Prefabs.
--
-- sms_window modal: Name / Author / Description / Tags, a checklist of the most
-- recent DCS screenshots to attach, Submit / Cancel. Submit runs the local
-- pure-data pre-check (prefab_safe_load), then drives a share_submit job one
-- step per UpdateManager tick — the editor never blocks. The result (PR link or
-- a readable reason) lands in the footer; on success an Open PR button appears.
--
-- The dxgui parts are verified by manual smoke (docs/release-gate/me-mod-smoke.md).
-- The pure helpers (recent_screenshots, author persistence) are unit-tested.

local Static;   do local ok, m = pcall(require, 'Static');   if ok then Static   = m end end
local Button;   do local ok, m = pcall(require, 'Button');   if ok then Button   = m end end
local EditBox;  do local ok, m = pcall(require, 'EditBox');  if ok then EditBox  = m end end
local CheckBox; do local ok, m = pcall(require, 'CheckBox'); if ok then CheckBox = m end end
local Skin;     do local ok, m = pcall(require, 'Skin');     if ok then Skin     = m end end
-- Not a global in the ME's Lua state: require it, like sms_window/prefab_manager.
local UpdateManager; do local ok, m = pcall(require, 'UpdateManager'); if ok then UpdateManager = m end end

local sms_skins; do local ok, m = pcall(require, 'dcs_sms_me.sms_skins'); if ok then sms_skins = m end end

local lfs   = require('lfs')
local paths = require('dcs_sms_me.paths')
local share = require('dcs_sms_me.share_submit')

local M = {}
local W = {}   -- single dialog instance

M.MAX_SCREENSHOTS = 12
local AUTHOR_FILE = 'share-author.txt'

-- ---- pure helpers (unit-tested) --------------------------------------------

-- The newest image files in `dir` (DCS writes Screen_<yymmdd>_<hhmmss>.png/.jpg
-- there), newest first, at most `limit`. `fs` is lfs (injectable for tests).
-- Returns { { name, path, modified } }.
function M.recent_screenshots(dir, fs, limit)
    local out = {}
    local ok = pcall(function()
        for entry in fs.dir(dir) do
            local ext = entry:match('%.([^.]+)$')
            if ext and share.IMAGE_EXTS[ext:lower()] then
                local p = dir .. entry
                local attr = fs.attributes(p)
                if attr and attr.mode == 'file' then
                    out[#out + 1] = { name = entry, path = p, modified = attr.modification or 0 }
                end
            end
        end
    end)
    if not ok then return {} end
    table.sort(out, function(a, b)
        if a.modified ~= b.modified then return a.modified > b.modified end
        return a.name > b.name
    end)
    for i = #out, (limit or M.MAX_SCREENSHOTS) + 1, -1 do out[i] = nil end
    return out
end

function M.load_author(root)
    local f = io.open(root .. AUTHOR_FILE, 'rb')
    if not f then return '' end
    local s = f:read('*a') or ''; f:close()
    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

function M.save_author(root, author)
    local f = io.open(root .. AUTHOR_FILE, 'wb')
    if not f then return false end
    f:write(tostring(author or '')); f:close()
    return true
end

-- ---- dxgui -----------------------------------------------------------------

local function try_skin(widget, skin_name)
    pcall(function()
        if not (widget and widget.setSkin) then return end
        local s
        if skin_name == 'sms_button' then s = sms_skins and sms_skins.button()
        else
            local fn = Skin and Skin[skin_name]
            if fn then s = fn() end
        end
        if s then widget:setSkin(s) end
    end)
end

local function text_of(widget)
    local ok, t = pcall(function() return widget:getText() end)
    return (ok and type(t) == 'string') and t or ''
end

local function status(text, sev)
    if W.win then pcall(function() W.win:set_status(tostring(text), sev or 'info') end) end
end

local function read_file(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local s = f:read('*a'); f:close()
    return s
end

local function set_busy(busy)
    W.busy = busy
    pcall(function() W.submit_btn:setEnabled(not busy) end)
    pcall(function() W.cancel_btn:setText(busy and 'Stop' or 'Close') end)
end

-- Pumped by UpdateManager every frame; cheap no-op when idle.
local function tick()
    local job = W.job
    if not job or job.state ~= 'running' then return end
    local state = job:step()
    if state == 'running' then
        local pct = math.floor(job:progress() * 100)
        status(pct < 100 and ('Uploading… ' .. pct .. '%') or 'Waiting for the server…')
        return
    end
    set_busy(false)
    W.job = nil
    if state == 'done' and job.result then
        if job.result.ok then
            W.pr_url = job.result.pr_url
            pcall(function() W.open_btn:setVisible(W.pr_url ~= nil) end)
            status('Submitted for review — thanks! A maintainer will merge it.', 'success')
            pcall(function()
                log.write('sms.me.share', log.INFO, 'submitted: ' .. tostring(W.pr_url))
            end)
        else
            status(job.result.message, 'error')
        end
    else
        status('Upload failed: ' .. tostring(job.error), 'error')
        pcall(function() log.write('sms.me.share', log.ERROR, 'upload failed: ' .. tostring(job.error)) end)
    end
end

-- Returns true once the per-frame pump is registered. Without it an upload
-- would sit at "Uploading…" forever, so callers must refuse to start.
local function ensure_tick()
    if W.tick_added then return true end
    if not (UpdateManager and UpdateManager.add) then return false end
    local ok = pcall(function() UpdateManager.add(function() pcall(tick) end) end)
    W.tick_added = ok
    return ok
end

local function on_submit()
    if W.busy then return end
    local prefab = read_file(W.row.path)
    if not prefab then status('Cannot read ' .. tostring(W.row.path), 'error'); return end

    -- Local pre-flight: the same pure-data grammar the catalog CI enforces.
    local safe = require('dcs_sms_me.prefab_safe_load')
    local parsed, perr = safe.load_string(prefab)
    if not parsed then status('This prefab would be rejected: ' .. tostring(perr), 'error'); return end

    local images = {}
    for _, s in ipairs(W.shots or {}) do
        local checked = false
        pcall(function() checked = s.check:getState() == true end)
        if checked then
            local bytes = read_file(s.path)
            if not bytes then status('Cannot read ' .. s.name, 'error'); return end
            images[#images + 1] = { name = s.name, bytes = bytes }
        end
    end

    local form = {
        name        = text_of(W.name),
        author      = text_of(W.author),
        description = text_of(W.desc),
        tags        = share.parse_tags(text_of(W.tags)),
        prefab      = prefab,
        prefab_name = (W.row.name or 'prefab') .. '.prefab',
        images      = images,
        client      = 'me-mod ' .. tostring(require('dcs_sms_me.version')),
    }
    local transport = require('dcs_sms_me.community_transport')
    if not transport.available() then
        status('Secure networking unavailable — re-run "dcs-sms install-me-mod".', 'error'); return
    end
    if not ensure_tick() then
        status('Cannot schedule the upload (UpdateManager unavailable) — see dcs.log.', 'error')
        pcall(function() log.write('sms.me.share', log.ERROR, 'UpdateManager.add unavailable') end)
        return
    end
    local job = share.new(transport)
    local ok, err = job:start(form)
    if not ok then status(err, 'warning'); return end

    M.save_author(paths.ROOT, form.author)
    W.pr_url = nil
    pcall(function() W.open_btn:setVisible(false) end)
    W.job = job
    set_busy(true)
    status('Uploading…')
end

local function on_cancel()
    if W.job then
        W.job:cancel(); W.job = nil
        set_busy(false)
        status('Upload stopped.', 'warning')
        return
    end
    if W.win then pcall(function() W.win:hide() end) end
end

local function on_open_pr()
    if not W.pr_url then return end
    -- The URL comes from our worker, but it still goes to a shell: only allow
    -- plain https URLs with no quoting characters.
    if not W.pr_url:match('^https://[%w%.%-_/:%%]+$') then return end
    os.execute('start "" "' .. W.pr_url .. '"')
end

local LABEL_W, ROW_H, GAP = 90, 22, 8

local function relayout(x, y, w, h)
    local function set(widget, bx, by, bw, bh)
        if widget then pcall(function() widget:setBounds(bx, by, bw, bh) end) end
    end
    local fx, fw = x + LABEL_W, w - LABEL_W
    local cy = y
    set(W.name_lbl, x, cy, LABEL_W, ROW_H);   set(W.name, fx, cy, fw, ROW_H);   cy = cy + ROW_H + GAP
    set(W.author_lbl, x, cy, LABEL_W, ROW_H); set(W.author, fx, cy, fw, ROW_H); cy = cy + ROW_H + GAP
    set(W.desc_lbl, x, cy, LABEL_W, ROW_H);   set(W.desc, fx, cy, fw, 90);      cy = cy + 90 + GAP
    set(W.tags_lbl, x, cy, LABEL_W, ROW_H);   set(W.tags, fx, cy, fw, ROW_H);   cy = cy + ROW_H + GAP
    set(W.shots_lbl, x, cy, w, ROW_H);        cy = cy + ROW_H
    for i, s in ipairs(W.shots or {}) do
        -- Two columns of checkboxes.
        local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
        set(s.check, x + col * math.floor(w / 2), cy + row * ROW_H, math.floor(w / 2) - 4, ROW_H)
    end
    local by = y + h - ROW_H
    set(W.folder_btn, x, by, 150, ROW_H)
    set(W.open_btn, x + w - 290, by, 110, ROW_H)
    set(W.submit_btn, x + w - 175, by, 85, ROW_H)
    set(W.cancel_btn, x + w - 85, by, 85, ROW_H)
end

local function label(raw, text)
    local l = Static.new(); l:setText(text)
    try_skin(l, 'staticSkin_ME')
    raw:insertWidget(l)
    return l
end

local function button(raw, text, cb)
    local b = Button.new(); pcall(function() b:setText(text) end)
    try_skin(b, 'sms_button')
    if b.addChangeCallback then b:addChangeCallback(cb) end
    raw:insertWidget(b)
    return b
end

-- Hide without cancelling: an in-flight upload keeps running on the tick and
-- Share brings the dialog back. Called on ME exit (menu.lua HIDE_ON_EXIT).
function M.hide()
    if W.win then pcall(function() W.win:hide() end) end
end

-- Open the dialog for a My Prefabs row ({ name, path, community, ... }).
-- `parent` (optional) centres the modal over the Prefab Manager.
function M.open(row, parent)
    if not (row and row.path) then return end
    -- Closed mid-upload: bring the running dialog back rather than a new one.
    if W.job and W.win then pcall(function() W.win:show() end); return end
    if W.win then pcall(function() W.win:hide() end); W.win = nil end
    if not (Static and Button and EditBox) then return end

    local sms_window = require('dcs_sms_me.sms_window')
    local mw, mh = 520, 520
    local position
    pcall(function()
        local px, py, pw, ph = parent:getBounds()
        if px and pw then position = { x = px + math.floor((pw - mw) / 2), y = py + math.floor((ph - mh) / 2) } end
    end)
    W.row = row
    W.win = sms_window.new({
        title = 'Share to Community', size = { w = mw, h = mh }, position = position,
        resizable = false, branded_title = false, modal_parent = parent,
        disable_undo_hotkey = true,
    })
    if not W.win then return end
    local raw = W.win:raw()

    W.name_lbl = label(raw, 'Name')
    W.name = EditBox.new(); try_skin(W.name, 'editBoxSkin_ME')
    pcall(function() W.name:setText(row.name or '') end)
    raw:insertWidget(W.name)

    W.author_lbl = label(raw, 'Author')
    W.author = EditBox.new(); try_skin(W.author, 'editBoxSkin_ME')
    pcall(function() W.author:setText(M.load_author(paths.ROOT)) end)
    pcall(function() if W.author.setHintText then W.author:setHintText('Your name as shown in the catalog') end end)
    raw:insertWidget(W.author)

    W.desc_lbl = label(raw, 'Description')
    W.desc = EditBox.new()
    -- setMultiline BEFORE setSkin: it rebuilds the scrollbar widgets.
    pcall(function() if W.desc.setMultiline then W.desc:setMultiline(true) end end)
    try_skin(W.desc, 'editBoxSkin_ME')
    raw:insertWidget(W.desc)

    W.tags_lbl = label(raw, 'Tags')
    W.tags = EditBox.new(); try_skin(W.tags, 'editBoxSkin_ME')
    pcall(function() if W.tags.setHintText then W.tags:setHintText('comma-separated, e.g. sam, fob') end end)
    raw:insertWidget(W.tags)

    local shot_dir = lfs.writedir() .. 'Screenshots\\'
    local recent = M.recent_screenshots(shot_dir, lfs, M.MAX_SCREENSHOTS)
    W.shots_lbl = label(raw, #recent > 0
        and string.format('Screenshots to attach (newest first, up to %d):', share.CAPS.images)
        or 'No screenshots found — take some in DCS (PrtSc), then reopen this dialog.')
    W.shots = {}
    if CheckBox then
        for _, s in ipairs(recent) do
            local c = CheckBox.new(s.name)
            try_skin(c, 'checkBoxSkin_MENew')
            pcall(function() c:setState(false) end)
            raw:insertWidget(c)
            W.shots[#W.shots + 1] = { name = s.name, path = s.path, check = c }
        end
    end

    W.folder_btn = button(raw, 'Screenshots folder', function()
        pcall(function() lfs.mkdir(shot_dir) end)
        os.execute('explorer "' .. shot_dir .. '"')
    end)
    W.open_btn   = button(raw, 'Open PR', on_open_pr)
    pcall(function() W.open_btn:setVisible(false) end)
    W.submit_btn = button(raw, 'Submit', on_submit)
    W.cancel_btn = button(raw, 'Close', on_cancel)

    local x, y, w, h = W.win:get_content_bounds()
    relayout(x, y, w, h)
    W.win:show()
    status('Submissions open a pull request that a maintainer reviews before it goes live.')
end

return M
