#!/usr/bin/env python3
import re
import subprocess
import sys
import time
import mido

# ---- CONFIG ----
MIDI_PORT_HINT = "LPD8"       # adjust if needed (run: python3 -c "import mido; print(mido.get_input_names())")
CC_TO_BUS = {
    1: "VM-GAME",
    2: "VM-CHAT",
    3: "VM-MUSIC",
}
# Optional: a pad/CC to toggle Scarlett mirror (uncomment after you confirm what it sends)
# TOGGLE_CC = 8
TOGGLE_SCRIPT = "/home/roaring/bin/toggle_scarlett_speakers.sh"
# ----------------

def sh(cmd: list[str]) -> str:
    return subprocess.check_output(cmd, text=True)

def get_sink_ids_by_description() -> dict[str, int]:
    """
    Parses 'wpctl status' and returns { "VM-GAME": 123, ... }
    """
    txt = sh(["wpctl", "status"])
    sinks_section = False
    out = {}

    # lines look like: "  *  103. Astro A50 Game [vol: 1.00]"
    # or:             "      97. VM-GAME [vol: 1.00]"
    line_re = re.compile(r"^\s*(\*?\s*)?(\d+)\.\s+(.+?)\s+\[vol:")

    for line in txt.splitlines():
        if line.strip().startswith("Sinks:"):
            sinks_section = True
            continue
        if sinks_section and line.strip().startswith("Sources:"):
            break
        if not sinks_section:
            continue

        m = line_re.match(line)
        if not m:
            continue
        sink_id = int(m.group(2))
        name = m.group(3).strip()
        out[name] = sink_id

    return out

def find_midi_port() -> str:
    ports = mido.get_input_names()
    for p in ports:
        if MIDI_PORT_HINT.lower() in p.lower():
            return p
    raise RuntimeError(f"Could not find MIDI input containing '{MIDI_PORT_HINT}'. Ports: {ports}")

def set_volume(node_id: int, value_0_127: int):
    pct = int(round((value_0_127 / 127.0) * 100))
    sh(["wpctl", "set-volume", str(node_id), f"{pct}%"])

def main():
    print("Scanning PipeWire sinks...")
    sinks = get_sink_ids_by_description()

    bus_ids = {}
    for cc, bus in CC_TO_BUS.items():
        if bus not in sinks:
            print(f"[!] Can't find sink named '{bus}' in wpctl status. Current sinks include: {list(sinks.keys())[:12]} ...")
            sys.exit(1)
        bus_ids[cc] = sinks[bus]

    midi_port = find_midi_port()
    print(f"Listening on MIDI: {midi_port}")
    print(f"Mapping: { {cc: (CC_TO_BUS[cc], bus_ids[cc]) for cc in CC_TO_BUS} }")
    print("Move knobs now... (Ctrl+C to exit)")

    with mido.open_input(midi_port) as port:
        last_toggle = 0.0
        for msg in port:
            if msg.type == "control_change":
                cc = msg.control
                val = msg.value

                if cc in bus_ids:
                    set_volume(bus_ids[cc], val)

                # Optional toggle (prevents spam by requiring a cooldown)
                # if cc == TOGGLE_CC and val > 100 and (time.time() - last_toggle) > 0.5:
                #     subprocess.call([TOGGLE_SCRIPT])
                #     last_toggle = time.time()

if __name__ == "__main__":
    main()
