# XNotch for iPhone and iPad

Sends files and text from an iPhone or iPad to XNotch on a Mac on the same network, and receives files the Mac sends back. It has two parts:

- **The app**: pair with a Mac, then fill the basket with photos and files, send text to the Mac's clipboard, or paste what you copied. Files from the Mac appear under **From your Mac**, and in the Files app under On My iPhone → XNotch → From Mac.
- **The Share extension**: XNotch in every share sheet. It connects, sends, and closes on its own.

On the Mac, add the **iPhone & iPad** extension in XNotch Settings → Extensions.

## Build and install

Requires Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). `project.yml` is the source of the Xcode project; after changing it, run:

```sh
cd Companion
xcodegen
open XNotchCompanion.xcodeproj
```

Pick your iPhone or iPad as the run destination and press Run. Signing is automatic with team `59UPSTU6WZ`; to use another team, change `DEVELOPMENT_TEAM` in `project.yml`. The app and its extension share pairings through a Keychain group, so both need the same team. A free Apple account works for your own devices, but its builds expire after 7 days.

## Pairing

On the Mac, open XNotch Settings → Extensions → iPhone & iPad. Scan its code with **Scan Code** in the app, or with the Camera app: the code is an `xnotchlink://pair` link that opens XNotch. You can pair several Macs and choose which one to send to from the Mac name at the bottom of the app.

The code carries the Mac's link ID, a random 256-bit key and, if set up, the Mac's relay server. The Mac also names its relay every time they connect, so adding one later needs no new code.

## Routes

The app keeps the fastest route that's up and moves to a faster one when it appears; the card at the top says which (USB, Wi-Fi, Nearby, Internet, Bluetooth).

- **USB**: while the app is open it listens on a loopback port (47812); a Mac with the iPhone plugged in reaches it through usbmuxd, as Xcode does. Trust the Mac when the iPhone asks.
- **Wi-Fi**: Bonjour (`_xnotchlink._tcp`) on the same network, or peer-to-peer Wi-Fi when the devices are close. iOS asks once for Local Network access; without it, allow it under Settings → Privacy & Security → Local Network.
- **Internet**: after a moment without a faster route, through the relay on the Mac's XNotch Cloud server (see Server/README.md). Both sides connect out, so it works behind any router.
- **Bluetooth**: after a few seconds without anything faster, an L2CAP channel. iOS asks once. Much slower than the rest; fine for text and photos.

The Share extension tries USB, Wi-Fi and the internet together and uses whichever connects first; Bluetooth is left to the app.

Every route runs the same secure channel: both sides prove they hold the pairing key, agree fresh keys for the connection (X25519), and encrypt and authenticate every record (ChaCha20-Poly1305). The relay only ever sees ciphertext. Resetting the pairing on the Mac unpairs every device.

## Limits

- The Mac has to be awake and running XNotch with the extension switched on.
- The app stays connected only while it's open, so files the Mac sends wait for that. If you leave mid-transfer, iOS gives the app a short time to finish.
- A file that was cut off by a route going away starts again from the beginning on the next route.
- Folders are sent as zip files.
