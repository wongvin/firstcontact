# iOS target — conventions

Native iOS app at `ios/FirstContact/`. SwiftUI, `URLSession` + `async/await`, no third-party dependencies. Personal-use only; signed with a free Apple ID. Not distributed via TestFlight or the App Store.

## Free Apple ID signing — the chicken-and-egg

A Personal Team (free Apple ID) cannot generate any provisioning profile until at least one device is registered to the team. Manually adding device UDIDs at developer.apple.com is paid-tier-only. The bootstrap order is therefore non-obvious — see [#6's resolution](https://github.com/wongvin/firstcontact/issues/6#issuecomment-4322861487) and the [underlying rule](https://github.com/wongvin/firstcontact/issues/6#issuecomment-4322861648).

Setup sequence for a fresh iOS project on free signing:

1. Create the Xcode project. Don't worry about Signing & Capabilities yet.
2. Plug iPhone in via USB → trust the Mac → enable Developer Mode (next section).
3. *Then* set Team in Signing & Capabilities. Provisioning profile generates.

## First install on a physical iPhone (via USB)

One-time per device:

1. Connect iPhone to Mac via USB cable.
2. iPhone: tap **Trust This Computer**, enter passcode if prompted.
3. iPhone: Settings → Privacy & Security → scroll to **Developer Mode** → toggle on → reboot. After reboot, unlock and tap **Turn On** on the prompt that appears.
4. Xcode: pick your iPhone in the destination dropdown → Run (⌘R). Xcode signs, installs, launches.

Free signing's provisioning profile expires after ~7 days. To refresh: plug in (or use wireless deployment, below) and Run from Xcode again. The app icon stays on the home screen between expiries; tapping a stale install just shows "Untrusted Developer" until re-signed.

If the iPhone doesn't appear in Xcode after USB connect:
- Window → Devices and Simulators → check whether it shows up there.
- Ensure iPhone is unlocked and "Trust This Computer" was accepted.
- `xcrun devicectl list devices` from terminal lists what Xcode sees.

## Wireless deployment

After the initial USB pair, you can deploy over WiFi instead of cabling.

1. Plug iPhone into Mac via USB.
2. Xcode → Window → Devices and Simulators → select your iPhone → check **Connect via network**.
3. Wait for the network icon (chain link) to appear next to the device name.
4. Disconnect the cable. The iPhone stays in the Xcode destination dropdown as long as both Mac and iPhone share a WiFi network and the phone is unlocked.

If the wireless connection drops:
- Confirm both devices are on the same network.
- iPhone must be unlocked for Xcode to discover it.
- Recovery: re-cable for a moment to re-establish the pair.

## Capabilities not available on free signing

- TestFlight and App Store distribution (paid Apple Developer Program, $99/yr)
- Push notifications, App Groups, iCloud / CloudKit, in-app purchase, Sign-in-with-Apple
- Provisioning profile lifetime ~1 year on paid accounts vs. ~7 days on free

If a future feature needs any of the above, the project graduates to paid signing.
