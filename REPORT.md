# MT7902 WiFi Driver Repair Report

Date: 2026-05-18
Host kernel: `7.0.8-arch1-1`

## Problem

After a kernel upgrade, the MT7902 WiFi DKMS package was registered but not installed for the running kernel:

```text
mt7902-wifi/1.0.0: added
```

The system fell back to the stock `mt7921e` module, which did not expose the MT7902 PCI alias for `14c3:7902`.

## Root Cause

The DKMS build failed against kernel `7.0.8-arch1-1` because `mt7615/debugfs.c` used `mac_pton()` without including the header that declares it on this kernel:

```text
mt7615/debugfs.c:503:14: error: implicit declaration of function 'mac_pton' [-Wimplicit-function-declaration]
```

On this kernel, `mac_pton()` is declared by `<linux/hex.h>`.

## Fix

Added `patches/12.patch`, which updates `mt7615/debugfs.c` to include:

```c
#include <linux/etherdevice.h>
#include <linux/hex.h>
```

The same include fix was applied to the local DKMS source at `/usr/src/mt7902-wifi-1.0.0/mt7615/debugfs.c` before rebuilding.

## Commands Used

```bash
make -C /lib/modules/$(uname -r)/build M=$PWD/drivers/net/wireless/mediatek/mt76 modules
sudo dkms build mt7902-wifi/1.0.0 -k $(uname -r)
sudo dkms install mt7902-wifi/1.0.0 -k $(uname -r) --force
sudo modprobe mt7921e
```

## Verification

DKMS installed successfully for the current kernel:

```text
mt7902-wifi/1.0.0, 7.0.8-arch1-1, x86_64: installed (Original modules exist)
```

The patched module is now preferred:

```text
filename: /lib/modules/7.0.8-arch1-1/updates/dkms/mt7921e.ko.zst
alias: pci:v000014C3d00007902sv*sd*bc*sc*i*
```

The PCI device is bound and WiFi is connected:

```text
Kernel driver in use: mt7921e
wlan0 connected and received a DHCP lease
```
