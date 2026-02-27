#!/usr/bin/env python3
"""
Decode raw Opus frames from BLE transfer to WAV

The device sends Opus frames with 2-byte length prefix:
[2-byte little-endian length][Opus frame data]...

Usage:
    python tools/decode_opus.py input.opus output.wav
"""

import sys
import struct
import wave
import argparse
from pathlib import Path


def decode_raw_opus(input_file: Path, output_file: Path, sample_rate=16000, channels=1):
    """Decode raw Opus frames to WAV"""

    # Try to import opuslib
    try:
        import opuslib
    except ImportError:
        print("Installing opuslib...")
        import subprocess
        subprocess.check_call([sys.executable, "-m", "pip", "install", "opuslib"])
        import opuslib

    # Read raw data
    with open(input_file, 'rb') as f:
        raw_data = f.read()

    print(f"Reading {len(raw_data)} bytes from {input_file}")

    # Skip header to find valid Opus frames
    offset = 0
    while offset < min(200, len(raw_data)):
        frame_len = struct.unpack('<H', raw_data[offset:offset+2])[0]
        # Look for reasonable frame sizes (Opus frames are typically 20-300 bytes)
        if 10 <= frame_len <= 300:
            print(f"Found valid frame start at offset {offset}")
            break
        offset += 2

    if offset >= 200:
        print("No valid frame start found! File may be corrupted.")
        return False

    # Create Opus decoder
    decoder = opuslib.Decoder(fs=sample_rate, channels=channels)
    frame_size = sample_rate // 50  # 20ms frames = 320 samples

    print(f"Decoder: {sample_rate} Hz, {channels} channel(s), frame_size={frame_size}")

    # Parse frames and decode
    pcm_frames = []
    frame_count = 0
    errors = 0

    while offset < len(raw_data):
        # Read 2-byte little-endian length
        if offset + 2 > len(raw_data):
            break

        frame_len = struct.unpack('<H', raw_data[offset:offset+2])[0]
        offset += 2

        # Validate frame length
        if frame_len < 10 or frame_len > 1000:
            # End of valid data
            break

        # Read frame data
        if offset + frame_len > len(raw_data):
            print(f"\nIncomplete frame at offset {offset}, stopping")
            break

        frame_data = raw_data[offset:offset+frame_len]
        offset += frame_len

        # Decode Opus frame to PCM
        try:
            pcm_data = decoder.decode(frame_data, frame_size, decode_fec=False)
            pcm_frames.append(pcm_data)
            frame_count += 1

            if frame_count % 50 == 0:
                print(f"  Decoded {frame_count} frames...", end='\r')
        except Exception as e:
            errors += 1
            if errors < 5:  # Only show first few errors
                print(f"\nWarning: Failed to decode frame {frame_count}: {e}")
            continue

    print(f"\nDecoded {frame_count} frames ({errors} errors)")

    if not pcm_frames:
        print("Error: No valid frames decoded")
        return False

    # Combine all PCM frames
    all_pcm = b''.join(pcm_frames)

    # Write WAV file
    output_file.parent.mkdir(parents=True, exist_ok=True)
    with open(output_file, 'wb') as wf:
        wav = wave.open(wf, 'wb')
        wav.setnchannels(channels)
        wav.setsampwidth(2)  # 16-bit
        wav.setframerate(sample_rate)
        wav.writeframes(all_pcm)
        wav.close()

    duration = len(all_pcm) / (sample_rate * channels * 2)
    print(f"\nSaved to {output_file}")
    print(f"  Duration: {duration:.2f} seconds")
    print(f"  Frames: {frame_count}")
    print(f"  Size: {len(all_pcm)} bytes")

    return True


def main():
    parser = argparse.ArgumentParser(
        description="Decode raw Opus frames to WAV",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Decode Opus file
  python tools/decode_opus.py recording.opus recording.wav

  # Decode stereo file
  python tools/decode_opus.py recording.opus recording.wav --channels 2

  # Decode with different sample rate
  python tools/decode_opus.py recording.opus recording.wav --sample-rate 48000
        """
    )

    parser.add_argument("input", type=Path, help="Input Opus file")
    parser.add_argument("output", nargs="?", type=Path, help="Output WAV file (default: input.wav)")
    parser.add_argument("--channels", type=int, default=1, choices=[1, 2],
                       help="Number of audio channels (default: 1)")
    parser.add_argument("--sample-rate", type=int, default=16000,
                       help="Sample rate in Hz (default: 16000)")

    args = parser.parse_args()

    input_file = args.input

    # Default output filename
    if args.output:
        output_file = args.output
    else:
        output_file = input_file.with_suffix('.wav')
        if output_file == input_file:
            output_file = input_file.parent / (input_file.name + '.wav')

    if not input_file.exists():
        print(f"Error: Input file not found: {input_file}")
        return 1

    print(f"Decoding: {input_file} -> {output_file}")
    print(f"  Channels: {args.channels}")
    print(f"  Sample rate: {args.sample_rate} Hz\n")

    success = decode_raw_opus(
        input_file,
        output_file,
        sample_rate=args.sample_rate,
        channels=args.channels,
    )

    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
