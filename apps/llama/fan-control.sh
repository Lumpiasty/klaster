#!/bin/sh
# Fan/power watchdog for the RX 580. Runs in the privileged gpu-fan-control
# DaemonSet (fan-control.yaml); the llama pod itself has a read-only /sys.
#
# We do NOT run a continuous manual PWM curve here. Testing showed the
# fan tachometer (fan1_input) reports live, physically-accurate values
# while ramping UP in manual mode (pwm1_enable=1), but freezes/goes stale
# on decreasing commands - so we have no way to verify the fan actually
# slows down when told to via manual mode, and no physical access to the
# box to confirm by ear. Rather than trust an unverifiable state, we only
# ever use manual mode for the one behavior proven to work (forcing max
# speed), and defer back to the SMC's own auto/fuzzy control (mode 2,
# vendor-tested, confirmed to give live accurate telemetry) for everything
# else, including all idle time.
#
# HIGH_T: cross this -> force manual, pwm=255 (well below the 75C SMU fan
#         target and the 79C temp seen right before the original crash).
# LOW_T:  drop below this while in manual mode -> hand back to auto.
# Hysteresis gap between them avoids flapping at the boundary.
#
# Power cap: FIXED at POWER_CAP (120W) at all times, independent of
# temperature (2026-10-09, owner request). The card hung twice in 24h under
# sustained load at the 145W default (amdgpu "ring sdma1 timeout ... device
# lost from bus"); a 120W cap was previously found to be stable. The cap is
# set at startup and re-asserted every loop if anything (e.g. a GPU reset)
# changes it. It is never restored to the 145W default.
set -u
HIGH_T=65
LOW_T=55
POWER_CAP=120000000  # 120W, in microwatts - fixed, never raised
state=auto
synced=0
HW=

# On pod stop, hand the fan back to the SMC instead of leaving it as is.
trap '[ -n "$HW" ] && echo 2 > "$HW/pwm1_enable"; exit 0' TERM INT

while true; do
  HW=$(ls -d /sys/class/drm/card0/device/hwmon/hwmon* 2>/dev/null | head -1)
  if [ -z "$HW" ]; then
    sleep 2
    continue
  fi

  if [ "$synced" = "0" ]; then
    echo 2 > "$HW/pwm1_enable"
    echo "$(date -u +%FT%TZ) using $HW, fan in auto mode"
    synced=1
  fi

  # Fixed power cap: (re-)assert whenever it differs from POWER_CAP.
  cap_now=$(cat "$HW/power1_cap" 2>/dev/null || echo 0)
  if [ "$cap_now" != "$POWER_CAP" ]; then
    if echo "$POWER_CAP" > "$HW/power1_cap" 2>/dev/null; then
      echo "$(date -u +%FT%TZ) power1_cap $cap_now -> $POWER_CAP"
    else
      echo "$(date -u +%FT%TZ) ERROR: cannot write $HW/power1_cap (is $cap_now)"
    fi
  fi

  t_raw=$(cat "$HW/temp1_input" 2>/dev/null || echo 0)
  t=$(( t_raw / 1000 ))

  if [ "$state" = "auto" ] && [ "$t" -ge "$HIGH_T" ]; then
    echo 1 > "$HW/pwm1_enable"
    echo 255 > "$HW/pwm1"
    echo "$(date -u +%FT%TZ) ${t}C >= ${HIGH_T}C: fan forced to max"
    state=manual
  elif [ "$state" = "manual" ] && [ "$t" -lt "$LOW_T" ]; then
    echo 2 > "$HW/pwm1_enable"
    echo "$(date -u +%FT%TZ) ${t}C < ${LOW_T}C: fan back to auto"
    state=auto
  fi

  sleep 1
done
