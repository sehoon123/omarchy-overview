# Hyprland 0.56.2: screenshare monitor-lifetime fix

Local maintenance patch, 2026-09-21. This is **not an upstream release** and does
not claim to fix unrelated Hyprland/driver crashes.

## Why the Overview capture guard stays off

The installed Overview had been changed outside Git to set
`windowCaptureEnabled: false` after a compositor crash. Those existing protective
changes are now tracked in this repository. Window selection/navigation remain
available; window thumbnails, hidden capture and preview priming are disabled.
The old `keepCache` setting does not override this guard.

Crash records identified Hyprland's window-screenshare initialization accessing
a missing monitor during output removal. A client-side output check cannot
eliminate the race between its check and the compositor processing a request.
The fix belongs in the compositor, not in an unconditional re-enable of previews.

## Patch scope

Based on upstream **v0.56.2**, commit
`efb50993780079460b0cbed1363e2166a2de1d9f`:

- Validate monitor availability before initializing a capture session or attaching
  listeners. Invalid sources produce stopped/unpublished sessions.
- Use the validated factory for managed captures too; reject unmapped windows and
  windows without an available monitor.
- Stop cleanly when the window loses its monitor. A stopped session cannot resume
  from late metadata, and failed constraint updates do not emit further events.
- Keep only a value-based identity while erasing managed sessions, rather than a
  reference into the object being destroyed.
- Toplevel-export and screencopy frame constructors send `failed` for unavailable
  sessions. Later copy requests also check frame/session validity.

See `0001-screenshare-monitor-lifetime.patch`. The surrounding code retains its
[upstream BSD-3-Clause license](LICENSE.Hyprland).

## Build and install

`PKGBUILD` is derived from [Arch's 0.56.2-2 recipe](https://gitlab.archlinux.org/archlinux/packaging/packages/hyprland/-/raw/0.56.2-2/PKGBUILD).
It retains the official source archive checksum, dependencies and system-glaze
adjustment. The local release is **0.56.2-2.1**. Compilation defaults to four jobs.
Build products/source archives belong outside the Overview installation/repo.

On a compatible Arch/Omarchy installation, from this directory:

```sh
omarchy pkg add base-devel cmake meson ninja glaze hyprland-protocols gtest
work=$(mktemp -d "$HOME/.cache/overview-hyprland.XXXXXX")
cp PKGBUILD 0001-screenshare-monitor-lifetime.patch "$work/"
(cd "$work" && makepkg --log)
python3 test_monitor_lifetime.py "$work/src/hyprland-source"
```

Review the package and keep a rollback package before installing. Normal terminal
installation (requires administrator authentication):

```sh
sudo pacman -Sw hyprland  # preserve the official package before replacement
sudo pacman -U "$work/hyprland-0.56.2-2.1-$(uname -m).pkg.tar.zst"
```

Do not manually overwrite `/usr/bin/Hyprland`, disable package signature checks,
or edit `/usr/share/omarchy`. The package has no install script and does not
restart the graphical session.

**Installing is not activation.** Save work and log out/in when convenient. A
config reload or restarting Overview cannot replace the running compositor.

```sh
pacman -Q hyprland                     # installed package
/usr/bin/Hyprland --version-json       # binary on disk
hyprctl -j version                     # currently running compositor
```

The patched binary reports tag **`v0.56.2-overview-monitor-fix1`**, with
`dirty: true` to identify local changes. Both binary and live-session checks
must show this marker before considering preview restoration. The package does
**not** change `windowCaptureEnabled`; leave it false until the new session is
confirmed and the normal preview path can be validated without disrupting work.

A later official package may supersede this local release. Do not permanently
freeze system updates; check whether the replacement contains the fix and keep
captures disabled if that has not been established.

## Verification and limits

Completed on 2026-09-21:

- Full release build and package creation against the installed libraries.
- Source archive/patch SHA256 validation; package file list matches the official
  package. Installed package integrity: 639 files, zero altered files.
- 11 offline C++ regression tests with AddressSanitizer and UndefinedBehaviorSanitizer.
  They compile the actual patched session/factory method bodies, use real
  Hyprutils smart pointers/signals, and fake windows, outputs, timers and rendering.
  They never connect to Wayland or launch a compositor. The runner refuses a
  source tree that does not contain this patch.
- Two **source-contract** checks for protocol failure handling, not wire-level tests.
- Overview validation: 160 layout combinations, 11 JS tests, 26 Python tests,
  47 Qt/QML test results; all passed.

The currently running desktop was deliberately **not restarted** during repair.
Physical hotplug, driver behavior, post-login startup and real preview rendering
have **not** been validated by these offline checks. No monitors were powered
OFF/ON or disconnected for testing. Preview capture remains disabled.

## Rollback

Keep capture disabled before and after rollback. Using the previously saved,
signed stock package (adjust its path):

```sh
sudo pacman -U /path/to/hyprland-0.56.2-2-x86_64.pkg.tar.zst
```

Log out/in after saving work to activate the old binary. This restores the known
compositor defect too, which is why the Overview capture guard must remain off.
No personal settings, desktop ordering or user applications need to be removed.
