#!/usr/bin/env python3
"""
Configuration Commands Test - Test 2

Tests: BITRATE, MODE, COMPLEXITY, CHUNKSIZE

Usage:
    python test_02_config.py [--device MAC_ADDRESS]
"""

import asyncio
import json
import argparse
from test_01_basic import ClipClient

async def test_bitrate(client):
    """Test AT+BITRATE command"""
    print("\n=== Test: AT+BITRATE ===")

    # Get current
    print("\n1. Get current bitrate:")
    response = await client.send_command("AT+BITRATE?")
    if response.get("ok") and "value" in response:
        original = response["value"]
        print(f"✓ Current bitrate: {original} bps")
    else:
        print(f"✗ Failed: {response}")
        return False

    # Set to 32000
    print(f"\n2. Set bitrate to 32000:")
    response = await client.send_command("AT+BITRATE=32000")
    if not response.get("ok"):
        print(f"✗ Failed: {response.get('error')}")
        return False
    print("✓ Bitrate set")

    # Verify
    print("\n3. Verify bitrate:")
    response = await client.send_command("AT+BITRATE?")
    if response.get("ok") and response.get("value") == 32000:
        print("✓ Bitrate verified: 32000 bps")
    else:
        print(f"✗ Verification failed: {response}")
        return False

    # Restore original
    print(f"\n4. Restore original bitrate ({original}):")
    await client.send_command(f"AT+BITRATE={original}")
    print("✓ Restored")
    return True

async def test_mode(client):
    """Test AT+MODE command"""
    print("\n=== Test: AT+MODE ===")

    # Get current
    print("\n1. Get current mode:")
    response = await client.send_command("AT+MODE?")
    if response.get("ok") and "value" in response:
        original = response["value"]
        print(f"✓ Current mode: {original}")
    else:
        print(f"✗ Failed: {response}")
        return False

    # Toggle mode
    new_mode = "enhanced" if original == "normal" else "normal"
    print(f"\n2. Switch to {new_mode}:")
    response = await client.send_command(f"AT+MODE={new_mode}")
    if not response.get("ok"):
        print(f"✗ Failed: {response.get('error')}")
        return False
    print("✓ Mode switched")

    # Verify
    print("\n3. Verify mode:")
    response = await client.send_command("AT+MODE?")
    if response.get("ok") and response.get("value") == new_mode:
        print(f"✓ Mode verified: {new_mode}")
    else:
        print(f"✗ Verification failed: {response}")
        return False

    # Restore original
    print(f"\n4. Restore original mode ({original}):")
    await client.send_command(f"AT+MODE={original}")
    print("✓ Restored")
    return True

async def test_complexity(client):
    """Test AT+COMPLEXITY command"""
    print("\n=== Test: AT+COMPLEXITY ===")

    # Get current
    print("\n1. Get current complexity:")
    response = await client.send_command("AT+COMPLEXITY?")
    if response.get("ok") and "value" in response:
        original = response["value"]
        print(f"✓ Current complexity: {original}")
    else:
        print(f"✗ Failed: {response}")
        return False

    # Set to 5
    print(f"\n2. Set complexity to 5:")
    response = await client.send_command("AT+COMPLEXITY=5")
    if not response.get("ok"):
        print(f"✗ Failed: {response.get('error')}")
        return False
    print("✓ Complexity set")

    # Verify
    print("\n3. Verify complexity:")
    response = await client.send_command("AT+COMPLEXITY?")
    if response.get("ok") and response.get("value") == 5:
        print("✓ Complexity verified: 5")
    else:
        print(f"✗ Verification failed: {response}")
        return False

    # Restore original
    print(f"\n4. Restore original complexity ({original}):")
    await client.send_command(f"AT+COMPLEXITY={original}")
    print("✓ Restored")
    return True

async def test_chunksize(client):
    """Test AT+CHUNKSIZE command"""
    print("\n=== Test: AT+CHUNKSIZE ===")

    # Get current
    print("\n1. Get current chunk size:")
    response = await client.send_command("AT+CHUNKSIZE?")
    if response.get("ok") and "value" in response:
        original = response["value"]
        print(f"✓ Current chunk size: {original} bytes")
    else:
        print(f"✗ Failed: {response}")
        return False

    # Set to 1000
    print(f"\n2. Set chunk size to 1000:")
    response = await client.send_command("AT+CHUNKSIZE=1000")
    if not response.get("ok"):
        print(f"✗ Failed: {response.get('error')}")
        return False
    print("✓ Chunk size set")

    # Verify
    print("\n3. Verify chunk size:")
    response = await client.send_command("AT+CHUNKSIZE?")
    if response.get("ok") and response.get("value") == 1000:
        print("✓ Chunk size verified: 1000 bytes")
    else:
        print(f"✗ Verification failed: {response}")
        return False

    # Restore original
    print(f"\n4. Restore original chunk size ({original}):")
    await client.send_command(f"AT+CHUNKSIZE={original}")
    print("✓ Restored")
    return True

async def main():
    parser = argparse.ArgumentParser(description="Configuration Commands Test")
    parser.add_argument("--device", "-d", help="Device MAC address")
    args = parser.parse_args()

    client = ClipClient(args.device)
    if not await client.connect():
        return 1

    try:
        print("\n" + "="*50)
        print("Configuration Commands Test")
        print("="*50)

        results = []
        results.append(await test_bitrate(client))
        results.append(await test_mode(client))
        results.append(await test_complexity(client))
        results.append(await test_chunksize(client))

        print("\n" + "="*50)
        print(f"Results: {sum(results)}/{len(results)} passed")
        print("="*50)

    finally:
        await client.disconnect()

if __name__ == "__main__":
    asyncio.run(main())
