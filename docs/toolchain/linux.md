# Linux notes

> Status: reported (community tested on Mint 21.2 / Fedora 38 with Quartus 20.1/22.1),
> not verified in this lab

## Quartus

Install the same way (`./QuartusProSetup-...run --mode unattended --installdir ~/altera/25.1`).
Quartus on Linux needs the usual 32-bit compatibility libraries for older versions; 25.1 is
64-bit only.

## FTDI driver

Remove the kernel serial driver so D2XX can claim the FT232H:

```bash
sudo modprobe -r ftdi_sio
```

Make it permanent with a udev rule (example):

```
# /etc/udev/rules.d/92-usbblaster.rules
SUBSYSTEM=="usb", ATTR{idVendor}=="0403", ATTR{idProduct}=="6014", MODE="0664", GROUP="plugdev"
```

Then:

```bash
sudo udevadm control --reload-rules
sudo udevadm trigger
sudo adduser $USER plugdev
```

## Plugin

```bash
sudo cp hardware/tools/usb-blaster/libjtag_hw_microsoft_catapult.so <quartus>/linux64/
sudo chmod 0755 <quartus>/linux64/libjtag_hw_microsoft_catapult.so
jtagconfig
```

The plugin links against `libftd2xx.so`; install the vendor library:

```bash
wget https://ftdichip.com/wp-content/uploads/2022/07/libftd2xx-x86_64-1.4.27.tgz
tar xf libftd2xx-x86_64-1.4.27.tgz
sudo cp release/build/libftd2xx.so.1.4.27 /usr/lib/
sudo ln -sf /usr/lib/libftd2xx.so.1.4.27 /usr/lib/libftd2xx.so
sudo ldconfig
```

Alternatively build [jtag-mpsse-blaster](https://github.com/tow3rs/jtag-mpsse-blaster)
(`make && sudo cp libjtag_hw_mpsse.so <quartus>/linux64/`).

## udev conflicts

If `jtagconfig` reports "permission denied", check that no other process holds the device:

```bash
fuser -v /dev/bus/usb/*/*
```

## Host PCIe

```bash
lspci -nn -vv | grep -A20 1414:
sudo lspci -vv -s 02:00.0 | grep -E 'LnkCap|LnkSta'
```

Bind a design with a standard vendor/device ID to VFIO for userspace BAR access:

```bash
sudo modprobe vfio-pci
echo 1172 e003 | sudo tee /sys/bus/pci/drivers/vfio-pci/new_id
```

## Flash tools

`flashrom` can program the N25Q00AA **only** with an external SPI clip; the on-board path is
JTAG + SFL and therefore Quartus-only.

## Known differences from Windows

- `quartus_pgm` needs the plugin `.so`, not the `.dll`.
- USB autosuspend can drop the FT232H; add `usbcore.autosuspend=-1` to the kernel command
  line if scans are flaky.
- Some distributions ship an `ftdi_sio` udev rule that re-binds the device after
  `modprobe -r`; blacklist it:

```
# /etc/modprobe.d/blacklist-ftdi.conf
blacklist ftdi_sio
```
