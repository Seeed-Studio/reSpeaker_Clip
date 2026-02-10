#!/usr/bin/env python3
"""
Opus Audio Receiver for ReSpeaker Lav

Receives Opus encoded audio data from UART and decodes it to WAV file.
Supports multiple start/stop sessions, auto-names files by datetime.

Usage:
    python3 receive_opus.py /dev/ttyACM0 921600 . --mode mono     # Left channel only
    python3 receive_opus.py /dev/ttyACM0 921600 . --mode stereo   # Stereo output
    python3 receive_opus.py /dev/ttyACM0 921600 . --mode merge    # Mix L+R to mono

Requires: pyserial, opuslib
"""

import serial
import sys
import wave
import os
import time
import argparse
from datetime import datetime

try:
    import opuslib
except ImportError:
    print("Installing required packages...")
    import subprocess
    subprocess.check_call([sys.executable, "-m", "pip", "install", "pyserial", "opuslib"])
    import opuslib


class OpusUARTReceiver:
    def __init__(self, port="/dev/ttyACM0", baudrate=921600, output_dir=".", mode="stereo"):
        self.ser = serial.Serial(port, baudrate, timeout=1)
        self.ser.reset_input_buffer()
        self.ser.reset_output_buffer()
        self.sample_rate = 16000
        self.device_channels = 2
        self.frame_size = 320
        self.bitrate = 48000
        self.output_dir = output_dir
        self.mode = mode
        self.decoder = None
        self.session_count = 0
        self.frames_data = []
        self.should_stop = False

        # Map mode to device command
        self.mode_cmd = {
            "mono": "1",
            "stereo": "2",
            "merge": "3"
        }.get(mode, "2")

        print(f"Mode: {mode.upper()} (will send command '{self.mode_cmd}' to device)")

    def send_cmd(self, cmd):
        """Send command to device"""
        self.ser.write((cmd + '\n').encode())
        self.ser.flush()
        time.sleep(0.05)

    def parse_header(self, line):
        """Parse header line"""
        if "=" in line:
            key, value = line.strip().split("=", 1)
            if key == "SAMPLE_RATE":
                self.sample_rate = int(value)
            elif key == "CHANNELS":
                self.device_channels = int(value)
            elif key == "FRAME_SIZE":
                self.frame_size = int(value)
            elif key == "BITRATE":
                self.bitrate = int(value)

    def init_decoder(self):
        """Initialize Opus decoder"""
        if self.decoder is None:
            print(f"Initializing Opus decoder:")
            print(f"  Sample Rate: {self.sample_rate} Hz")
            print(f"  Channels: {self.device_channels}")
            print(f"  Frame Size: {self.frame_size}")
            print(f"  Bitrate: {self.bitrate} bps")

            self.decoder = opuslib.Decoder(
                fs=self.sample_rate,
                channels=self.device_channels
            )

    def generate_filename(self):
        """Generate filename with datetime and mode"""
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        return os.path.join(self.output_dir, f"recording_{timestamp}.wav")

    def wait_for_data_start(self):
        """Wait for DATA_START marker"""
        print("Waiting for data start...")
        start_time = time.time()
        while time.time() - start_time < 5 and not self.should_stop:
            line = self.ser.readline().decode('utf-8', errors='ignore').strip()
            if line:
                print(f"RX: {line}")
            if line.startswith(">>> DATA_START"):
                self.init_decoder()
                return True
            elif "=" in line:
                self.parse_header(line)
        return not self.should_stop

    def receive_one_session(self):
        """Receive one recording session"""
        self.frames_data = []
        frame_count = 0

        # Wait for DATA_START
        if not self.wait_for_data_start():
            if self.should_stop:
                print("\nStopping...")
            else:
                print("Timeout waiting for data start")
            return False

        print("Receiving encoded frames... (press Ctrl+C to stop)")

        # Read frames until DATA_END or interrupted
        while not self.should_stop:
            line = self.ser.readline().decode('utf-8', errors='ignore').strip()

            if not line:
                continue

            if line.startswith(">>> DATA_END"):
                print(f"\nSession ended. Received {frame_count} frames")
                break

            # Parse frame data: <length>\n<hex data>
            if len(line) == 4:
                try:
                    frame_len = int(line, 16)
                    if frame_len > 0 and frame_len < 4000:
                        # Read hex data
                        hex_line = self.ser.readline().decode('utf-8', errors='ignore').strip()
                        opus_data = bytes.fromhex(hex_line)

                        if len(opus_data) == frame_len:
                            # Decode Opus frame
                            try:
                                pcm_data = self.decoder.decode(opus_data, self.frame_size, False)
                                self.frames_data.append(pcm_data)
                                frame_count += 1

                                if frame_count % 50 == 0:
                                    print(f"\rReceived {frame_count} frames", end='', flush=True)
                            except Exception as e:
                                print(f"\nDecode error: {e}")
                except ValueError as e:
                    print(f"\nParse error: {e}")
                    continue

        # Save to WAV file
        print(f"\nFrames collected: {len(self.frames_data)}")
        if self.frames_data:
            try:
                output_file = self.generate_filename()
                self.save_wav(self.frames_data, output_file)
                self.session_count += 1
                print(f"Session count incremented to: {self.session_count}")
                return True
            except Exception as e:
                print(f"Error saving WAV: {e}")
                import traceback
                traceback.print_exc()
                return False
        else:
            print("No data received in this session")
            return False

    def save_wav(self, frames_data, output_file):
        """Save decoded PCM data to WAV file"""
        if not frames_data:
            print("No audio data to save")
            return

        # Combine all frames
        pcm_data = b''.join(frames_data)

        # Calculate total samples
        total_samples = len(pcm_data) // 2  # 16-bit samples

        # Create WAV file
        with wave.open(output_file, 'wb') as wav_file:
            wav_file.setnchannels(self.device_channels)
            wav_file.setsampwidth(2)  # 16-bit
            wav_file.setframerate(self.sample_rate)
            wav_file.writeframes(pcm_data)

        duration = len(pcm_data) / (self.sample_rate * self.device_channels * 2)
        print(f"\n\n*** Saved to {output_file} ***")
        print(f"Channels: {self.device_channels}")
        print(f"Duration: {duration:.2f} seconds")
        print(f"Samples: {total_samples}")

    def signal_handler(self, signum, frame):
        """Handle interrupt signals"""
        print("\n\nInterrupt signal received...")
        self.should_stop = True

    def run(self):
        """Main loop: support multiple recording sessions"""
        print(f"Opus UART Receiver")
        print(f"Port: {self.ser.port}")
        print(f"Baudrate: {self.ser.baudrate}")
        print(f"Output directory: {os.path.abspath(self.output_dir)}")
        print(f"Mode: {self.mode}")

        # Setup signal handlers
        import signal
        signal.signal(signal.SIGINT, self.signal_handler)
        signal.signal(signal.SIGTERM, self.signal_handler)

        try:
            while not self.should_stop:
                # Send 'e' to ensure device is stopped
                print("\n" + "="*50)
                self.send_cmd('e')

                # Clear any pending data
                self.ser.reset_input_buffer()

                # Send mode command to device
                print(f"Sending mode command: {self.mode_cmd}")
                self.send_cmd(self.mode_cmd)

                # Wait for device to reinitialize encoder
                time.sleep(0.5)

                # Send 's' to start recording
                self.send_cmd('s')

                # Receive data
                success = self.receive_one_session()
                print(f"Session result: {success}, Total sessions: {self.session_count}")

                if not success and not self.should_stop:
                    print("Failed to receive data. Check device connection.")
                    break

                if self.should_stop:
                    break

                # Ask user if continue
                try:
                    input("\nPress Enter for next recording, or Ctrl+C to exit...")
                except KeyboardInterrupt:
                    self.should_stop = True
                    break

        finally:
            print("\n\nStopping...")
            self.send_cmd('e')
            print("Sent stop command")

            # Save any remaining data
            if self.frames_data:
                print("Saving remaining data...")
                self.save_wav(self.frames_data, self.generate_filename())

    def close(self):
        if self.ser.is_open:
            self.ser.close()


def main():
    parser = argparse.ArgumentParser(
        description='Opus Audio Receiver for ReSpeaker Lav',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='''
Audio modes:
  mono     - Use left channel only (single microphone)
  stereo   - Keep stereo output (left + right microphones)
  merge    - Mix both channels to mono (blended microphone sound)

Examples:
  %(prog)s /dev/ttyACM0 921600 . --mode mono
  %(prog)s /dev/ttyACM0 921600 recordings --mode merge
        '''
    )

    parser.add_argument('port', nargs='?', default='/dev/ttyACM0',
                        help='Serial port (default: /dev/ttyACM0)')
    parser.add_argument('baudrate', nargs='?', type=int, default=921600,
                        help='Baudrate (default: 921600)')
    parser.add_argument('output_dir', nargs='?', default='.',
                        help='Output directory (default: current directory)')
    parser.add_argument('--mode', choices=['mono', 'stereo', 'merge'],
                        default='stereo',
                        help='Audio mode (default: stereo)')

    args = parser.parse_args()

    receiver = OpusUARTReceiver(args.port, args.baudrate, args.output_dir, args.mode)

    try:
        receiver.run()
    except Exception as e:
        print(f"\nError: {e}")
        import traceback
        traceback.print_exc()
    finally:
        receiver.close()


if __name__ == "__main__":
    main()
