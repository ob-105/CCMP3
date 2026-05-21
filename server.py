#!/usr/bin/env python3
"""
CCMP3 local media server.

Serves this project's output/ folder so CC:Tweaked can stream audio directly
from your PC or a Cloudflare quick tunnel URL.

Usage:
  python server.py
  python server.py --tunnel

Requirements:
  pip install flask

Optional for --tunnel:
  cloudflared on PATH
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import threading
import time
from pathlib import Path

from flask import Flask, abort, jsonify, send_from_directory

DEFAULT_PORT = 8765


class CloudflaredTunnel:
    def __init__(self, port: int):
        self.port = port
        self.proc: subprocess.Popen[str] | None = None
        self.url: str | None = None
        self._reader_thread: threading.Thread | None = None
        self._stop = threading.Event()

    def start(self) -> bool:
        if shutil.which("cloudflared") is None:
            print("[cloudflared] Not found on PATH.")
            print("Install: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/")
            return False

        cmd = ["cloudflared", "tunnel", "--url", f"http://127.0.0.1:{self.port}"]
        try:
            self.proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )
        except Exception as exc:
            print(f"[cloudflared] Failed to start: {exc}")
            return False

        pat = re.compile(r"https://[a-z0-9\-]+\.trycloudflare\.com")

        def _reader() -> None:
            assert self.proc and self.proc.stdout
            for line in self.proc.stdout:
                if self._stop.is_set():
                    break
                text = line.rstrip()
                print(f"[cf] {text}")
                if self.url is None:
                    m = pat.search(text)
                    if m:
                        self.url = m.group(0)
                        print(f"[cloudflared] Public URL: {self.url}")

        self._reader_thread = threading.Thread(target=_reader, daemon=True)
        self._reader_thread.start()
        return True

    def stop(self) -> None:
        self._stop.set()
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=3)
            except Exception:
                self.proc.kill()
        self.proc = None


def load_index_audio_names(output_dir: Path) -> list[str]:
    index_path = output_dir / "index.lua"
    if not index_path.exists():
        return []

    text = index_path.read_text(encoding="utf-8", errors="ignore")
    m = re.search(r"audio\s*=\s*\{([^}]*)\}", text, re.DOTALL)
    if not m:
        return []

    names = re.findall(r'"([^"]+)"', m.group(1))
    return names


def create_app(base_dir: Path) -> Flask:
    app = Flask(__name__)
    output_dir = base_dir / "output"

    @app.route("/")
    def index() -> str:
        names = load_index_audio_names(output_dir)
        rows = ["<h2>CCMP3 Local Server</h2>"]
        rows.append(f"<p>Tracks: {len(names)}</p>")
        rows.append("<ul>")
        for n in names:
            rows.append(f"<li>{n}</li>")
        rows.append("</ul>")
        return "\n".join(rows)

    @app.route("/health")
    def health() -> tuple[dict[str, str], int]:
        return {"status": "ok"}, 200

    @app.route("/output/<path:filename>")
    def serve_output(filename: str):
        try:
            return send_from_directory(output_dir, filename)
        except Exception:
            abort(404)

    @app.route("/player.lua")
    def serve_player():
        try:
            return send_from_directory(base_dir, "player.lua")
        except Exception:
            abort(404)

    @app.route("/install.lua")
    def serve_install():
        try:
            return send_from_directory(base_dir, "install.lua")
        except Exception:
            abort(404)

    @app.route("/meta")
    def meta():
        names = load_index_audio_names(output_dir)
        return jsonify(
            {
                "tracks": len(names),
                "port": DEFAULT_PORT,
                "base": f"http://127.0.0.1:{DEFAULT_PORT}",
            }
        )

    return app


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Run the CCMP3 local HTTP server")
    p.add_argument("--host", default="127.0.0.1", help="Flask bind host")
    p.add_argument("--port", type=int, default=DEFAULT_PORT, help="Flask bind port")
    p.add_argument("--tunnel", action="store_true", help="Also start cloudflared quick tunnel")
    return p.parse_args()


def main() -> int:
    args = parse_args()
    base_dir = Path(__file__).resolve().parent

    app = create_app(base_dir)
    tunnel = CloudflaredTunnel(args.port) if args.tunnel else None

    if tunnel is not None:
        print("[server] Starting cloudflared...")
        tunnel.start()

    print(f"[server] Serving: http://{args.host}:{args.port}")
    print("[server] Routes: /output/*, /player.lua, /install.lua")
    print("[server] Stop with Ctrl+C")

    try:
        app.run(host=args.host, port=args.port, use_reloader=False, threaded=True)
    except KeyboardInterrupt:
        pass
    finally:
        if tunnel is not None:
            print("[server] Stopping cloudflared...")
            tunnel.stop()
        time.sleep(0.1)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
