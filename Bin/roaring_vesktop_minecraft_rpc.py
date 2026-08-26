#!/usr/bin/env python3
# roaring_vesktop_minecraft_rpc.py  v1.0
# Watches the host process table for a running Minecraft (Java or Bedrock)
# client and pushes a Discord Rich Presence update straight over the
# discord-ipc socket, bypassing Vesktop's (flatpak-sandboxed, PID-namespace
# isolated) automatic game-process detection, which can never see host
# processes from inside the sandbox.
#
# Requires a Discord application client ID, set via MINECRAFT_RPC_CLIENT_ID
# in the systemd unit's [Service] Environment=. Create one free at
# https://discord.com/developers/applications -> New Application -> copy
# "Application ID". For the Minecraft icon to show, go to that app's
# Rich Presence -> Art Assets and upload an image with asset key "minecraft".

import json
import os
import re
import socket
import struct
import sys
import time
import uuid

CLIENT_ID = os.environ.get("MINECRAFT_RPC_CLIENT_ID", "")
POLL_SECONDS = 10
LARGE_IMAGE_KEY = "minecraft"

LOG = os.path.expanduser("~/.cache/roaring-vesktop-minecraft-rpc.log")
os.makedirs(os.path.dirname(LOG), exist_ok=True)


def log(msg):
    line = f"[minecraft-rpc] {time.strftime('%H:%M:%S')} {msg}"
    print(line, flush=True)
    with open(LOG, "a") as f:
        f.write(line + "\n")


# --- process detection -------------------------------------------------

JAVA_ENTRY_PATTERNS = [
    r"org\.prismlauncher\.EntryPoint",
    r"net\.minecraft\.client\.main\.Main",
    r"net\.minecraft\.launchwrapper\.Launch",
    r"cpw\.mods\.bootstraplauncher\.BootstrapLauncher",
]
JAR_VERSION_RE = re.compile(r"minecraft-([\w.\-]+)-client\.jar")
INSTANCE_RE = re.compile(r"/instances/([^/]+)/")
BEDROCK_PATTERNS = [r"mcpelauncher-client"]


def find_minecraft():
    import psutil

    for proc in psutil.process_iter(["pid", "cmdline", "create_time"]):
        try:
            cmdline = proc.info["cmdline"]
            if not cmdline:
                continue
            full = " ".join(cmdline)
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue

        if any(re.search(p, full) for p in JAVA_ENTRY_PATTERNS):
            version = None
            m = JAR_VERSION_RE.search(full)
            if m:
                version = m.group(1)
            instance = None
            m = INSTANCE_RE.search(full)
            if m:
                instance = m.group(1)
            return {
                "edition": "java",
                "pid": proc.info["pid"],
                "start": proc.info["create_time"],
                "version": version,
                "instance": instance,
            }

        if any(re.search(p, full) for p in BEDROCK_PATTERNS):
            return {
                "edition": "bedrock",
                "pid": proc.info["pid"],
                "start": proc.info["create_time"],
                "version": None,
                "instance": None,
            }

    return None


def build_activity(meta):
    if meta["edition"] == "java":
        details = f"Minecraft {meta['version']}" if meta["version"] else "Minecraft Java Edition"
    else:
        details = "Minecraft Bedrock Edition"

    activity = {
        "details": details,
        "timestamps": {"start": int(meta["start"])},
        "assets": {
            "large_image": LARGE_IMAGE_KEY,
            "large_text": "Minecraft",
        },
    }
    if meta.get("instance"):
        activity["state"] = meta["instance"]
    return activity


# --- discord IPC --------------------------------------------------------

class IPCError(Exception):
    pass


def connect_ipc():
    runtime = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    last_err = None
    for i in range(10):
        path = f"{runtime}/discord-ipc-{i}"
        if not os.path.exists(path):
            continue
        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.connect(path)
            return sock
        except OSError as e:
            last_err = e
            continue
    raise IPCError(f"no discord-ipc socket found ({last_err})")


def send_frame(sock, op, payload):
    data = json.dumps(payload).encode()
    sock.sendall(struct.pack("<II", op, len(data)) + data)


def recv_frame(sock):
    header = b""
    while len(header) < 8:
        chunk = sock.recv(8 - len(header))
        if not chunk:
            raise IPCError("socket closed during header read")
        header += chunk
    op, length = struct.unpack("<II", header)
    data = b""
    while len(data) < length:
        chunk = sock.recv(length - len(data))
        if not chunk:
            raise IPCError("socket closed during payload read")
        data += chunk
    return op, json.loads(data) if data else None


def handshake(sock):
    send_frame(sock, 0, {"v": 1, "client_id": CLIENT_ID})
    op, resp = recv_frame(sock)
    if not resp or resp.get("evt") != "READY":
        raise IPCError(f"handshake failed: {resp}")


def set_activity(sock, activity):
    send_frame(
        sock,
        1,
        {
            "cmd": "SET_ACTIVITY",
            "args": {"pid": os.getpid(), "activity": activity},
            "nonce": str(uuid.uuid4()),
        },
    )
    recv_frame(sock)


# --- main loop -----------------------------------------------------------

def main():
    if not CLIENT_ID:
        log("MINECRAFT_RPC_CLIENT_ID not set — see header comment. Idling.")
        while True:
            time.sleep(3600)

    sock = None
    last_meta = None

    while True:
        try:
            meta = find_minecraft()

            if meta and not last_meta:
                if sock is None:
                    sock = connect_ipc()
                    handshake(sock)
                set_activity(sock, build_activity(meta))
                log(f"started: {meta}")

            elif meta and last_meta and (
                meta["instance"] != last_meta["instance"]
                or meta["version"] != last_meta["version"]
                or meta["edition"] != last_meta["edition"]
            ):
                set_activity(sock, build_activity(meta))
                log(f"updated: {meta}")

            elif not meta and last_meta:
                if sock is not None:
                    set_activity(sock, None)
                log("stopped")

            last_meta = meta

        except IPCError as e:
            log(f"IPC error: {e}, will reconnect")
            try:
                if sock:
                    sock.close()
            except OSError:
                pass
            sock = None
        except Exception as e:
            log(f"unexpected error: {e}")
            try:
                if sock:
                    sock.close()
            except OSError:
                pass
            sock = None

        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
