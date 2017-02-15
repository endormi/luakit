-----------------------------------------------------------
-- Downloads for luakit                                  --
-- © 2010-2012 Mason Larobina <mason.larobina@gmail.com> --
-- © 2010 Fabian Streitel <karottenreibe@gmail.com>      --
-----------------------------------------------------------

-- Grab environment from luakit libs
local lousy = require("lousy")
local webview = require("webview")
local window = require("window")

local capi = {
    download = download,
    timer = timer,
    luakit = luakit,
    widget = widget,
    xdg = xdg
}

local downloads = {}
lousy.signal.setup(downloads, true)

-- Unique ids for downloads in this luakit instance
local id_count = 0
local function next_download_id()
    id_count = id_count + 1
    return tostring(id_count)
end

-- Default download directory
downloads.default_dir = capi.xdg.download_dir or (os.getenv("HOME") .. "/downloads")

-- Private data for the download instances (speed tracking)
local dls = {}

function downloads.get_all()
    return lousy.util.table.clone(dls)
end

-- Get download object from id (passthrough if already given download object)
function downloads.to_download(id)
    if type(id) == "download" then return id end
    for d, data in pairs(dls) do
        if id == data.id then return d end
    end
end

function downloads.get(id)
    local d = assert(downloads.to_download(id),
        "download.get() expected valid download object or id")
    return d, dls[d]
end

local function is_running(d)
    local status = d.status
    return status == "created" or status == "started"
end

function downloads.do_open(d, w)
    if downloads.emit_signal("open-file", d.destination, d.mime_type, w) ~= true then
        if w then
            w:error(string.format("Couldn't open: %q (%s)", d.destination,
                d.mime_type))
        end
    end
end

local status_timer = capi.timer{interval=1000}
status_timer:add_signal("timeout", function ()
    local running = 0
    for d, data in pairs(dls) do
        -- Create list of running downloads
        if is_running(d) then running = running + 1 end

        -- Raise "download::status" signals
        local status = d.status
        if status ~= data.last_status then
            data.last_status = status
            downloads.emit_signal("download::status", d, data)

            -- Open download
            if status == "finished" and data.opening then
                downloads.do_open(d)
            end
        end
    end

    -- Stop the status_timer after all downloads finished
    if running == 0 then status_timer:stop() end

    -- Update window download status widget
    for _, w in pairs(window.bywidget) do
        w.sbar.r.downloads.text = (running == 0 and "") or running.."↓"
    end

    downloads.emit_signal("status-tick", running)
end)

function downloads.add(uri, opts, view)
    opts = opts or {}
    local d = (type(uri) == "string" and capi.download{uri=uri}) or uri

    assert(type(d) == "download",
        string.format("download.add() expected uri or download object "
            .. "(got %s)", type(d) or "nil"))

    d:add_signal("decide-destination", function(dd, suggested_filename)
        -- Emit signal to get initial download location
        local fn = opts.filename or downloads.emit_signal("download-location", dd.uri,
            opts.suggested_filename or suggested_filename, dd.mime_type)
        assert(fn == nil or type(fn) == "string" and #fn > 1,
            string.format("invalid filename: %q", tostring(fn)))

        -- Ask the user where we should download the file to
        if not fn then
            fn = capi.luakit.save_file("Save file", opts.window, downloads.default_dir,
                suggested_filename)
        end

        dd.allow_overwrite = true

        if fn then
            dd.destination = fn
            dd:add_signal("created-destination", function(ddd,destination)
                local data = {
                    created = capi.luakit.time(),
                    id = next_download_id(),
                }
                dls[ddd] = data
                if not status_timer.started then status_timer:start() end
                downloads.emit_signal("download::status", ddd, dls[ddd])
            end)
            --return true
        else
            dd:cancel()
        end
        return true
    end)
end

function downloads.cancel(id)
    local d = assert(downloads.to_download(id),
        "download.cancel() expected valid download object or id")
    d:cancel()
    downloads.emit_signal("download::status", d, dls[d])
end

function downloads.remove(id)
    local d = assert(downloads.to_download(id),
        "download.remove() expected valid download object or id")
    if is_running(d) then downloads.cancel(d) end
    downloads.emit_signal("removed-download", d, dls[d])
    dls[d] = nil
end

function downloads.restart(id)
    local d = assert(downloads.to_download(id),
        "download.restart() expected valid download object or id")
    local new_d = downloads.add(d.uri) -- TODO use soup message from old download
    if new_d then downloads.remove(d) end
    return new_d
end

function downloads.open(id, w)
    local d = assert(downloads.to_download(id),
        "download.open() expected valid download object or id")
    local data = assert(dls[d], "download removed")

    if d.status == "finished" then
        data.opening = false
        downloads.do_open(d, w)
    else
        -- Set open flag to open file when download finishes
        data.opening = true
    end
end

-- Clear all finished, cancelled or aborted downloads
function downloads.clear()
    for d, _ in pairs(dls) do
        if not is_running(d) then
            dls[d] = nil
        end
    end
    downloads.emit_signal("cleared-downloads")
end

-- Catch "download-started" webcontext widget signals (webkit2 API)
-- returned d is a download_t
capi.luakit.add_signal("download-start", function (d, v)
    local w

    if v then
        w = webview.window(v)
    else
        -- Fall back to currently focused window
        for _, ww in pairs(window.bywidget) do
            if ww.win.focused then
                w, v = ww, ww.view
                break
            end
        end
    end

    downloads.add(d, { window = w.win }, v)
    return true
end)

window.init_funcs.download_status = function (w)
    local r = w.sbar.r
    r.downloads = capi.widget{type="label"}
    r.layout:pack(r.downloads)
    r.layout:reorder(r.downloads, 1)
    -- Apply theme
    local theme = lousy.theme.get()
    r.downloads.fg = theme.downloads_sbar_fg
    r.downloads.font = theme.downloads_sbar_font
end

-- Prevent luakit from soft-closing if there are downloads still running
capi.luakit.add_signal("can-close", function ()
    local count = 0
    for d, _ in pairs(dls) do
        if is_running(d) then
            count = count + 1
        end
    end
    if count > 0 then
        return count .. " download(s) still running"
    end
end)

-- Download normal mode binds.
local key = lousy.bind.key
add_binds("normal", {
    key({"Control"}, "D",
        "Generate `:download` command with current URI.",
        function (w)
            w:enter_cmd(":download " .. (w.view.uri or "http://"))
        end),
})

-- Download commands
local cmd = lousy.bind.cmd
add_cmds({
    cmd("down[load]", "Download the given URI.", function (w, a)
        downloads.add(a, { window = w.win })
    end),
})

return downloads
