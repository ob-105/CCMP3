# CC:Tweaked MP3 Player (Project Starter)

This is a clean, audio-first project based on your older MP3/MP4 setup.
It keeps the same overall workflow, but removes video conversion/playback so it is easier to maintain.

## What this project includes

- `convert_audio.py`: Converts audio files to `audio.dfpwm` + writes manifests + updates `output/index.lua`.
- `player.lua`: In-game CC:Tweaked audio player (speaker playback).
- `install.lua`: One-time installer for downloading `player.lua` to your computer in-game.
- `input/`: Drop source songs here (`.mp3`, `.wav`, `.flac`, `.ogg`, `.m4a`, `.mp4`).
- `output/`: Generated CC media folders and index.

## 1. Prepare your PC tools

- Install Python 3.10+.
- Install `ffmpeg` and ensure it is on `PATH`.
- Install Flask for local hosting: `pip install flask`

## 2. Convert songs

From this folder, run:

```bash
python convert_audio.py
```

Optional paths:

```bash
python convert_audio.py --input input --output output
```

Each song gets:

- `output/<song_name>/audio.dfpwm`
- `output/<song_name>/manifest.lua`

And the global index gets updated:

- `output/index.lua`

## 3. Host files for CC:Tweaked HTTP

Host this project in a GitHub repo (or any static host). The player reads from:

- `<BASE_URL>/output/index.lua`
- `<BASE_URL>/output/<song_name>/manifest.lua`
- `<BASE_URL>/output/<song_name>/audio.dfpwm`

Current repo raw base URL:

- `https://raw.githubusercontent.com/ob-105/CCMP3/main`

That URL is already set in:

- `player.lua`
- `install.lua`

## 4. Install in-game

On your CC computer:

```lua
wget https://raw.githubusercontent.com/ob-105/CCMP3/main/install.lua install.lua
lua install.lua
```

Then run:

```lua
lua player.lua
```

## 5. Local server (faster than GitHub)

Run the local HTTP server from this folder:

`python server.py`

Or expose it publicly via Cloudflare quick tunnel:

`python server.py --tunnel`

The player can use an override source URL saved on the CC computer in:

- `mp3_source_url.txt`

If this file exists, player uses that URL instead of GitHub.

Examples for `mp3_source_url.txt`:

- Local LAN server: `http://192.168.1.50:8765`
- Cloudflare tunnel: `https://your-subdomain.trycloudflare.com`

Quick in-game setup:

1. `edit mp3_source_url.txt`
2. Paste URL only (no trailing slash needed)
3. Save and run `lua player.lua`

## Notes

- Works best with multiple speakers, but one speaker is enough.
- Keyboard controls while playing:
  - `space`: pause/resume
  - `q`: stop current song
  - `up`: volume up
  - `down`: volume down
