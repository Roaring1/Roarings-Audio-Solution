#!/usr/bin/env python3
"""
roaring_cmd_rxd.py  v1.0
UDP command receiver for RoaringMic Windows client → Linux.
Listens on UDP 46002. Only accepts packets from CMD_ALLOWED_IP (default: 192.168.50.132).

Commands:
  set-mic  explicitly select SM7B (through Carla) or A50 boom for B1
  swap     legacy toggle alias for clients that have not adopted set-mic
  mute     mute the B1 microphone source and verify the result
  unmute   unmute the B1 microphone source and verify the result
  status   report applied route state and observed B1 mute state
"""

import datetime, os, pathlib, socket, subprocess, sys

PORT    = 46002
HOME    = pathlib.Path.home()
ALLOWED = os.environ.get('CMD_ALLOWED_IP', '192.168.50.132')
MICCONF = HOME / '.config/hearth/roaring_mic_router.conf'


def log(msg: str):
    ts   = datetime.datetime.now().strftime('%H:%M:%S')
    line = f'[cmd-rxd] {ts} {msg}\n'
    # systemd owns the append-only file sink for this unit.
    sys.stdout.write(line)
    sys.stdout.flush()


def current_source() -> str:
    """The sender is pinned to B1; legacy mic_source files are not authoritative."""
    return 'b1_mic'


def allowed_peer(addr) -> bool:
    """Enforce the configured laptop address before parsing a command."""
    return bool(addr) and addr[0] == ALLOWED


def _read_conf() -> dict:
    values = {}
    try:
        for line in MICCONF.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith('#') or '=' not in line:
                continue
            key, _, val = line.partition('=')
            values[key.strip()] = val.strip().strip('"')
    except FileNotFoundError:
        pass
    return values


def _write_conf(updates: dict):
    """Rewrite in place, keeping comments, order and unknown keys.

    A shell daemon sources this file every three seconds, so it is written
    atomically: a half-written conf is a half-configured microphone.
    """
    lines = MICCONF.read_text().splitlines(keepends=True)
    seen = set()
    out = []
    for line in lines:
        key = line.split('=', 1)[0].strip()
        if key in updates:
            out.append(f'{key}="{updates[key]}"\n')
            seen.add(key)
        else:
            out.append(line)
    for key, val in updates.items():
        if key not in seen:
            out.append(f'{key}="{val}"\n')
    tmp = MICCONF.with_suffix('.conf.tmp')
    tmp.write_text(''.join(out))
    os.replace(tmp, MICCONF)


def requested_mic() -> str:
    """Which input the config requests for the active B1 bus."""
    conf = _read_conf()
    if conf.get('B1_ACTIVE', 'true') != 'true':
        return 'none'
    if conf.get('CARLA_TO_B1', 'false') == 'true':
        return 'SM7B'
    route = conf.get('B1_ROUTE', 'none')
    if route == 'both':
        return 'SM7B + A50 boom'
    if route == 'sm7b':
        return 'SM7B'
    if route == 'astro':
        return 'A50 boom'
    return 'none'


def applied_mic() -> str | None:
    """Return the input(s) proven connected to the active B1 bus."""
    conf = _read_conf()
    if conf.get('B1_ACTIVE', 'true') != 'true':
        return None

    if conf.get('CARLA_TO_B1', 'false') == 'true':
        try:
            graph = subprocess.run(
                ['pw-link', '-l'], check=True, capture_output=True,
                text=True, timeout=2).stdout
            current = ''
            links = set()
            for line in graph.splitlines():
                if line and not line[0].isspace():
                    current = line.strip()
                elif current:
                    peer = line.strip()
                    peer = peer.removeprefix('|->').removeprefix('|<-').strip()
                    links.add((current, peer))
            required = {
                ('sm7b_mono:capture_MONO', 'Carla:audio-in1'),
                ('sm7b_mono:capture_MONO', 'Carla:audio-in2'),
                ('Carla:audio-out1', 'mic_b1:playback_FL'),
                ('Carla:audio-out2', 'mic_b1:playback_FR'),
            }
            return 'SM7B' if required.issubset(links) else None
        except Exception as e:
            log(f'route status graph check failed: {e}')
            return None

    route = conf.get('B1_ROUTE', 'none')
    required_sources = []
    if route in ('sm7b', 'both'):
        required_sources.append(('sm7b_mono', 'SM7B'))
    if route in ('astro', 'both'):
        required_sources.append(('astro_mic_48k', 'A50 boom'))
    if not required_sources:
        return None

    try:
        modules = subprocess.run(
            ['pactl', 'list', 'short', 'modules'], check=True,
            capture_output=True, text=True, timeout=2).stdout
        active = {
            source for source, _label in required_sources
            if any('module-loopback' in line and f'source={source}' in line
                   and 'sink=mic_b1' in line for line in modules.splitlines())
        }
        if len(active) != len(required_sources):
            return None
        return ' + '.join(label for _source, label in required_sources)
    except Exception as e:
        log(f'route status loopback check failed: {e}')
        return None


def set_mic(name: str):
    if name == 'SM7B':
        _write_conf({'CARLA_TO_B1': 'true', 'B1_ROUTE': 'none', 'B1_ACTIVE': 'true'})
    else:
        _write_conf({'CARLA_TO_B1': 'false', 'B1_ROUTE': 'astro', 'B1_ACTIVE': 'true'})
    # No restart: roaring_mic_routesd.sh applies the conf on its next pass.
    log(f'mic input set to {name}')


def handle(cmd: str, addr, sock: socket.socket):
    cmd = cmd.strip().lower()

    if cmd == 'swap':
        # Retained for older clients. New clients use set-mic:<target> to avoid
        # a late acknowledgement turning a retried toggle into a double swap.
        new = 'A50 boom' if requested_mic() == 'SM7B' else 'SM7B'
        set_mic(new)
        reply = f'accepted:mic={new}'

    elif cmd.startswith('set-mic:'):
        requested = cmd.partition(':')[2].strip()
        targets = {'sm7b': 'SM7B', 'a50 boom': 'A50 boom'}
        new = targets.get(requested)
        if new is None:
            reply = 'err:set-mic:target'
        else:
            if requested_mic() != new:
                set_mic(new)
            else:
                log(f'mic input already set to {new}')
            reply = f'accepted:mic={new}'

    elif cmd == 'status':
        applied = applied_mic()
        requested = requested_mic()
        # An intentionally un-routed or inactive bus is a confirmed state,
        # not a route still waiting for the daemon to apply it.
        route_state = 'ok' if requested == 'none' or applied else 'pending'
        route_name = applied or requested
        try:
            mute = subprocess.run(
                ['pactl', 'get-source-mute', current_source()],
                check=True, capture_output=True, text=True, timeout=3).stdout.strip().lower().split()[-1]
            if mute not in ('yes', 'no'):
                mute = 'unknown'
        except Exception as e:
            log(f'status mute query failed: {e}')
            mute = 'unknown'
        reply = f'{route_state}:mic={route_name}:muted={mute}'

    elif cmd in ('mute', 'unmute'):
        src = current_source()
        target = '1' if cmd == 'mute' else '0'
        try:
            result = subprocess.run(
                ['pactl', 'set-source-mute', src, target],
                check=False, capture_output=True, text=True, timeout=3)
            if result.returncode != 0:
                detail = (result.stderr or result.stdout or 'pactl failed').strip()
                log(f'{cmd} FAILED for {src}: {detail}')
                reply = f'err:{cmd}:pactl'
            else:
                check = subprocess.run(
                    ['pactl', 'get-source-mute', src],
                    check=False, capture_output=True, text=True, timeout=3)
                expected = 'yes' if target == '1' else 'no'
                actual = check.stdout.strip().lower().split()[-1] if check.stdout.strip() else ''
                if check.returncode != 0 or actual != expected:
                    log(f'{cmd} verification FAILED for {src}: {check.stdout.strip()} {check.stderr.strip()}')
                    reply = f'err:{cmd}:verify'
                else:
                    log(f'{cmd} verified for {src}')
                    reply = f'ok:{cmd}:source={src}'
        except Exception as e:
            log(f'{cmd} exception for {src}: {e}')
            reply = f'err:{cmd}:exception'


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
            if not allowed_peer(addr):
                log(f'rejected packet from {addr[0]}')
                continue
            handle(data.decode('utf-8', errors='replace'), addr, sock)
        except Exception as e:
            log(f'error: {e}')


if __name__ == '__main__':
    main()
