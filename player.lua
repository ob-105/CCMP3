-- CC:Tweaked MP3 Player with clickable UI and favorites
local VERSION = "4"

local BASE_URL = "https://raw.githubusercontent.com/ob-105/CCMP3/main"
local DEFAULT_SERVER_URL = "http://127.0.0.1:8765"
local FAVORITES_PATH = "mp3_favorites.lua"
local PLAYLISTS_PATH = "mp3_playlists.lua"
local SOURCE_URL_PATH = "mp3_source_url.txt"
local SOURCE_MODE_PATH = "mp3_source_mode.txt"
local SELF_PATH = "player.lua"
local UPDATE_URL = BASE_URL .. "/player.lua"

local function read_text_file(path)
    if not fs.exists(path) then return nil end
    local f = fs.open(path, "r")
    if not f then return nil end
    local txt = f.readAll()
    f.close()
    if not txt then return nil end
    txt = txt:gsub("%s+$", "")
    if txt == "" then return nil end
    return txt
end

local function write_text_file(path, value)
    local f = fs.open(path, "w")
    if not f then return false end
    f.write(value)
    f.write("\n")
    f.close()
    return true
end

local function load_source_mode()
    local mode = read_text_file(SOURCE_MODE_PATH)
    if mode == "server" then return "server" end
    return "github"
end

local function save_source_mode(mode)
    return write_text_file(SOURCE_MODE_PATH, mode)
end

local function load_server_url()
    return read_text_file(SOURCE_URL_PATH) or DEFAULT_SERVER_URL
end

local function active_base_for_mode(mode)
    if mode == "server" then return load_server_url() end
    return BASE_URL
end

local function download(url, path)
    local dir = path:match("^(.*)/[^/]+$")
    if dir and dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local res = http.get(url, nil, true)
    if not res then return false end
    local data = res.readAll()
    res.close()
    local f = fs.open(path, "wb")
    f.write(data)
    f.close()
    return true
end

local function self_update()
    if not http or not http.get then return end

    local ok, res = pcall(http.get, UPDATE_URL, nil, true)
    if not ok or not res then return end

    local data = res.readAll()
    res.close()
    if not data or data == "" then return end

    local remote_ver = data:match('local VERSION%s*=%s*"(%d+)"')
    local remote_num = tonumber(remote_ver or "")
    local local_num = tonumber(VERSION) or 0
    if not remote_num or remote_num <= local_num then return end

    local f = fs.open(SELF_PATH, "w")
    if not f then return end
    f.write(data)
    f.close()

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    print("Updated player to v" .. tostring(remote_num) .. ". Rebooting...")
    os.sleep(0.4)
    os.reboot()
end

local load_index_for_base

local function load_index()
    local active_base = active_base_for_mode(load_source_mode())
    return load_index_for_base(active_base)
end

load_index_for_base = function(active_base)
    local path = "media/index.lua"
    if fs.exists(path) then fs.delete(path) end

    local ok = download(active_base .. "/output/index.lua", path)
    if not ok then return { video = {}, audio = {} } end

    local fn = loadfile(path)
    if not fn then return { video = {}, audio = {} } end

    local good, result = pcall(fn)
    if not good or type(result) ~= "table" then return { video = {}, audio = {} } end

    result.video = result.video or {}
    result.audio = result.audio or {}
    return result
end

local function reload_index_for_state(state)
    local active_base = active_base_for_mode(state.source_mode)
    local idx = load_index_for_base(active_base)
    if #idx.audio == 0 then
        return false, "No audio entries from source"
    end
    state.songs = idx.audio
    state.scroll = 0
    state.active_base = active_base
    return true, "Loaded " .. tostring(#idx.audio) .. " tracks"
end

local function load_favorites_map()
    if not fs.exists(FAVORITES_PATH) then return {} end
    local f = fs.open(FAVORITES_PATH, "r")
    if not f then return {} end
    local raw = f.readAll()
    f.close()
    local t = textutils.unserialize(raw)
    if type(t) ~= "table" then return {} end
    local map = {}
    for _, name in ipairs(t) do
        if type(name) == "string" then map[name] = true end
    end
    return map
end

local function save_favorites_map(map)
    local list = {}
    for name, v in pairs(map) do
        if v then list[#list + 1] = name end
    end
    table.sort(list)
    local f = fs.open(FAVORITES_PATH, "w")
    if not f then return end
    f.write(textutils.serialize(list))
    f.close()
end

local function load_playlists_map()
    if not fs.exists(PLAYLISTS_PATH) then return {} end
    local f = fs.open(PLAYLISTS_PATH, "r")
    if not f then return {} end
    local raw = f.readAll()
    f.close()
    local t = textutils.unserialize(raw)
    if type(t) ~= "table" then return {} end

    local out = {}
    for k, v in pairs(t) do
        if type(k) == "string" and type(v) == "table" then
            local cleaned = {}
            for _, name in ipairs(v) do
                if type(name) == "string" then cleaned[#cleaned + 1] = name end
            end
            out[k] = cleaned
        end
    end
    return out
end

local function save_playlists_map(map)
    local f = fs.open(PLAYLISTS_PATH, "w")
    if not f then return end
    f.write(textutils.serialize(map))
    f.close()
end

local function get_playlist_names(map)
    local names = {}
    for name, songs in pairs(map) do
        if type(name) == "string" and type(songs) == "table" then
            names[#names + 1] = name
        end
    end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    return names
end

local function contains_song(list, song)
    for _, s in ipairs(list) do
        if s == song then return true end
    end
    return false
end

local function ensure_active_playlist(state)
    local names = get_playlist_names(state.playlists)
    if #names == 0 then
        state.active_playlist = nil
        return names
    end
    if not state.active_playlist or not state.playlists[state.active_playlist] then
        state.active_playlist = names[1]
    end
    return names
end

local function matches_search(song_name, query)
    if not query or query == "" then return true end
    return song_name:lower():find(query:lower(), 1, true) ~= nil
end

local function collect_speakers()
    return { peripheral.find("speaker") }
end

local function make_ui_state(index)
    local playlists = load_playlists_map()
    return {
        songs = index.audio,
        view = "all",      -- all | favorites | playlists
        source_mode = load_source_mode(),
        active_base = BASE_URL,
        scroll = 0,
        favorites = load_favorites_map(),
        playlists = playlists,
        active_playlist = nil,
        search_query = "",
        running = true,
        dirty = true,
        message = "Click Play to start.",
        now_playing = nil,
        paused = false,
        volume = 1.5,
        zones = {},
    }
end

local function filtered_songs(state)
    local base = {}
    if state.view == "all" then
        base = state.songs
    elseif state.view == "favorites" then
        for _, name in ipairs(state.songs) do
            if state.favorites[name] then base[#base + 1] = name end
        end
    else
        ensure_active_playlist(state)
        local list = state.active_playlist and state.playlists[state.active_playlist] or {}
        local song_map = {}
        for _, s in ipairs(state.songs) do song_map[s] = true end
        for _, name in ipairs(list or {}) do
            if song_map[name] then base[#base + 1] = name end
        end
    end

    if state.search_query == "" then return base end

    local out = {}
    for _, name in ipairs(base) do
        if matches_search(name, state.search_query) then out[#out + 1] = name end
    end
    return out
end

local function set_colors()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
end

local function put(x, y, text, fg, bg)
    if fg then term.setTextColor(fg) end
    if bg then term.setBackgroundColor(bg) end
    term.setCursorPos(x, y)
    term.write(text)
end

local function clear_line(y)
    local w = term.getSize()
    term.setCursorPos(1, y)
    term.clearLine()
    term.setCursorPos(w, y)
end

local function add_zone(state, x1, x2, y, kind, name)
    state.zones[#state.zones + 1] = { x1 = x1, x2 = x2, y = y, kind = kind, name = name }
end

local function draw_ui(state)
    if not state.dirty then return end
    state.dirty = false
    state.zones = {}

    local w, h = term.getSize()
    local list_start = 4
    local footer_y = h
    local list_height = math.max(1, h - list_start - 2)
    local songs = filtered_songs(state)

    if state.scroll < 0 then state.scroll = 0 end
    if state.scroll > math.max(0, #songs - list_height) then
        state.scroll = math.max(0, #songs - list_height)
    end

    set_colors()
    term.clear()

    put(1, 1, string.rep(" ", w), colors.black, colors.cyan)
    put(2, 1, "CC MP3 Player v" .. VERSION, colors.black, colors.cyan)

    local all_label = "[ All ]"
    local fav_label = "[ Favorites ]"
    local pl_label = "[ Playlists ]"
    local all_bg = state.view == "all" and colors.lime or colors.gray
    local fav_bg = state.view == "favorites" and colors.lime or colors.gray
    local pl_bg = state.view == "playlists" and colors.lime or colors.gray
    put(2, 2, all_label, colors.black, all_bg)
    add_zone(state, 2, 2 + #all_label - 1, 2, "tab", "all")
    put(2 + #all_label + 1, 2, fav_label, colors.black, fav_bg)
    add_zone(state, 2 + #all_label + 1, 2 + #all_label + #fav_label, 2, "tab", "favorites")
    local pl_x = 2 + #all_label + #fav_label + 2
    put(pl_x, 2, pl_label, colors.black, pl_bg)
    add_zone(state, pl_x, pl_x + #pl_label - 1, 2, "tab", "playlists")

    local src_git = "[GitHub]"
    local src_srv = "[Server]"
    local src_refresh = "[Reload]"
    local src_x = math.max(pl_x + #pl_label + 2, w - (#src_git + #src_srv + #src_refresh + 6))

    put(src_x, 2, src_git, colors.black, state.source_mode == "github" and colors.lightBlue or colors.gray)
    add_zone(state, src_x, src_x + #src_git - 1, 2, "source", "github")

    local src_srv_x = src_x + #src_git + 1
    put(src_srv_x, 2, src_srv, colors.black, state.source_mode == "server" and colors.lightBlue or colors.gray)
    add_zone(state, src_srv_x, src_srv_x + #src_srv - 1, 2, "source", "server")

    local src_ref_x = src_srv_x + #src_srv + 1
    put(src_ref_x, 2, src_refresh, colors.black, colors.orange)
    add_zone(state, src_ref_x, src_ref_x + #src_refresh - 1, 2, "reload", "reload")

    put(1, 3, string.rep(" ", w), colors.lightGray, colors.black)
    local x = 2
    if state.view == "playlists" then
        local prev_btn = "[Prev]"
        local next_btn = "[Next]"
        local new_btn = "[New]"
        local del_btn = "[Del]"
        put(x, 3, prev_btn, colors.black, colors.lightBlue)
        add_zone(state, x, x + #prev_btn - 1, 3, "plist_prev", "prev")
        x = x + #prev_btn + 1
        put(x, 3, next_btn, colors.black, colors.lightBlue)
        add_zone(state, x, x + #next_btn - 1, 3, "plist_next", "next")
        x = x + #next_btn + 1
        put(x, 3, new_btn, colors.black, colors.lime)
        add_zone(state, x, x + #new_btn - 1, 3, "plist_new", "new")
        x = x + #new_btn + 1
        put(x, 3, del_btn, colors.black, colors.red)
        add_zone(state, x, x + #del_btn - 1, 3, "plist_del", "del")
        x = x + #del_btn + 2

        local list_name = state.active_playlist or "(none)"
        local list_text = "List: " .. list_name
        local max_list = math.max(1, w - x - 18)
        if #list_text > max_list then
            list_text = list_text:sub(1, math.max(1, max_list - 3)) .. "..."
        end
        put(x, 3, list_text, colors.lightGray, colors.black)
    end

    local search_btn = "[Search]"
    local clear_btn = "[Clear]"
    local search_x = math.max(2, w - (#search_btn + #clear_btn + 5))
    put(search_x, 3, search_btn, colors.black, colors.orange)
    add_zone(state, search_x, search_x + #search_btn - 1, 3, "search", "search")
    local clear_x = search_x + #search_btn + 1
    put(clear_x, 3, clear_btn, colors.black, colors.gray)
    add_zone(state, clear_x, clear_x + #clear_btn - 1, 3, "clear_search", "clear")

    for i = 0, list_height - 1 do
        local y = list_start + i
        clear_line(y)
        local idx = state.scroll + i + 1
        local name = songs[idx]
        if name then
            local is_playing = (state.now_playing == name)
            local is_fav = state.favorites[name] == true
            local fav_text = is_fav and "[Unf]" or "[Fav]"
            local play_text = is_playing and "[Now]" or "[Play]"
            local pl_song_text = state.view == "playlists" and "[Rem]" or "[List]"
            local row_bg = (i % 2 == 0) and colors.black or colors.gray
            local title_fg = is_playing and colors.lime or colors.white

            put(1, y, string.rep(" ", w), colors.white, row_bg)
            put(2, y, play_text, colors.black, colors.lightBlue)
            add_zone(state, 2, 2 + #play_text - 1, y, "play", name)

            put(2 + #play_text + 1, y, fav_text, colors.black, colors.orange)
            add_zone(state, 2 + #play_text + 1, 2 + #play_text + #fav_text, y, "fav", name)

            local pl_song_x = 2 + #play_text + #fav_text + 2
            put(pl_song_x, y, pl_song_text, colors.black, colors.lime)
            add_zone(state, pl_song_x, pl_song_x + #pl_song_text - 1, y, "plist_song", name)

            local song_x = pl_song_x + #pl_song_text + 2
            local prefix = is_fav and "* " or "  "
            local max_song_len = math.max(1, w - song_x - 1)
            local label = prefix .. name
            if #label > max_song_len then
                label = label:sub(1, math.max(1, max_song_len - 3)) .. "..."
            end
            put(song_x, y, label, title_fg, row_bg)
        end
    end

    put(1, footer_y - 1, string.rep(" ", w), colors.black, colors.lightGray)
    local source_tag = state.source_mode == "server" and "Server" or "GitHub"
    local status = state.now_playing and (state.paused and "Paused: " or "Playing: ") .. state.now_playing or "Idle"
    local voltxt = ("Vol %.1f"):format(state.volume)
    local search_tag = state.search_query ~= "" and (" | Search: " .. state.search_query) or ""
    local mid = " " .. source_tag .. " | " .. status .. " | " .. voltxt .. search_tag
    if #mid > w - 2 then mid = mid:sub(1, w - 2) end
    put(2, footer_y - 1, mid, colors.black, colors.lightGray)

    put(1, footer_y, string.rep(" ", w), colors.white, colors.black)
    local msg = state.message or ""
    if #msg > w - 2 then msg = msg:sub(1, w - 2) end
    put(2, footer_y, msg, colors.white, colors.black)

    set_colors()
end

local function find_zone(state, x, y)
    for _, z in ipairs(state.zones) do
        if z.y == y and x >= z.x1 and x <= z.x2 then
            return z
        end
    end
    return nil
end

local function queue_command(kind, value)
    os.queueEvent("mp3_cmd", kind, value)
end

local function prompt_text(state, title)
    local w, h = term.getSize()
    set_colors()
    term.setCursorPos(1, h)
    term.clearLine()
    local label = title .. ": "
    if #label > w - 1 then label = label:sub(1, w - 1) end
    term.write(label)
    local v = read()
    if not v then return nil end
    v = v:gsub("^%s+", ""):gsub("%s+$", "")
    state.dirty = true
    if v == "" then return nil end
    return v
end

local function cycle_playlist(state, dir)
    local names = ensure_active_playlist(state)
    if #names == 0 then
        state.message = "No playlists yet. Create one first."
        return
    end
    local current = 1
    for i, name in ipairs(names) do
        if name == state.active_playlist then current = i break end
    end
    local next_i = current + dir
    if next_i < 1 then next_i = #names end
    if next_i > #names then next_i = 1 end
    state.active_playlist = names[next_i]
    state.scroll = 0
    state.message = "Playlist: " .. state.active_playlist
end

local function create_playlist_prompt(state)
    local name = prompt_text(state, "New playlist name")
    if not name then
        state.message = "Create playlist canceled"
        return
    end
    if state.playlists[name] then
        state.message = "Playlist already exists: " .. name
        return
    end
    state.playlists[name] = {}
    state.active_playlist = name
    save_playlists_map(state.playlists)
    state.scroll = 0
    state.message = "Created playlist: " .. name
end

local function delete_playlist_prompt(state)
    ensure_active_playlist(state)
    if not state.active_playlist then
        state.message = "No playlist selected"
        return
    end
    local answer = prompt_text(state, "Type YES to delete " .. state.active_playlist)
    if answer ~= "YES" then
        state.message = "Delete canceled"
        return
    end
    state.playlists[state.active_playlist] = nil
    ensure_active_playlist(state)
    save_playlists_map(state.playlists)
    state.scroll = 0
    state.message = "Playlist deleted"
end

local function toggle_song_playlist_membership(state, song)
    ensure_active_playlist(state)
    if not state.active_playlist then
        create_playlist_prompt(state)
        ensure_active_playlist(state)
        if not state.active_playlist then
            state.message = "No playlist available"
            return
        end
    end

    local list = state.playlists[state.active_playlist]
    if not list then
        list = {}
        state.playlists[state.active_playlist] = list
    end

    if state.view == "playlists" then
        local out = {}
        local removed = false
        for _, name in ipairs(list) do
            if name == song then
                removed = true
            else
                out[#out + 1] = name
            end
        end
        state.playlists[state.active_playlist] = out
        state.message = removed and ("Removed from " .. state.active_playlist) or "Song not in playlist"
    else
        if contains_song(list, song) then
            state.message = "Already in " .. state.active_playlist
        else
            list[#list + 1] = song
            state.message = "Added to " .. state.active_playlist
        end
    end

    save_playlists_map(state.playlists)
    state.dirty = true
end

local function set_search_prompt(state)
    local q = prompt_text(state, "Search songs")
    if q == nil then
        state.message = "Search unchanged"
        return
    end
    state.search_query = q
    state.scroll = 0
    if q == "" then
        state.message = "Search cleared"
    else
        state.message = "Search: " .. q
    end
end

local function clear_search(state)
    state.search_query = ""
    state.scroll = 0
    state.message = "Search cleared"

local function audio_worker(state)
    local dfpwm = require("cc.audio.dfpwm")

    local current = {
        name = nil,
        res = nil,
        decode = nil,
        pending_pcm = nil,
        speakers = {},
        speaker_names = {},
    }

    local function refresh_speakers()
        current.speakers = collect_speakers()
        current.speaker_names = {}
        for _, spk in ipairs(current.speakers) do
            current.speaker_names[peripheral.getName(spk)] = true
        end
        return #current.speakers > 0
    end

    local function stop_all_speakers()
        for _, spk in ipairs(collect_speakers()) do
            pcall(function() spk.stop() end)
        end
        os.queueEvent("speaker_audio_empty")
    end

    local function stop_song(msg)
        if current.res then pcall(function() current.res.close() end) end
        stop_all_speakers()
        current.name = nil
        current.res = nil
        current.decode = nil
        current.pending_pcm = nil
        state.now_playing = nil
        state.paused = false
        state.message = msg or "Stopped"
        state.dirty = true
    end

    local function push_pending()
        if not current.pending_pcm then return true end
        local busy = false
        for _, spk in ipairs(current.speakers) do
            if not spk.playAudio(current.pending_pcm, state.volume) then
                busy = true
            end
        end
        if busy then return false end
        current.pending_pcm = nil
        return true
    end

    local function feed_audio()
        if not current.res or not current.decode then return end
        if state.paused then return end
        while true do
            if current.pending_pcm and not push_pending() then return end
            if current.pending_pcm then
                -- Sent the pending chunk; continue feeding.
            else
                local chunk = current.res.read(16 * 1024)
                if not chunk then
                    stop_song("Finished: " .. (current.name or ""))
                    return
                end
                current.pending_pcm = current.decode(chunk)
            end
        end
    end

    local function start_song(name)
        stop_song()
        if not refresh_speakers() then
            state.message = "No speakers found. Attach at least one speaker."
            state.dirty = true
            return
        end

        local active_base = active_base_for_mode(state.source_mode)
        local url = active_base .. "/output/" .. name .. "/audio.dfpwm"
        local res = http.get(url, nil, true)
        if not res then
            state.message = "Failed to fetch: " .. name
            state.dirty = true
            return
        end

        current.name = name
        current.res = res
        current.decode = dfpwm.make_decoder()
        current.pending_pcm = nil
        state.now_playing = name
        state.paused = false
        state.message = "Playing: " .. name
        state.dirty = true
        feed_audio()
    end

    while state.running do
        local ev, a, b = os.pullEvent()
        if ev == "mp3_cmd" then
            if a == "quit" then
                state.running = false
                stop_song("Bye")
            elseif a == "play" then
                start_song(b)
            elseif a == "stop" then
                stop_song("Stopped")
            elseif a == "pause" then
                if current.res then
                    state.paused = not state.paused
                    state.message = state.paused and "Paused" or "Resumed"
                    state.dirty = true
                    if not state.paused then feed_audio() end
                end
            elseif a == "volume" then
                state.volume = math.max(0.1, math.min(3.0, b or state.volume))
                state.message = ("Volume: %.1f"):format(state.volume)
                state.dirty = true
            end
        elseif ev == "speaker_audio_empty" then
            if current.speaker_names[a] then feed_audio() end
        end
    end
end

local function ui_worker(state)
    while state.running do
        draw_ui(state)
        local ev, a, b, c = os.pullEvent()

        if ev == "mouse_click" then
            local _, x, y = a, b, c
            local zone = find_zone(state, x, y)
            if zone then
                if zone.kind == "tab" then
                    state.view = zone.name
                    state.scroll = 0
                    if zone.name == "all" then
                        state.message = "Showing all songs"
                    elseif zone.name == "favorites" then
                        state.message = "Showing favorites"
                    else
                        ensure_active_playlist(state)
                        state.message = "Showing playlists"
                    end
                    state.dirty = true
                elseif zone.kind == "source" then
                    state.source_mode = zone.name
                    save_source_mode(zone.name)
                    queue_command("stop")
                    local ok, msg = reload_index_for_state(state)
                    if ok then
                        state.message = "Source: " .. (zone.name == "server" and "Server" or "GitHub") .. " | " .. msg
                    else
                        state.message = "Source error: " .. msg
                    end
                    state.dirty = true
                elseif zone.kind == "reload" then
                    local ok, msg = reload_index_for_state(state)
                    state.message = ok and ("Reloaded | " .. msg) or ("Reload error: " .. msg)
                    state.dirty = true
                elseif zone.kind == "search" then
                    set_search_prompt(state)
                    state.dirty = true
                elseif zone.kind == "clear_search" then
                    clear_search(state)
                    state.dirty = true
                elseif zone.kind == "plist_prev" then
                    cycle_playlist(state, -1)
                    state.dirty = true
                elseif zone.kind == "plist_next" then
                    cycle_playlist(state, 1)
                    state.dirty = true
                elseif zone.kind == "plist_new" then
                    create_playlist_prompt(state)
                    state.dirty = true
                elseif zone.kind == "plist_del" then
                    delete_playlist_prompt(state)
                    state.dirty = true
                elseif zone.kind == "play" then
                    state.message = "Loading: " .. zone.name
                    state.dirty = true
                    queue_command("play", zone.name)
                elseif zone.kind == "fav" then
                    local is_fav = state.favorites[zone.name] == true
                    if is_fav then
                        state.favorites[zone.name] = nil
                        state.message = "Removed favorite: " .. zone.name
                    else
                        state.favorites[zone.name] = true
                        state.message = "Added favorite: " .. zone.name
                    end
                    save_favorites_map(state.favorites)
                    state.dirty = true
                elseif zone.kind == "plist_song" then
                    toggle_song_playlist_membership(state, zone.name)
                    state.dirty = true
                end
            end
        elseif ev == "mouse_scroll" then
            local dir = a
            state.scroll = state.scroll + dir
            state.dirty = true
        elseif ev == "key" then
            local key = a
            if key == keys.q then
                queue_command("quit")
                state.running = false
            elseif key == keys.space then
                queue_command("pause")
            elseif key == keys.s then
                queue_command("stop")
            elseif key == keys.up then
                queue_command("volume", state.volume + 0.1)
            elseif key == keys.down then
                queue_command("volume", state.volume - 0.1)
            elseif key == keys.f then
                state.view = (state.view == "all") and "favorites" or "all"
                state.scroll = 0
                state.dirty = true
            elseif key == keys.l then
                state.view = "playlists"
                ensure_active_playlist(state)
                state.scroll = 0
                state.message = "Showing playlists"
                state.dirty = true
            elseif key == keys.n then
                create_playlist_prompt(state)
                state.dirty = true
            elseif key == keys.delete then
                delete_playlist_prompt(state)
                state.dirty = true
            elseif key == keys.left then
                if state.view == "playlists" then
                    cycle_playlist(state, -1)
                    state.dirty = true
                end
            elseif key == keys.right then
                if state.view == "playlists" then
                    cycle_playlist(state, 1)
                    state.dirty = true
                end
            elseif key == keys.slash then
                set_search_prompt(state)
                state.dirty = true
            elseif key == keys.c then
                clear_search(state)
                state.dirty = true
            elseif key == keys.pageUp then
                state.scroll = math.max(0, state.scroll - 5)
                state.dirty = true
            elseif key == keys.pageDown then
                state.scroll = state.scroll + 5
                state.dirty = true
            elseif key == keys.r then
                local ok, msg = reload_index_for_state(state)
                state.message = ok and ("Reloaded | " .. msg) or ("Reload error: " .. msg)
                state.dirty = true
            end
        elseif ev == "term_resize" then
            state.dirty = true
        elseif ev == "monitor_touch" then
            -- Ignored in terminal UI mode.
        end
    end
end

local function main()
    self_update()

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)

    local state = make_ui_state({ audio = {} })
    local ok, msg = reload_index_for_state(state)

    if not ok then
        local first_mode = state.source_mode
        local fallback_mode = (first_mode == "github") and "server" or "github"

        state.source_mode = fallback_mode
        local ok2, msg2 = reload_index_for_state(state)
        if ok2 then
            save_source_mode(fallback_mode)
            state.message = "Startup fallback to " .. fallback_mode .. " | " .. msg2
        else
            state.source_mode = first_mode
            state.message = "No tracks found on selected source. Click GitHub/Server then Reload."
        end
    else
        state.message = msg
    end

    parallel.waitForAny(
        function() ui_worker(state) end,
        function() audio_worker(state) end
    )

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    print("Player closed.")
end

main()
