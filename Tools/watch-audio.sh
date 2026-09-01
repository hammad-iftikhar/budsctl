#!/usr/bin/env bash
#
# Log every change in the earbuds' Bluetooth profile mask and their presence in
# the CoreAudio device list, alongside whether BudsCtl is running.
#
#   ./Tools/watch-audio.sh            # print to the terminal
#   ./Tools/watch-audio.sh log.txt    # and tee to a file
#
# Why this exists: the earbuds once disappeared from the audio output list while
# BudsCtl was running, and it has not reproduced. BudsCtl demonstrably adds a
# BLE link on top of the classic A2DP link, so the suspicion is that the two
# interact -- but suspicion is not evidence. Leave this running; when it happens
# again the timeline will say whether the BLE bit, the A2DP bit, or the audio
# device went first, which is the difference between three different fixes.

set -uo pipefail

DEVICE="SOUNDPEATS Air4 Pro"
OUT="${1:-}"

emit() {
    local line="$(date '+%H:%M:%S')  $*"
    echo "$line"
    [ -n "$OUT" ] && echo "$line" >>"$OUT"
}

emit "watching \"$DEVICE\" -- Ctrl-C to stop"
last=""

while true; do
    # Profile mask, e.g. "< HFP AVRCP A2DP BLE ACL >". BLE appears only while
    # something holds a CoreBluetooth connection.
    services=$(system_profiler SPBluetoothDataType 2>/dev/null \
        | sed -n "/$DEVICE/,/Services:/p" | grep -o '<[^>]*>' | head -1)
    [ -z "$services" ] && services="(not connected)"

    # Does CoreAudio still offer the buds as an output device?
    if system_profiler SPAudioDataType 2>/dev/null | grep -q "$DEVICE"; then
        audio="audio-device:present"
    else
        audio="audio-device:GONE"
    fi

    if pgrep -qx BudsCtl 2>/dev/null || pgrep -qf '/Applications/BudsCtl.app' 2>/dev/null; then
        app="budsctl:running"
    else
        app="budsctl:stopped"
    fi

    now="$app  $audio  $services"
    if [ "$now" != "$last" ]; then
        emit "$now"
        last="$now"
    fi

    sleep 5
done
