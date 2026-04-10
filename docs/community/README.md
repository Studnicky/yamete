# yamete-accel-warmup

**What it is**: a tiny open-source helper that starts the built-in BMI286
accelerometer on Apple Silicon MacBooks so the Yamete App Store build can
read its 100Hz report stream.

**Why you need it**: Yamete on the Mac App Store runs under App Sandbox.
The sandbox silently blocks the IORegistry writes that tell the accelerometer
to start reporting, so inside the sandbox Yamete cannot wake the sensor on
its own. Until something *outside* the sandbox warms the sensor, the adapter
reports as unavailable and the app falls back to microphone + headphone-motion
only.

**Who should install it**: users on an M1 / M2 / M3 / M4 MacBook Air or
MacBook Pro who want the tactile detection channel (desk slaps and taps
picked up through the laptop chassis) in addition to the microphone. On
Macs without the BMI286 (iMac, Mac Mini, Mac Studio, Mac Pro, Intel Macs),
this helper does nothing useful — there is no sensor to warm.

**Who should NOT install it**: anyone who is not comfortable compiling a
~150-line Swift source file and installing a LaunchDaemon as root. The
microphone detection path in the App Store build works on every Mac with
zero setup, and headphone-motion works whenever AirPods / Beats are
connected. You don't need this helper for Yamete to function.

## Report issues (please!)

**If this helper doesn't work on your Mac, we want to know.** The
`AppleSPUHIDDriver` property surface is undocumented — Apple can change
it at any macOS update, and it is physically only available on a subset
of Apple Silicon MacBooks we haven't all tested. Verification relies on
the community.

**File a report here**: <https://github.com/Studnicky/yamete/issues/new>

Please include:

- **Your Mac model**: e.g., "MacBook Pro 14-inch, M2 Pro, 2023". The
  "About This Mac" dialog has all of this.
- **Your macOS version**: full string including the point release, e.g.
  `14.5 (23F79)`.
- **What you were expecting vs. what happened**: one line each is fine.
- **Output of the probe command, before and after running `warmup`**:
  ```bash
  /usr/local/libexec/yamete-accel-warmup probe
  /usr/local/libexec/yamete-accel-warmup warmup
  /usr/local/libexec/yamete-accel-warmup probe
  ```
- **The last 20 lines of the LaunchDaemon log** (after a reboot if you
  can reproduce the issue at boot):
  ```bash
  tail -20 /var/log/yamete-accel-warmup.log
  ```
- **The last 20 lines of the Yamete app log** (helpful for cross-
  referencing the probe result with what Yamete actually saw):
  ```bash
  tail -20 "$HOME/Library/Containers/com.studnicky.yamete/Data/Library/Application Support/Yamete/logs/yamete-$(date +%Y-%m-%d).log"
  ```

Reports on Macs where this **does** work are just as valuable as reports
where it doesn't — we are building a known-working matrix and every data
point helps.

## Safety notes

1. **This is an open-source community helper, not an Apple-sanctioned
   interface.** The three property writes it issues (`ReportInterval`,
   `SensorPropertyReportingState`, `SensorPropertyPowerState` on the
   `AppleSPUHIDDriver` service) are Apple-internal driver commands. They
   are invoked via public IOKit functions with no private API imports,
   but the property keys themselves are undocumented. A future macOS
   update can change or remove this surface without warning.
2. **It runs as root via a LaunchDaemon.** That is necessary because
   LaunchDaemons execute outside of any user's App Sandbox. Review the
   source (`yamete-accel-warmup.swift`) before running the installer
   if you want to audit exactly what it does — it is short enough to
   read in a few minutes.
3. **It does not touch the network, write to user data, load kexts,
   install launch agents as other users, or persist anything other
   than the LaunchDaemon plist + the compiled binary.** The install
   paths are `/usr/local/libexec/yamete-accel-warmup` and
   `/Library/LaunchDaemons/com.studnicky.yamete.accel-warmup.plist`.
   The uninstall script removes both.
4. **`sudo` is required** for the install and uninstall scripts. You
   will be prompted for your admin password.

## Files in this gist

- **`yamete-accel-warmup.swift`** — the helper source (single file,
  uses only `Foundation` and `IOKit`). Implements `probe`, `warmup`,
  and `deactivate` subcommands. The LaunchDaemon invokes `warmup`.
- **`com.studnicky.yamete.accel-warmup.plist`** — the LaunchDaemon
  plist. `RunAtLoad = true`, `KeepAlive = false` — the helper runs
  once at boot, warms the sensor, and exits. Logs to
  `/var/log/yamete-accel-warmup.log`.
- **`install.sh`** — compiles the Swift file with `swiftc`, copies the
  binary to `/usr/local/libexec/`, copies the plist to
  `/Library/LaunchDaemons/`, and loads it with `launchctl bootstrap`.
- **`uninstall.sh`** — unloads the LaunchDaemon and removes both files
  and the log.

## Installation

Download all four files from the gist into a fresh directory and run:

```bash
chmod +x install.sh uninstall.sh
./install.sh
```

The installer will:
1. Verify the Mac is `arm64` (Apple Silicon).
2. Compile `yamete-accel-warmup.swift` with `swiftc`.
3. Smoke-test the compiled binary against the probe subcommand.
4. Unload any previously-installed version of the LaunchDaemon.
5. Copy the binary and plist to their system locations (sudo prompt).
6. Load the LaunchDaemon with `launchctl bootstrap` (triggers `RunAtLoad`
   — the sensor warms up immediately).
7. Probe the sensor again to confirm the warmup succeeded.

If the final probe succeeds, launch or relaunch Yamete. Open the menu
bar dropdown, expand the Sensors section, and toggle **Accelerometer**
on. You should see the accelerometer detecting desk taps alongside the
microphone.

From the next reboot onward, the LaunchDaemon runs automatically at boot
and Yamete picks up the warm sensor without any further action.

## Uninstallation

```bash
./uninstall.sh
```

This unloads the LaunchDaemon, removes the installed files, and removes
the log. After uninstall, the accelerometer goes cold on the next reboot
and Yamete silently falls back to microphone + headphone-motion.

## Troubleshooting

**`probe: active=false` after installing**  
The LaunchDaemon may have run before the IOKit service matching became
ready. Try forcing it to run again:

```bash
sudo launchctl kickstart -k system/com.studnicky.yamete.accel-warmup
/usr/local/libexec/yamete-accel-warmup probe
```

**`probe: no AppleSPUHIDDriver dispatchAccel=Yes service found`**  
Your Mac doesn't have the BMI286 accelerometer (iMac, Mac Mini, Mac
Studio, Mac Pro, or Intel Mac). The helper won't help on this hardware;
Yamete will run on microphone + headphone-motion only.

**`error: this helper is only useful on Apple Silicon Macs`**  
The installer detected an Intel architecture. Even if you're running
the Intel build of macOS on Apple Silicon via Rosetta (you shouldn't
be), the IOKit calls need native arm64. Nothing to do here.

**Yamete still doesn't show the Accelerometer in the Sensors list**  
Open the Yamete menu bar dropdown once after the helper has run. The
sensor availability is probed when the dropdown opens. Also make sure
you toggled the Accelerometer row on — the helper warms the hardware
but doesn't change Yamete's settings.

**Does the sensor survive sleep/wake?**  
Yes. Verified on Apple Silicon: the BMI286 is in the always-on power
domain, so once warmed it streams continuously at 100Hz across lid
close / open cycles without interruption. The `RunAtLoad`-only
LaunchDaemon runs the helper once per boot and that single warm-up
carries the sensor through every subsequent sleep/wake until the next
reboot. If you observe any deviation (the sensor going cold after
sleep on a specific Mac model or macOS revision), please file an
issue at <https://github.com/Studnicky/yamete/issues> — we will add a
wake watcher to the plist if a counter-example turns up.

## License

This helper is released under the MIT License (same as Yamete itself).
Do whatever you like with it.
