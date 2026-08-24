"""Deterministic, dependency-free renderer for the pinned E1M1 standard MIDI."""

from array import array
from fractions import Fraction
import math
import struct
import sys

SAMPLE_RATE = 11025
PROGRAM_NAMES = {29: "Overdriven Guitar", 35: "Fretless Bass", 38: "Synth Bass 1",
                 50: "Synth Strings 1", 80: "Lead 1 (square)", 81: "Lead 2 (sawtooth)",
                 87: "Lead 8 (bass + lead)", 100: "FX 5 (brightness)"}
DRUM_NAMES = {27: "High Q", 29: "Scratch Push", 30: "Scratch Pull", 36: "Bass Drum 1",
              38: "Acoustic Snare", 39: "Hand Clap", 40: "Electric Snare",
              42: "Closed Hi-Hat", 44: "Pedal Hi-Hat", 46: "Open Hi-Hat",
              49: "Crash Cymbal 1", 53: "Ride Bell", 57: "Crash Cymbal 2"}
EXPECTED_PROGRAMS = frozenset(PROGRAM_NAMES)
EXPECTED_DRUMS = frozenset(DRUM_NAMES)


def _vlq(data, pos):
    value = 0
    for _ in range(4):
        byte = data[pos]
        pos += 1
        value = value * 128 + (byte & 0x7f)
        if byte < 0x80:
            return value, pos
    raise ValueError("MIDI variable-length quantity exceeds four bytes")


def parse(data):
    if data[:4] != b"MThd" or len(data) < 14:
        raise ValueError("music is not a standard MIDI file")
    header_size, midi_format, track_count, division = struct.unpack_from(">IHHH", data, 4)
    if header_size != 6 or midi_format not in (0, 1) or division & 0x8000:
        raise ValueError("renderer requires format 0/1 MIDI with metrical ticks")
    pos, events, order = 14, [], 0
    programs, drums, melodic_channels = set(), set(), set()
    for _ in range(track_count):
        if data[pos:pos + 4] != b"MTrk":
            raise ValueError("missing MIDI track header")
        size = struct.unpack_from(">I", data, pos + 4)[0]
        track, pos = data[pos + 8:pos + 8 + size], pos + 8 + size
        cursor = tick = 0
        running = None
        while cursor < len(track):
            delta, cursor = _vlq(track, cursor)
            tick += delta
            status = track[cursor]
            if status & 0x80:
                cursor += 1
            elif running is None:
                raise ValueError("MIDI running status used before a channel event")
            else:
                status = running
            if status == 0xff:
                kind = track[cursor]
                cursor += 1
                length, cursor = _vlq(track, cursor)
                payload = track[cursor:cursor + length]
                cursor += length
                if kind == 0x51:
                    if length != 3:
                        raise ValueError("invalid MIDI tempo event")
                    events.append((tick, order, "tempo", int.from_bytes(payload, "big"), 0, 0))
                    order += 1
                continue
            if status in (0xf0, 0xf7):
                length, cursor = _vlq(track, cursor)
                cursor += length
                continue
            running = status
            kind, channel = status & 0xf0, status & 15
            width = 1 if kind in (0xc0, 0xd0) else 2
            values = track[cursor:cursor + width]
            cursor += width
            if kind not in (0x80, 0x90, 0xb0, 0xc0, 0xe0):
                raise ValueError(f"unsupported MIDI channel event 0x{kind:02x}")
            a, b = values[0], values[1] if width == 2 else 0
            events.append((tick, order, kind, channel, a, b)); order += 1
            if kind == 0xc0:
                programs.add(a)
            elif kind == 0x90 and b:
                if channel == 9: drums.add(a)
                else: melodic_channels.add(channel)
    if pos != len(data):
        raise ValueError("trailing bytes after MIDI tracks")
    used_programs = programs & set(PROGRAM_NAMES)
    unknown_programs = programs - set(PROGRAM_NAMES) - {0, 16}
    if unknown_programs or drums - set(DRUM_NAMES):
        raise ValueError(f"procedural bank lacks programs {sorted(unknown_programs)} or percussion {sorted(drums - set(DRUM_NAMES))}")
    if used_programs != EXPECTED_PROGRAMS or drums != EXPECTED_DRUMS:
        raise ValueError(f"pinned E1M1 MIDI requirements changed: programs={sorted(used_programs)}, percussion={sorted(drums)}")
    return sorted(events), division, used_programs, drums


def _wave(program, phase):
    unit = (phase >> 16) & 0xffff
    if program in (80, 87): return 24000 if unit < 32768 else -24000
    if program in (29, 81, 100): return unit - 32768
    if program in (35, 38): return ((unit if unit < 32768 else 65535 - unit) * 2 - 32768)
    return ((unit if unit < 32768 else 65535 - unit) * 2 - 32768) * 3 // 4


def render(data):
    events, division, programs_used, drums_used = parse(data)
    timed, tempo, tick, position = [], 500000, 0, Fraction(0)
    for event in events:
        position += Fraction((event[0] - tick) * tempo * SAMPLE_RATE, division * 1_000_000)
        tick = event[0]
        timed.append((int(position), *event[2:]))
        if event[2] == "tempo": tempo = event[3]
    end = (timed[-1][0] if timed else 0) + SAMPLE_RATE
    program, volume, bend, sensitivity = [0]*16, [100]*16, [8192]*16, [2]*16
    rpn_msb, rpn_lsb = [127]*16, [127]*16
    voices, output, event_index, noise = [], array("h"), 0, 0x12345678
    for sample_index in range(end):
        while event_index < len(timed) and timed[event_index][0] <= sample_index:
            _, kind, channel, a, b = timed[event_index]; event_index += 1
            if kind == "tempo": continue
            if kind == 0xc0: program[channel] = a
            elif kind == 0xb0:
                if a == 7: volume[channel] = b
                elif a == 101: rpn_msb[channel] = b
                elif a == 100: rpn_lsb[channel] = b
                elif a == 6 and rpn_msb[channel] == rpn_lsb[channel] == 0: sensitivity[channel] = b
            elif kind == 0xe0: bend[channel] = a | (b << 7)
            elif kind == 0x90 and b:
                voices.append({"ch":channel,"note":a,"vel":b,"program":program[channel],"phase":0,"age":0,"released":False})
            elif kind == 0x80 or (kind == 0x90 and not b):
                for voice in voices:
                    if voice["ch"] == channel and voice["note"] == a and not voice["released"]:
                        voice["released"] = True; break
        mixed, retained = 0, []
        for voice in voices:
            ch, age = voice["ch"], voice["age"]
            if ch == 9:
                duration = SAMPLE_RATE * (5 if voice["note"] in (46,49,53,57) else 2) // 10
                if age >= duration: continue
                noise = (1664525 * noise + 1013904223) & 0xffffffff
                tone = ((noise >> 16) - 32768)
                if voice["note"] == 36: tone = _wave(35, voice["phase"])
                increment = int(55 * (2 ** ((voice["note"] - 36) / 12)) * (2**32) / SAMPLE_RATE)
                voice["phase"] = (voice["phase"] + increment) & 0xffffffff
                value = tone * (duration-age) // duration
            else:
                if voice["released"]: continue
                semitone = voice["note"] - 69 + ((bend[ch]-8192) / 8192) * sensitivity[ch]
                increment = int(440 * (2 ** (semitone / 12)) * (2**32) / SAMPLE_RATE)
                voice["phase"] = (voice["phase"] + increment) & 0xffffffff
                value = _wave(voice["program"], voice["phase"])
                value = value * min(age, 110) // 110
            mixed += value * voice["vel"] * volume[ch] // (127*127)
            voice["age"] = age + 1; retained.append(voice)
        voices = retained
        output.append(max(-32768, min(32767, mixed // 5)))
    if sys.byteorder != "little": output.byteswap()
    pcm = output.tobytes()
    fmt = struct.pack("<HHIIHH", 1, 1, SAMPLE_RATE, SAMPLE_RATE*2, 2, 16)
    wav = b"RIFF" + struct.pack("<I", 36+len(pcm)) + b"WAVEfmt " + struct.pack("<I",16) + fmt + b"data" + struct.pack("<I",len(pcm)) + pcm
    requirements = {
        "programs": [{"midi_program": p+1, "program_index": p, "name": PROGRAM_NAMES[p]} for p in sorted(programs_used)],
        "percussion": [{"midi_note": n, "name": DRUM_NAMES[n]} for n in sorted(drums_used)],
        "renderer": "project-authored deterministic integer oscillator bank", "sample_rate": SAMPLE_RATE,
    }
    return wav, requirements
