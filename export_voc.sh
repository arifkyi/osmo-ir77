#!/bin/bash
# Export all detected Iridium VOC calls to individual WAV files
# Usage: ./export_voc.sh <parsed_file> <output_dir>

PARSED_FILE="${1:?Usage: $0 <parsed_file> <output_dir>}"
OUTPUT_DIR="${2:-./voc_output}"
TOOLKIT_DIR="$HOME/build/iridium-toolkit"

mkdir -p "$OUTPUT_DIR"

# Extract all VOC lines
grep "VOC:" "$PARSED_FILE" | grep -v "LCW(0,001111,100000000000000000000" > /tmp/all_voc.bits

TOTAL=$(wc -l < /tmp/all_voc.bits)
echo "Found $TOTAL VOC frames total"

if [ "$TOTAL" -eq 0 ]; then
    echo "No VOC frames found!"
    exit 1
fi

# Group VOC frames into separate calls based on time gaps (>5 sec = new call)
python3 - "$PARSED_FILE" "$OUTPUT_DIR" "$TOOLKIT_DIR" << 'PYEOF'
import sys, os, subprocess

parsed_file = sys.argv[1]
output_dir = sys.argv[2]
toolkit_dir = sys.argv[3]

# Read all VOC lines
voc_lines = []
with open(parsed_file) as f:
    for line in f:
        if 'VOC:' in line and 'LCW(0,001111,100000000000000000000' not in line:
            parts = line.strip().split()
            if parts[1] == 'VOC:':
                ts = float(parts[3]) / 1000.0
            else:
                ts = float(parts[2]) / 1000.0
            voc_lines.append((ts, line.strip()))

if not voc_lines:
    print("No VOC frames found")
    sys.exit(1)

voc_lines.sort(key=lambda x: x[0])

# Group by time gap > 5 seconds = new call
calls = []
current_call = [voc_lines[0]]
for i in range(1, len(voc_lines)):
    if voc_lines[i][0] - voc_lines[i-1][0] > 5.0:
        calls.append(current_call)
        current_call = [voc_lines[i]]
    else:
        current_call.append(voc_lines[i])
calls.append(current_call)

print(f"Detected {len(calls)} separate voice calls")

success = 0
for idx, call in enumerate(calls):
    call_num = idx + 1
    bits_file = f"/tmp/voc_call_{call_num}.bits"
    dfs_file = f"/tmp/voc_call_{call_num}.dfs"
    wav_file = os.path.join(output_dir, f"call_{call_num:03d}_{len(call)}frames.wav")
    mp3_file = os.path.join(output_dir, f"call_{call_num:03d}_{len(call)}frames.mp3")

    # Write bits
    with open(bits_file, 'w') as f:
        for _, line in call:
            f.write(line + "\n")

    print(f"  Call {call_num}: {len(call)} frames", end="")

    # bits -> dfs
    r = subprocess.run([sys.executable, os.path.join(toolkit_dir, "bits_to_dfs.py"), bits_file, dfs_file],
                       capture_output=True)
    if r.returncode != 0:
        print(" [SKIP - dfs failed]")
        continue

    # dfs -> wav
    r = subprocess.run([os.path.join(toolkit_dir, "ir77_ambe_decode"), dfs_file, wav_file],
                       capture_output=True)
    if r.returncode != 0:
        print(" [SKIP - decode failed]")
        continue

    # wav -> mp3 (if ffmpeg available)
    r = subprocess.run(["ffmpeg", "-y", "-i", wav_file, "-q:a", "2", mp3_file],
                       capture_output=True)
    if r.returncode == 0:
        os.remove(wav_file)
        print(f" -> {mp3_file}")
    else:
        print(f" -> {wav_file}")

    success += 1

print(f"\nDone! {success}/{len(calls)} calls exported to {output_dir}/")
PYEOF
