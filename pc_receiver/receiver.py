"""
HeadTracker PC Receiver
-----------------------
Receives pose data from the iPhone app over UDP and writes it to
FreeTrack shared memory so DCS, MSFS, and other sims see it natively.
No OpenTrack needed.

Usage:
    python receiver.py

Requirements:
    pip install pywin32
"""

import socket
import struct
import time
import sys
import mmap

# ── Config ────────────────────────────────────────────────────────────────────

LISTEN_IP   = '0.0.0.0'
LISTEN_PORT = 4242

# ── FreeTrack 2.0 Shared Memory ───────────────────────────────────────────────
#
# Games (DCS, MSFS, Assetto Corsa, ETS2, etc.) read from a named shared memory
# block called "FT_SharedMem". We write pose data here directly.
#
# Struct layout (little-endian):
#   offset  0: uint32  DataID       (increment each frame so game knows data is fresh)
#   offset  4: int32   CamWidth     (set to 640)
#   offset  8: int32   CamHeight    (set to 480)
#   offset 12: float32 Yaw          (degrees, positive = left)
#   offset 16: float32 Pitch        (degrees, positive = up)
#   offset 20: float32 Roll         (degrees, positive = left)
#   offset 24: float32 X            (cm)
#   offset 28: float32 Y            (cm)
#   offset 32: float32 Z            (cm)
#   ... (rest of struct padded to 284 bytes for Enhanced)

SHM_NAME = "FT_SharedMem"
SHM_SIZE = 284

def create_shared_memory():
    """Create or open the FreeTrack named shared memory block."""
    try:
        shm = mmap.mmap(-1, SHM_SIZE, tagname=SHM_NAME)
        print(f"[OK] FreeTrack shared memory created: {SHM_NAME}")
        return shm
    except Exception as e:
        print(f"[ERROR] Could not create shared memory: {e}")
        print("       Make sure you're running on Windows.")
        sys.exit(1)

def write_pose(shm, frame_id, yaw, pitch, roll, x, y, z):
    """Write a pose into FreeTrack shared memory."""
    shm.seek(0)
    data = struct.pack(
        '<Iii ffffff',   # little-endian: uint32, int32, int32, 6x float32
        frame_id,        # DataID — increment so game knows it's fresh
        640,             # CamWidth
        480,             # CamHeight
        yaw,             # degrees
        pitch,           # degrees
        roll,            # degrees
        x,               # cm
        y,               # cm
        z,               # cm
    )
    # Pad to SHM_SIZE
    shm.write(data + bytes(SHM_SIZE - len(data)))

# ── UDP Receiver ──────────────────────────────────────────────────────────────

def main():
    shm = create_shared_memory()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((LISTEN_IP, LISTEN_PORT))
    sock.settimeout(1.0)

    print(f"[OK] Listening on UDP {LISTEN_IP}:{LISTEN_PORT}")
    print(f"     Open DCS / your sim now. It will pick up tracking automatically.")
    print(f"     Press Ctrl+C to stop.\n")

    frame_id   = 0
    last_fps   = time.perf_counter()
    fps_count  = 0
    last_yaw   = 0.0

    try:
        while True:
            try:
                data, addr = sock.recvfrom(1024)
            except socket.timeout:
                continue

            if len(data) < 48:
                continue

            # Unpack 6x float64 (OpenTrack UDP format from the iPhone app)
            yaw, pitch, roll, x, y, z = struct.unpack('<6d', data[:48])

            # Write to shared memory immediately — no buffering
            write_pose(shm, frame_id, yaw, pitch, roll, x, y, z)
            frame_id += 1

            # Console stats
            fps_count += 1
            now = time.perf_counter()
            if now - last_fps >= 1.0:
                delta = abs(yaw - last_yaw)
                print(
                    f"  {fps_count:3d} fps  |  "
                    f"yaw={yaw:+7.2f}  pitch={pitch:+7.2f}  roll={roll:+7.2f}  |  "
                    f"x={x:+6.1f}  y={y:+6.1f}  z={z:+6.1f}"
                )
                fps_count  = 0
                last_fps   = now
                last_yaw   = yaw

    except KeyboardInterrupt:
        print("\n[STOP] Receiver stopped.")
    finally:
        sock.close()
        shm.close()

if __name__ == '__main__':
    main()
