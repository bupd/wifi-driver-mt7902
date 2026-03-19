# MediaTek MT7902 (Filogic 310) WiFi 6E Linux Driver

## Overview

This document describes how to enable the **MediaTek MT7902 802.11ax (WiFi 6E) PCIe Wireless Network Adapter** on Linux, specifically on an ASUS Vivobook 14 running Arch Linux. Tested on kernels 6.17.7 and 6.19.8.

The MT7902 is a combo WiFi/Bluetooth chip (Filogic 310 family) that shares the same connac2 architecture as the MT7921/MT7922 family. As of February 2026, official upstream support has been submitted as an 11-patch series by Sean Wang (MediaTek) targeting Linux 7.1, but has not yet been merged into stable kernels.

This guide backports that patch series to kernel 6.17.7 and includes firmware updates.

## Hardware Information

| Property | Value |
|----------|-------|
| **Chip** | MediaTek MT7902 (Filogic 310) |
| **PCI ID** | `14c3:7902` |
| **Subsystem** | AzureWave 5520 |
| **Interface** | PCIe (also available as SDIO) |
| **WiFi Standard** | 802.11ax (WiFi 6E) |
| **Bands** | 2.4 GHz, 5 GHz, 6 GHz |
| **Bluetooth** | Integrated (separate USB interface `13d3:3579`) |
| **PCI Address** | `0000:02:00.0` |

## Why the Driver Doesn't Work Out of the Box

The existing `mt7921e` kernel module supports the MT7921/MT7922 family but the **MT7902 PCI device ID (`14c3:7902`) is not in the driver's device table**. Additionally, the MT7902 has hardware differences from MT7921/MT7922 that require driver changes:

1. **Different MCU TXQ index** - MT7902 uses TX ring 15 for MCU commands (vs ring 17 on MT7921)
2. **No MCU_WA ring** - MT7902 uses a single larger RX ring for both events and TX-done
3. **Different WFDMA prefetch layout** - Unique DMA prefetch configuration
4. **Different IRQ mapping** - The `wm2_complete_mask` must be zeroed
5. **Runtime PM disabled** - MT7902 doesn't support the PM mode used by MT7921

## Prerequisites

- Linux kernel 6.17.x with headers installed (`linux-headers` package on Arch)
- GCC and make (build tools)
- Internet connection (for downloading source and firmware)
- Root access

```bash
# Arch Linux
sudo pacman -S linux-headers base-devel

# Verify
ls /lib/modules/$(uname -r)/build/Makefile
```

## Step 1: Download Kernel Source

Download the kernel source tarball matching your running kernel and extract only the mt76 driver directory:

```bash
mkdir -p ~/mt7902-driver && cd ~/mt7902-driver

# Download kernel source (match your kernel version)
curl -L -o linux-6.17.7.tar.xz \
  "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.17.7.tar.xz"

# Extract only the mt76 driver tree
tar xf linux-6.17.7.tar.xz --strip-components=1 \
  linux-6.17.7/drivers/net/wireless/mediatek/mt76/
```

## Step 2: Apply the 11 Patches

The patches are based on Sean Wang's official patch series posted to linux-wireless on February 19, 2026. Below is a summary and the exact changes for each patch.

### Patch 01/11: Rename `is_mt7921()` to `is_connac2()`

Replaces all `is_mt7921()` references with `is_connac2()` to clarify the helper covers the entire connac2 chipset family (MT7961, MT7922, MT7920, and now MT7902).

**Files modified:**
- `mt76_connac.h` - Rename function
- `mt76_connac_mac.c` - All occurrences
- `mt76_connac_mcu.c` - All occurrences
- `mt76_connac_mcu.h` - All occurrences
- `mt792x_core.c` - All occurrences
- `mt792x_dma.c` - All occurrences

```bash
# In mt76_connac.h, rename the function:
# -static inline bool is_mt7921(struct mt76_dev *dev)
# +static inline bool is_connac2(struct mt76_dev *dev)

# Then replace all references in other files:
sed -i 's/is_mt7921/is_connac2/g' \
  mt76_connac_mac.c mt76_connac_mcu.c mt76_connac_mcu.h \
  mt792x_core.c mt792x_dma.c
```

### Patch 02/11: Use `mt76_for_each_q_rx()` in reset path

Replaces hardcoded NAPI disable calls with a loop over allocated RX queues, so the reset path works regardless of which queues exist.

**File:** `mt7921/pci_mac.c`

```c
// Before:
napi_disable(&dev->mt76.napi[MT_RXQ_MAIN]);
napi_disable(&dev->mt76.napi[MT_RXQ_MCU]);
napi_disable(&dev->mt76.napi[MT_RXQ_MCU_WA]);

// After:
mt76_for_each_q_rx(&dev->mt76, i) {
    napi_disable(&dev->mt76.napi[i]);
}
```

### Patch 03/11: Handle MT7902 IRQ map quirk

Creates a mutable copy of the IRQ map for MT7902 and zeros the `wm2_complete_mask` since MT7902 has no MCU_WA ring.

**File:** `mt7921/pci.c` (in probe function after `dev->irq_map = &irq_map`)

```c
if (id->device == 0x7902) {
    struct mt792x_irq_map *map;
    map = devm_kmemdup(&pdev->dev, &irq_map, sizeof(irq_map), GFP_KERNEL);
    if (!map)
        return -ENOMEM;
    map->rx.wm2_complete_mask = 0;
    dev->irq_map = map;
}
```

### Patch 04/11: Add MT7902 DMA layout support

Introduces a `mt7921_dma_layout` struct to parameterize the DMA init for MT7902-specific settings:
- MCU WM TXQ at index 15 (vs 17)
- MCU RX ring size 512 (vs 8)
- No MCU_WA ring

**Files:** `mt7921/mt7921.h`, `mt7921/pci.c`

Key additions to `mt7921.h`:
```c
#define MT7902_RX_MCU_RING_SIZE     512

enum mt7902_txq_id {
    MT7902_TXQ_MCU_WM = 15,
};

struct mt7921_dma_layout {
    u8 mcu_wm_txq;
    u16 mcu_rxdone_ring_size;
    bool has_mcu_wa;
};
```

### Patch 05/11: Mark MT7902 as hw txp device

Adds `0x7902` to the `is_mt76_fw_txp()` switch to return `false`, indicating MT7902 uses hardware TXP (same as other connac2 chips).

**File:** `mt76_connac.h`

```c
case 0x7902:  // added alongside 0x7961, 0x7920, 0x7922
```

### Patch 06/11: Add PSE handling barrier for large MCU commands

Adds a register read after MCU TX power commands to avoid PSE buffer underflow.

**Files:** `mt76_connac_mcu.c`, `mt792x_regs.h`

```c
// After each batch in mt76_connac_mcu_rate_txpower_band():
mt76_connac_mcu_reg_rr(dev, MT_PSE_BASE);

// New define in mt792x_regs.h:
#define MT_PSE_BASE  0x820c8000
```

### Patch 07/11: Ensure MCU ready before ROM patch download

Adds an MCU restart and readiness poll before firmware download begins.

**File:** `mt792x_core.c`

```c
// Added at start of mt792x_load_firmware():
mt76_connac_mcu_restart(&dev->mt76);
if (!mt76_poll_msec(dev, MT_CONN_ON_MISC, MT_TOP_MISC_FW_STATE,
                    MT_TOP_MISC2_FW_PWR_ON, 1000))
    dev_warn(dev->mt76.dev, "MCU is not ready for firmware download\n");
```

### Patch 08/11: Add MT7902 MCU support

Adds the `is_mt7902()` helper, includes MT7902 in the `is_connac2()` check, defines firmware paths, adds firmware name/patch name switch cases, and disables runtime PM for MT7902.

**Files:** `mt76_connac.h`, `mt792x.h`, `mt7921/init.c`

Key additions:
```c
// mt76_connac.h:
static inline bool is_mt7902(struct mt76_dev *dev)
{ return mt76_chip(dev) == 0x7902; }

// is_connac2() now includes: || is_mt7902(dev)

// mt792x.h:
#define MT7902_FIRMWARE_WM  "mediatek/WIFI_RAM_CODE_MT7902_1.bin"
#define MT7902_ROM_PATCH    "mediatek/WIFI_MT7902_patch_mcu_1_1_hdr.bin"
```

### Patch 09/11: Add MT7902 WFDMA prefetch configuration

Adds MT7902-specific prefetch register values for all TX and RX DMA rings.

**File:** `mt792x_dma.c`

```c
} else if (is_mt7902(&dev->mt76)) {
    /* rx ring */
    mt76_wr(dev, MT_WFDMA0_RX_RING0_EXT_CTRL, PREFETCH(0x0000, 0x4));
    mt76_wr(dev, MT_WFDMA0_RX_RING1_EXT_CTRL, PREFETCH(0x0040, 0x4));
    mt76_wr(dev, MT_WFDMA0_RX_RING2_EXT_CTRL, PREFETCH(0x0080, 0x4));
    mt76_wr(dev, MT_WFDMA0_RX_RING3_EXT_CTRL, PREFETCH(0x00c0, 0x4));
    /* tx ring */
    mt76_wr(dev, MT_WFDMA0_TX_RING0_EXT_CTRL, PREFETCH(0x0100, 0x4));
    mt76_wr(dev, MT_WFDMA0_TX_RING1_EXT_CTRL, PREFETCH(0x0140, 0x4));
    mt76_wr(dev, MT_WFDMA0_TX_RING2_EXT_CTRL, PREFETCH(0x0180, 0x4));
    mt76_wr(dev, MT_WFDMA0_TX_RING3_EXT_CTRL, PREFETCH(0x01c0, 0x4));
    mt76_wr(dev, MT_WFDMA0_TX_RING4_EXT_CTRL, PREFETCH(0x0200, 0x4));
    mt76_wr(dev, MT_WFDMA0_TX_RING5_EXT_CTRL, PREFETCH(0x0240, 0x4));
    mt76_wr(dev, MT_WFDMA0_TX_RING6_EXT_CTRL, PREFETCH(0x0280, 0x4));
    mt76_wr(dev, MT_WFDMA0_TX_RING15_EXT_CTRL, PREFETCH(0x02c0, 0x4));
    mt76_wr(dev, MT_WFDMA0_TX_RING16_EXT_CTRL, PREFETCH(0x0300, 0x4));
}
```

### Patch 10/11: Add MT7902 PCIe device support

Registers the MT7902 PCI device ID (`14c3:7902`) in the driver's device table and declares firmware files.

**File:** `mt7921/pci.c`

```c
// Device table:
{ PCI_DEVICE(PCI_VENDOR_ID_MEDIATEK, 0x7902),
    .driver_data = (kernel_ulong_t)MT7902_FIRMWARE_WM },

// Module firmware declarations:
MODULE_FIRMWARE(MT7902_FIRMWARE_WM);
MODULE_FIRMWARE(MT7902_ROM_PATCH);
```

### Patch 11/11: Add MT7902 SDIO support

Registers the MT7902 SDIO device ID for systems using SDIO interface.

**File:** `mt7921/sdio.c`

```c
{ SDIO_DEVICE(SDIO_VENDOR_ID_MEDIATEK, 0x7902),
    .driver_data = (kernel_ulong_t)MT7902_FIRMWARE_WM },
```

## Step 3: Update Firmware

**Critical step!** The firmware files shipped with `linux-firmware` before February 2026 are from July 2022 (extracted from Windows drivers) and **do not work** with this driver. You must update to the official December 2025 firmware submitted by MediaTek.

```bash
# Backup old firmware
sudo cp /lib/firmware/mediatek/WIFI_MT7902_patch_mcu_1_1_hdr.bin \
        /lib/firmware/mediatek/WIFI_MT7902_patch_mcu_1_1_hdr.bin.old
sudo cp /lib/firmware/mediatek/WIFI_RAM_CODE_MT7902_1.bin \
        /lib/firmware/mediatek/WIFI_RAM_CODE_MT7902_1.bin.old

# Download new firmware (Dec 2025, commit edc18bd4)
sudo wget -O /lib/firmware/mediatek/WIFI_MT7902_patch_mcu_1_1_hdr.bin \
  "https://gitlab.com/kernel-firmware/linux-firmware/-/raw/main/mediatek/WIFI_MT7902_patch_mcu_1_1_hdr.bin"

sudo wget -O /lib/firmware/mediatek/WIFI_RAM_CODE_MT7902_1.bin \
  "https://gitlab.com/kernel-firmware/linux-firmware/-/raw/main/mediatek/WIFI_RAM_CODE_MT7902_1.bin"
```

| File | Old Size (Jul 2022) | New Size (Dec 2025) |
|------|-------------------|-------------------|
| `WIFI_MT7902_patch_mcu_1_1_hdr.bin` | 118,432 bytes | 119,328 bytes |
| `WIFI_RAM_CODE_MT7902_1.bin` | 708,148 bytes | 716,944 bytes |

## Step 4: Build the Modules

```bash
cd ~/mt7902-driver

# Build against running kernel headers
make -C /lib/modules/$(uname -r)/build \
  M=$(pwd)/drivers/net/wireless/mediatek/mt76 modules
```

This builds all mt76 family modules. The key output files are:
- `mt76.ko` - Core mt76 module
- `mt76-connac-lib.ko` - Connac helper library
- `mt792x-lib.ko` - MT792x common library
- `mt7921/mt7921-common.ko` - MT7921 family common code
- `mt7921/mt7921e.ko` - PCIe driver (the main driver)

## Step 5: Install the Modules

```bash
SRCDIR="drivers/net/wireless/mediatek/mt76"
MODDIR="/lib/modules/$(uname -r)/kernel/drivers/net/wireless/mediatek/mt76"

# Backup existing modules
mkdir -p ~/mt7902-driver/backup_modules/mt7921
cp $MODDIR/mt76.ko.zst $MODDIR/mt76-connac-lib.ko.zst \
   $MODDIR/mt792x-lib.ko.zst ~/mt7902-driver/backup_modules/
cp $MODDIR/mt7921/*.ko.zst ~/mt7902-driver/backup_modules/mt7921/

# Install new modules (uncompressed .ko replaces compressed .ko.zst)
sudo cp $SRCDIR/mt76.ko $MODDIR/mt76.ko
sudo cp $SRCDIR/mt76-connac-lib.ko $MODDIR/mt76-connac-lib.ko
sudo cp $SRCDIR/mt792x-lib.ko $MODDIR/mt792x-lib.ko
sudo cp $SRCDIR/mt7921/mt7921-common.ko $MODDIR/mt7921/mt7921-common.ko
sudo cp $SRCDIR/mt7921/mt7921e.ko $MODDIR/mt7921/mt7921e.ko
sudo cp $SRCDIR/mt7921/mt7921s.ko $MODDIR/mt7921/mt7921s.ko
sudo cp $SRCDIR/mt7921/mt7921u.ko $MODDIR/mt7921/mt7921u.ko

# Remove old compressed modules (kernel prefers .ko.zst over .ko)
sudo rm -f $MODDIR/mt76.ko.zst $MODDIR/mt76-connac-lib.ko.zst \
           $MODDIR/mt792x-lib.ko.zst \
           $MODDIR/mt7921/mt7921-common.ko.zst \
           $MODDIR/mt7921/mt7921e.ko.zst \
           $MODDIR/mt7921/mt7921s.ko.zst \
           $MODDIR/mt7921/mt7921u.ko.zst

# Regenerate module dependencies
sudo depmod -a
```

## Step 6: Load and Verify

```bash
# Reset the PCI device (important for first load!)
echo 1 | sudo tee /sys/bus/pci/devices/0000:02:00.0/remove
sleep 2
echo 1 | sudo tee /sys/bus/pci/rescan
sleep 2

# Load the driver with ASPM disabled
sudo modprobe mt7921e disable_aspm=1

# Verify
iw dev                    # Should show the new wlan interface
dmesg | grep mt7921e      # Check for successful initialization
ip link show              # Interface should be visible
```

## Step 7: Make It Persistent

To ensure the driver loads with `disable_aspm=1` on every boot:

```bash
echo "options mt7921e disable_aspm=1" | sudo tee /etc/modprobe.d/mt7902.conf
```

## Troubleshooting

### "driver own failed" (error -5)
The PCI device needs a reset before the driver can claim it:
```bash
echo 1 | sudo tee /sys/bus/pci/devices/0000:02:00.0/remove
sleep 2
echo 1 | sudo tee /sys/bus/pci/rescan
```

### MCU message timeouts with old firmware
If you see `Message 00020001 (seq X) timeout` repeating with `Build Time: 20220729`, your firmware is the old July 2022 version. Update to the December 2025 firmware (see Step 3).

### Module not auto-loading
Verify the PCI alias exists:
```bash
modinfo mt7921e | grep 7902
# Should show: alias: pci:v000014C3d00007902sv*sd*bc*sc*i*
```

### Reverting changes
To restore original modules:
```bash
MODDIR="/lib/modules/$(uname -r)/kernel/drivers/net/wireless/mediatek/mt76"
sudo cp ~/mt7902-driver/backup_modules/*.ko.zst $MODDIR/
sudo cp ~/mt7902-driver/backup_modules/mt7921/*.ko.zst $MODDIR/mt7921/
sudo rm -f $MODDIR/mt76.ko $MODDIR/mt76-connac-lib.ko $MODDIR/mt792x-lib.ko
sudo rm -f $MODDIR/mt7921/mt7921-common.ko $MODDIR/mt7921/mt7921e.ko
sudo rm -f $MODDIR/mt7921/mt7921s.ko $MODDIR/mt7921/mt7921u.ko
sudo depmod -a
```

## Step 7: DKMS Setup (Survive Kernel Updates)

To prevent the driver from breaking on future kernel updates, set up DKMS:

```bash
# Copy the patched mt76 source to DKMS
sudo mkdir -p /usr/src/mt7902-wifi-1.0.0
sudo cp -a drivers/net/wireless/mediatek/mt76/* /usr/src/mt7902-wifi-1.0.0/
```

Create `/usr/src/mt7902-wifi-1.0.0/dkms.conf`:
```ini
PACKAGE_NAME="mt7902-wifi"
PACKAGE_VERSION="1.0.0"

MAKE="make -C /lib/modules/${kernelver}/build M=${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/build modules"

BUILT_MODULE_NAME[0]="mt76"
BUILT_MODULE_LOCATION[0]=""
DEST_MODULE_LOCATION[0]="/updates/dkms"

BUILT_MODULE_NAME[1]="mt76-connac-lib"
BUILT_MODULE_LOCATION[1]=""
DEST_MODULE_LOCATION[1]="/updates/dkms"

BUILT_MODULE_NAME[2]="mt792x-lib"
BUILT_MODULE_LOCATION[2]=""
DEST_MODULE_LOCATION[2]="/updates/dkms"

BUILT_MODULE_NAME[3]="mt7921-common"
BUILT_MODULE_LOCATION[3]="mt7921/"
DEST_MODULE_LOCATION[3]="/updates/dkms"

BUILT_MODULE_NAME[4]="mt7921e"
BUILT_MODULE_LOCATION[4]="mt7921/"
DEST_MODULE_LOCATION[4]="/updates/dkms"

BUILT_MODULE_NAME[5]="mt7921s"
BUILT_MODULE_LOCATION[5]="mt7921/"
DEST_MODULE_LOCATION[5]="/updates/dkms"

BUILT_MODULE_NAME[6]="mt7921u"
BUILT_MODULE_LOCATION[6]="mt7921/"
DEST_MODULE_LOCATION[6]="/updates/dkms"

AUTOINSTALL="yes"

POST_INSTALL="post-install.sh"
```

Create `/usr/src/mt7902-wifi-1.0.0/post-install.sh`:
```bash
#!/bin/bash
MODDIR="/lib/modules/${kernelver}/kernel/drivers/net/wireless/mediatek/mt76"
rm -f "$MODDIR/mt76.ko.zst" "$MODDIR/mt76-connac-lib.ko.zst" \
      "$MODDIR/mt792x-lib.ko.zst" "$MODDIR/mt7921/mt7921-common.ko.zst" \
      "$MODDIR/mt7921/mt7921e.ko.zst" "$MODDIR/mt7921/mt7921s.ko.zst" \
      "$MODDIR/mt7921/mt7921u.ko.zst" 2>/dev/null
```

Then register and build:
```bash
sudo dkms add mt7902-wifi/1.0.0
sudo dkms build mt7902-wifi/1.0.0
sudo dkms install mt7902-wifi/1.0.0 --force
```

## Bluetooth

The MT7902 includes a Bluetooth chip exposed as a USB device (`13d3:3579` / IMC Networks Wireless_Device). Bluetooth support requires patched `btusb`/`btmtk` modules — see the companion repo at `../bt-driver-mt7902/`. A DKMS module (`mt7902-bt`) is also available for automatic rebuild on kernel updates.

## Upstream Status

- **Kernel patches**: 11-patch series by Sean Wang, posted Feb 19, 2026 to linux-wireless, targeting Linux 7.1
  - Lore: `https://lore.kernel.org/linux-wireless/20260219004007.19733-1-sean.wang@kernel.org/`
- **Firmware**: Committed to linux-firmware on Feb 21, 2026 (commit `edc18bd4`)
  - GitLab: `https://gitlab.com/kernel-firmware/linux-firmware/-/commit/edc18bd4`
- **Expected mainline**: Linux 7.1 (merge window ~April 2026)

## Tested Configuration

| Component | Version |
|-----------|---------|
| **Laptop** | ASUS Vivobook 14 |
| **Kernel** | 6.17.7-arch1-2, 6.19.8-arch1-1 |
| **OS** | Arch Linux |
| **GCC** | 15.2.1 |
| **Firmware (patch)** | Build 20251212032046a (119,328 bytes) |
| **Firmware (RAM)** | Build 20251212032127 (716,944 bytes) |
| **Driver** | mt7921e with MT7902 patches (DKMS) |

## Credits

- **Sean Wang** (MediaTek) - Original 11-patch series and firmware submission
- **Xiong Huang** (MediaTek) - Co-developer on several patches
- **Lorenzo Bianconi** - mt76 driver maintainer
- **nbd (Felix Fietkau)** - mt76 driver creator and maintainer

## License

The mt76 driver is dual-licensed under BSD/GPL. All patches follow the same licensing.
