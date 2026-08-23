-- CC:Tweaked MP3 Player - Bootstrap/Installer
-- Run this once in-game to install player.lua

local GITHUB_RAW = "https://raw.githubusercontent.com/ob-105/CCMP3/main"

local FILES = {
    { url = GITHUB_RAW .. "/player.lua", path = "player.lua" },
}

print("=== CC:Tweaked MP3 Player Installer ===")
print()

for _, file in ipairs(FILES) do
    io.write("Downloading " .. file.path .. "... ")
    local res = http.get(file.url)
    if res then
        local data = res.readAll()
        res.close()
        local f = fs.open(file.path, "w")
        f.write(data)
        f.close()
        print("OK")
    else
        print("FAILED")
        print("Could not reach: " .. file.url)
        print("Check HTTP is enabled and the URL is public.")
        return
    end
end

print()
print("Installation complete!")
print("Run with: lua player.lua")
