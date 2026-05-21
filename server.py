#!/usr/bin/env python3
"""
CCMP3 all-in-one server (old-project style, no screenshare).

Features:
- Convert audio files from input/ into output/ DFPWM format
- Serve output/ and scripts via local Flask server
- Optional Cloudflare quick tunnel integration

Usage:
  python server.py
"""

from __future__ import annotations

import multiprocessing
import os
import queue
import re
import shutil
import subprocess
import sys
import threading
from pathlib import Path

sys.path.insert(0, os.path.dirname(__file__))
from convert_audio import (  # noqa: E402
    SUPPORTED_EXTS,
    convert_audio_to_dfpwm,
    discover_inputs,
    sanitize_name,
    write_index,
    write_manifest,
)


FLASK_PORT = 8765
_flask_thread = None
_flask_app = None
_cf_proc = None


def _load_index_audio_names(output_dir: Path) -> list[str]:
    index_path = output_dir / "index.lua"
    if not index_path.exists():
        return []
    text = index_path.read_text(encoding="utf-8", errors="ignore")
    m = re.search(r"audio\s*=\s*\{([^}]*)\}", text, re.DOTALL)
    if not m:
        return []
    return re.findall(r'"([^"]+)"', m.group(1))


def _write_player_source_url(base_dir: Path, url: str) -> None:
    path = base_dir / "mp3_source_url.txt"
    path.write_text(url.strip() + "\n", encoding="utf-8")


def _rebuild_index_from_output(output_dir: Path) -> list[str]:
    names: list[str] = []
    if not output_dir.exists():
        return names

    for child in output_dir.iterdir():
        if not child.is_dir():
            continue
        if (child / "audio.dfpwm").exists() and (child / "manifest.lua").exists():
            names.append(child.name)

    names = sorted(set(names), key=str.lower)
    write_index(output_dir / "index.lua", names)
    return names


def convert_all_audio(base_dir: Path, log_fn) -> None:
    input_dir = base_dir / "input"
    output_dir = base_dir / "output"

    files = discover_inputs(input_dir)
    if not files:
        log_fn("No supported audio files found in input/.")
        return

    log_fn(f"=== Converting {len(files)} file(s) ===")
    for src in files:
        name = sanitize_name(src.stem)
        target_dir = output_dir / name
        audio_out = target_dir / "audio.dfpwm"
        manifest_out = target_dir / "manifest.lua"

        log_fn(f"Converting: {src.name}")
        duration = convert_audio_to_dfpwm(src, audio_out)

        manifest = {
            "name": name,
            "has_audio": "true",
            "has_video": "false",
            "duration": round(duration, 2),
            "frame_count": 0,
            "fps": 0,
            "width": 0,
            "height": 0,
            "monitors_x": 0,
            "monitors_y": 0,
            "frame_ext": "",
        }
        write_manifest(manifest_out, manifest)

    names = _rebuild_index_from_output(output_dir)
    log_fn(f"Index updated. Audio tracks: {len(names)}")
    log_fn("Done.")


def _make_flask_app(base_dir: Path):
    try:
        from flask import Flask, abort, jsonify, send_from_directory
    except ImportError:
        return None

    app = Flask(__name__)
    output_dir = base_dir / "output"

    @app.route("/")
    def index() -> str:
        names = _load_index_audio_names(output_dir)
        rows = ["<h2>CCMP3 Local Server</h2>"]
        rows.append(f"<p>Tracks: {len(names)}</p>")
        rows.append("<ul>")
        for n in names:
            rows.append(f"<li>{n}</li>")
        rows.append("</ul>")
        return "\n".join(rows)

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
        names = _load_index_audio_names(output_dir)
        return jsonify({
            "tracks": len(names),
            "base": f"http://127.0.0.1:{FLASK_PORT}",
            "supported_exts": sorted(SUPPORTED_EXTS),
        })

    return app


def start_flask(base_dir: Path, log_fn) -> bool:
    global _flask_thread, _flask_app

    if _flask_thread and _flask_thread.is_alive():
        log_fn(f"[server] Flask already running on http://127.0.0.1:{FLASK_PORT}/")
        return True

    _flask_app = _make_flask_app(base_dir)
    if _flask_app is None:
        log_fn("[server] Flask not installed. Run: pip install flask")
        return False

    def _run():
        try:
            _flask_app.run(host="127.0.0.1", port=FLASK_PORT, use_reloader=False, threaded=True)
        except Exception as exc:
            log_fn(f"[server] Flask error: {exc}")

    _flask_thread = threading.Thread(target=_run, daemon=True)
    _flask_thread.start()
    log_fn(f"[server] Flask running on http://127.0.0.1:{FLASK_PORT}/")
    return True


def start_cloudflared(url_callback, log_fn):
    global _cf_proc
    if shutil.which("cloudflared") is None:
        log_fn("[cloudflared] Not found on PATH. Install from: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/")
        return None

    try:
        proc = subprocess.Popen(
            ["cloudflared", "tunnel", "--url", f"http://127.0.0.1:{FLASK_PORT}"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        _cf_proc = proc
    except Exception as exc:
        log_fn(f"[cloudflared] Failed to start: {exc}")
        return None

    url_pattern = re.compile(r"https://[a-z0-9\-]+\.trycloudflare\.com")

    def _reader():
        assert proc.stdout is not None
        for line in proc.stdout:
            text = line.rstrip()
            log_fn(f"[cf] {text}")
            m = url_pattern.search(text)
            if m:
                url_callback(m.group(0))

    threading.Thread(target=_reader, daemon=True).start()
    return proc


def stop_cloudflared():
    global _cf_proc
    if _cf_proc and _cf_proc.poll() is None:
        _cf_proc.terminate()
        try:
            _cf_proc.wait(timeout=3)
        except Exception:
            _cf_proc.kill()
    _cf_proc = None


def launch_gui():
    import tkinter as tk
    from tkinter import scrolledtext, ttk
    import traceback

    base_dir = Path(__file__).resolve().parent

    root = tk.Tk()
    root.title("CCMP3 Server")
    root.resizable(False, False)

    notebook = ttk.Notebook(root)
    notebook.pack(fill="both", expand=True)

    # =========================================================
    # TAB 1 - CONVERT
    # =========================================================
    tab_convert = ttk.Frame(notebook)
    notebook.add(tab_convert, text="  Convert  ")

    sf = ttk.LabelFrame(tab_convert, text="Input", padding=10)
    sf.pack(fill="x", padx=12, pady=(12, 6))

    ttk.Label(sf, text="Input folder:").grid(row=0, column=0, sticky="w")
    ttk.Label(sf, text=str(base_dir / "input"), foreground="#555").grid(row=0, column=1, sticky="w", padx=(6, 0))

    ttk.Label(sf, text="Output folder:").grid(row=1, column=0, sticky="w")
    ttk.Label(sf, text=str(base_dir / "output"), foreground="#555").grid(row=1, column=1, sticky="w", padx=(6, 0))

    ttk.Label(sf, text="Supported:", foreground="#555").grid(row=2, column=0, sticky="w")
    ttk.Label(sf, text=", ".join(sorted(SUPPORTED_EXTS)), foreground="#555").grid(row=2, column=1, sticky="w", padx=(6, 0))

    lf = ttk.LabelFrame(tab_convert, text="Conversion Log", padding=10)
    lf.pack(fill="both", expand=True, padx=12, pady=6)

    log_box = scrolledtext.ScrolledText(lf, height=15, width=76, state="disabled", font=("Consolas", 9))
    log_box.pack(fill="both", expand=True)

    log_queue = queue.Queue()

    class QueueWriter:
        def write(self, text):
            if text and text.strip():
                log_queue.put(text.rstrip())

        def flush(self):
            return None

    def poll_convert_log():
        while not log_queue.empty():
            msg = log_queue.get_nowait()
            log_box.configure(state="normal")
            log_box.insert(tk.END, msg + "\n")
            log_box.see(tk.END)
            log_box.configure(state="disabled")
        root.after(120, poll_convert_log)

    root.after(120, poll_convert_log)

    def run_conversion():
        old_stdout = sys.stdout
        old_cwd = os.getcwd()
        sys.stdout = QueueWriter()
        try:
            os.chdir(base_dir)
            convert_all_audio(base_dir, print)
        except Exception as exc:
            print(f"Error: {exc}\n{traceback.format_exc()}")
        finally:
            sys.stdout = old_stdout
            os.chdir(old_cwd)
            root.after(0, lambda: convert_btn.configure(state="normal"))

    convert_btn = ttk.Button(tab_convert, text="Convert Input Folder", width=24,
                             command=lambda: [convert_btn.configure(state="disabled"),
                                              threading.Thread(target=run_conversion, daemon=True).start()])
    convert_btn.pack(pady=(0, 10))

    # =========================================================
    # TAB 2 - SERVER
    # =========================================================
    tab_server = ttk.Frame(notebook)
    notebook.add(tab_server, text="  Server  ")

    sf2 = ttk.LabelFrame(tab_server, text="Cloudflare Quick Tunnel", padding=14)
    sf2.pack(fill="x", padx=12, pady=(12, 6))

    status_var = tk.StringVar(value="Stopped")
    status_label = ttk.Label(sf2, textvariable=status_var, foreground="#c00", font=("", 10, "bold"))
    status_label.grid(row=0, column=0, columnspan=4, sticky="w", pady=(0, 8))

    ttk.Label(sf2, text="Tunnel URL:").grid(row=1, column=0, sticky="w")
    url_var = tk.StringVar(value="")
    url_entry = ttk.Entry(sf2, textvariable=url_var, width=48, state="readonly")
    url_entry.grid(row=1, column=1, padx=(6, 6), sticky="w")

    def copy_url():
        u = url_var.get()
        if u:
            root.clipboard_clear()
            root.clipboard_append(u)
            copy_btn.configure(text="Copied!")
            root.after(1200, lambda: copy_btn.configure(text="Copy"))

    copy_btn = ttk.Button(sf2, text="Copy", width=7, command=copy_url)
    copy_btn.grid(row=1, column=2)

    def use_tunnel_url():
        u = url_var.get().strip()
        if not u:
            server_log_fn("[server] No tunnel URL available yet.")
            return
        _write_player_source_url(base_dir, u)
        server_log_fn(f"[server] Wrote mp3_source_url.txt -> {u}")

    use_tunnel_btn = ttk.Button(sf2, text="Use in Player", width=14, command=use_tunnel_url)
    use_tunnel_btn.grid(row=1, column=3, padx=(6, 0))

    local_frame = ttk.Frame(sf2)
    local_frame.grid(row=2, column=0, columnspan=4, sticky="w", pady=(8, 0))

    local_url = f"http://127.0.0.1:{FLASK_PORT}"
    ttk.Label(local_frame, text=f"Local URL: {local_url}", foreground="#555").pack(side="left")

    def use_local_url():
        _write_player_source_url(base_dir, local_url)
        server_log_fn(f"[server] Wrote mp3_source_url.txt -> {local_url}")

    ttk.Button(local_frame, text="Use Local", width=10, command=use_local_url).pack(side="left", padx=(8, 0))

    ttk.Label(sf2, text="Server tab handles hosting and tunnel. No screen sharing included.",
              foreground="#555").grid(row=3, column=0, columnspan=4, sticky="w", pady=(8, 0))

    slf = ttk.LabelFrame(tab_server, text="Server Log", padding=10)
    slf.pack(fill="both", expand=True, padx=12, pady=6)

    server_log = scrolledtext.ScrolledText(slf, height=12, width=76, state="disabled", font=("Consolas", 9))
    server_log.pack(fill="both", expand=True)

    srv_log_queue = queue.Queue()

    def server_log_fn(msg):
        srv_log_queue.put(msg)

    def poll_server_log():
        while not srv_log_queue.empty():
            m = srv_log_queue.get_nowait()
            server_log.configure(state="normal")
            server_log.insert(tk.END, m + "\n")
            server_log.see(tk.END)
            server_log.configure(state="disabled")
        root.after(150, poll_server_log)

    root.after(150, poll_server_log)

    _server_running = threading.Event()

    def start_server(with_tunnel: bool):
        if _server_running.is_set():
            return
        _server_running.set()
        start_btn.configure(state="disabled")
        start_tunnel_btn.configure(state="disabled")
        stop_btn.configure(state="normal")
        status_var.set("Starting Flask...")
        status_label.configure(foreground="#a60")

        ok = start_flask(base_dir, server_log_fn)
        if not ok:
            status_var.set("Flask missing (pip install flask)")
            status_label.configure(foreground="#c00")
            _server_running.clear()
            start_btn.configure(state="normal")
            start_tunnel_btn.configure(state="normal")
            stop_btn.configure(state="disabled")
            return

        if not with_tunnel:
            status_var.set("Running local only")
            status_label.configure(foreground="#060")
            return

        status_var.set("Starting cloudflared...")

        def on_url(url):
            url_var.set(url)
            root.after(0, lambda: status_var.set("Running with tunnel"))
            root.after(0, lambda: status_label.configure(foreground="#060"))
            server_log_fn(f"[server] Tunnel URL: {url}")

        proc = start_cloudflared(on_url, server_log_fn)
        if proc is None:
            status_var.set("cloudflared not found")
            status_label.configure(foreground="#c00")

    def stop_server():
        stop_cloudflared()
        url_var.set("")
        status_var.set("Stopped")
        status_label.configure(foreground="#c00")
        _server_running.clear()
        start_btn.configure(state="normal")
        start_tunnel_btn.configure(state="normal")
        stop_btn.configure(state="disabled")
        server_log_fn("[server] Tunnel stopped. Flask may still be running in this session.")

    btn_frame = ttk.Frame(tab_server)
    btn_frame.pack(pady=(0, 10))

    start_btn = ttk.Button(
        btn_frame,
        text="Start Local Server",
        width=20,
        command=lambda: threading.Thread(target=lambda: start_server(False), daemon=True).start(),
    )
    start_btn.pack(side="left", padx=6)

    start_tunnel_btn = ttk.Button(
        btn_frame,
        text="Start + Tunnel",
        width=20,
        command=lambda: threading.Thread(target=lambda: start_server(True), daemon=True).start(),
    )
    start_tunnel_btn.pack(side="left", padx=6)

    stop_btn = ttk.Button(btn_frame, text="Stop Tunnel", width=20, command=stop_server, state="disabled")
    stop_btn.pack(side="left", padx=6)

    def on_close():
        stop_cloudflared()
        root.destroy()

    root.protocol("WM_DELETE_WINDOW", on_close)
    root.mainloop()


if __name__ == "__main__":
    multiprocessing.freeze_support()
    launch_gui()
