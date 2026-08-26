#!/usr/bin/env python3
"""
roaring_cmd_rxd.py  v1.0
UDP command receiver for RoaringMic Windows client → Linux.
Listens on UDP 46002. Only accepts packets from CMD_ALLOWED_IP (default: 192.168.50.132).

Commands:
  swap     toggle MIC_SOURCE between b1_mic / b2_mic, restart moonlight-mic
  mute     mute the current MIC_SOURCE in PipeWire
  unmute   unmute the current MIC_SOURCE in PipeWire
  status   reply with ok:mic=<source>
"""

import datetime, os, pathlib, socket, subprocess, sys

PORT    = 46002
HOME    = pathlib.Path.home()
STATE   = HOME / '.config' / 'roaring' / 'mic_source'
DROPIN  = HOME / '.config/systemd/user/roaring-moonlight-mic.service.d/mic-source.conf'
SERVICE = 'roaring-moonlight-mic'
ALLOWED = os.environ.get('CMD_ALLOWED_IP', '192.168.50.132')
LOG     = HOME / '.cache' / 'roaring-cmd-rxd.log'


def log(msg: str):
    ts   = datetime.datetime.now().strftime('%H:%M:%S')
    line = f'[cmd-rxd] {ts} {msg}\n'
    sys.stdout.write(line)
    sys.stdout.flush()
    try:
        with LOG.open('a') as f:
            f.write(line)
    except Exception:
        pass


def current_source() -> str:
    try:
        return STATE.read_text().strip()
    except FileNotFoundError:
        return 'b1_mic'


def set_source(src: str):
    STATE.parent.mkdir(parents=True, exist_ok=True)
    STATE.write_text(src + '\n')
    DROPIN.parent.mkdir(parents=True, exist_ok=True)
    DROPIN.write_text(f'[Service]\nEnvironment=MIC_SOURCE={src}\n')
    subprocess.run(['systemctl', '--user', 'daemon-reload'],
                   check=False, capture_output=True)
    subprocess.run(['systemctl', '--user', 'restart', SERVICE],
                   check=False, capture_output=True)
    log(f'set MIC_SOURCE={src}, restarted {SERVICE}')


def handle(cmd: str, addr, sock: socket.socket):
    cmd = cmd.strip().lower()

    if cmd == 'swap':
        cur = current_source()
        new = 'b2_mic' if cur == 'b1_mic' else 'b1_mic'
        set_source(new)
        reply = f'ok:mic={new}'

    elif cmd == 'status':
        reply = f'ok:mic={current_source()}'

    elif cmd == 'mute':
        src = current_source()
        subprocess.run(['pactl', 'set-source-mute', src, '1'],
                       check=False, capture_output=True)
        log(f'muted {src}')
        reply = 'ok:muted'

    elif cmd == 'unmute':
        src = current_source()
        subprocess.run(['pactl', 'set-source-mute', src, '0'],
                       check=False, capture_output=True)
        log(f'unmuted {src}')
        reply = 'ok:unmuted'

    else:
        log(f'unknown cmd: {cmd!r}')
        reply = 'err:unknown'

    try:
        sock.sendto(reply.encode(), addr)
    except Exception:
        pass


def main():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(('0.0.0.0', PORT))
    log(f'listening on UDP {PORT}, allowed={ALLOWED}')
    while True:
        try:
            data, addr = sock.recvfrom(256)
            if addr[0] != ALLOWED:
                log(f'rejected packet from {addr[0]}')
                continue
            handle(data.decode('utf-8', errors='replace'), addr, sock)
        except Exception as e:
            log(f'error: {e}')


if __name__ == '__main__':
    main()
