#!/bin/bash
# q8b-bt-bringup — bring up the Q8B UART Bluetooth (Broadcom/SYN43756, AP6276P).
#
# Why this exists (root cause, observed on hardware):
#   Wi-Fi and Bluetooth live on the same M.2 E-key module (AP6276P /
#   SYN43756B0). Wi-Fi is PCIe, BT is UART (988000.serial / serial1).
#   On a *cold* boot the BT core is not yet responsive when hci0 is first
#   opened: hci_dev_do_open() -> hci_uart_setup() -> bcm_setup() ->
#   btbcm_reset() sends HCI_Reset and gets no reply
#       "Bluetooth: hci0: command 0x0c03 tx timeout"
#       "Bluetooth: hci0: BCM: Reset failed (-110)"
#   bluetoothd then does NOT retry, so the controller never comes up.
#   A few seconds later the chip *is* openable; re-initialising the
#   transport (rmmod/modprobe hci_uart) re-registers the controller with
#   MGMT, and an explicit power-on brings it UP RUNNING. This unit performs
#   that sequence until bluetoothd reports the controller as powered.
#
# Design: best-effort, bounded, idempotent. Ordered after bluetooth.service,
#   never blocks the boot; always exits 0.
#
# NOTE: readiness is probed with `bluetoothctl`, NOT `btmgmt`. btmgmt hangs
#   when it has no controlling tty (observed under systemd, rc=124/timeout);
#   bluetoothctl works there and also proves bluetoothd can see the
#   controller, which is what we actually care about.
set -u

LOG="${Q8B_BT_LOG:-/run/q8b-bt-bringup.log}"
ATTEMPTS="${Q8B_BT_ATTEMPTS:-40}"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }

ctrl_powered() { timeout 8 bluetoothctl show 2>/dev/null | grep -q 'Powered: yes'; }
ctrl_visible() { timeout 8 bluetoothctl list 2>/dev/null | grep -q '^Controller '; }
hci_up()       { hciconfig hci0 2>/dev/null | grep -q 'UP RUNNING'; }

: >"$LOG" 2>/dev/null || LOG=/dev/null
log "start (attempts=$ATTEMPTS)"

# Wait (up to 90 s) for hci_uart to create the hci0 device at all.
for _ in $(seq 1 90); do
    [ -e /sys/class/bluetooth/hci0 ] && break
    sleep 1
done
if [ ! -e /sys/class/bluetooth/hci0 ]; then
    log "hci0 device never appeared; nothing to do"
    exit 0
fi
log "hci0 device present"

start=$(date +%s)
for i in $(seq 1 "$ATTEMPTS"); do
    if ctrl_powered; then
        log "controller powered (attempt $i, t=$(( $(date +%s) - start ))s)"
        exit 0
    fi

    t=$(( $(date +%s) - start ))

    # Registered with MGMT but not powered on -> just power it on.
    if ctrl_visible; then
        log "attempt $i (t=${t}s): controller visible, powering on"
        bluetoothctl power on >/dev/null 2>&1
        sleep 2
        if ctrl_powered; then
            log "controller powered (attempt $i, t=$(( $(date +%s) - start ))s)"
            exit 0
        fi
    fi

    # Make sure the chip is openable at the HCI level. If it is, re-register
    # the transport so the controller is announced over MGMT again.
    hciconfig hci0 up >/dev/null 2>&1
    if hci_up; then
        log "attempt $i (t=${t}s): hci0 openable; reloading hci_uart"
        hciconfig hci0 down >/dev/null 2>&1
        rmmod hci_uart >/dev/null 2>&1
        sleep 1
        modprobe hci_uart >/dev/null 2>&1
        sleep 4
        # Open the fresh device, then power it on through bluetoothd.
        hciconfig hci0 up >/dev/null 2>&1
        sleep 2
        bluetoothctl power on >/dev/null 2>&1
        sleep 2
        if ctrl_powered; then
            log "controller powered via reload (attempt $i, t=$(( $(date +%s) - start ))s)"
            exit 0
        fi
        # bluetoothd may have missed the re-add; nudge it once and retry.
        systemctl try-restart bluetooth >/dev/null 2>&1
        sleep 3
        hciconfig hci0 up >/dev/null 2>&1
        bluetoothctl power on >/dev/null 2>&1
        sleep 2
        if ctrl_powered; then
            log "controller powered via reload+bluetoothd restart (attempt $i, t=$(( $(date +%s) - start ))s)"
            exit 0
        fi
    else
        log "attempt $i (t=${t}s): hci0 not openable yet"
    fi

    sleep 5
done

log "giving up after $ATTEMPTS attempts (controller still not powered)"
exit 0
