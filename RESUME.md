# AirPlay Tiger Receiver Resume

## Project
- Name: AirPlay Tiger Receiver
- Target platform: macOS 10.4 Tiger, PowerPC + Intel
- Goal: receive audio from an AirPlay source and play it locally with metadata, cover art, playback controls, and optional Growl notifications

## Current status
This project is in a mature protocol skeleton and UI integration state.

### Completed
- App skeleton and Cocoa UI
- playback controls: play/pause, previous, next, volume
- metadata display for title, artist, and album
- cover art display and placeholder artwork rendering
- optional Growl notification integration
- Bonjour / discovery-related receiver skeleton
- RTSP session and transport handling skeleton
- RTP packet validation and flow logic
- metadata plist parsing and artwork extraction
- ALAC frame parsing and reassembly logic
- sender-like validation for transport, metadata, and ALAC payloads
- CoreAudio queue setup and output buffer flow
- compile validation in a legacy Objective-C configuration
- Tiger-era ICNS app icon generated from `Resources/Images/PowerPlay_icon.png`

### Known caveat
The implementation is not yet proven against a live AirPlay sender stream. The validation so far is synthetic and sender-model based rather than packet capture based.

## Important files
- App/AirPlayReceiverAppDelegate.h
- App/AirPlayReceiverAppDelegate.m
- Network/RAOPReceiver.h
- Network/RAOPReceiver.m
- Audio/ALACDecoder.h
- Audio/ALACDecoder.m
- Audio/CoreAudioPlayer.h
- Audio/CoreAudioPlayer.m
- Metadata/AirPlayMetadataParser.h
- Metadata/AirPlayMetadataParser.m
- UI/CoverArtView.m
- App/GrowlNotifier.m

## Remaining high-priority work
1. Rebuild on the target machine and verify there is only one bold `PowerPlay` menu entry next to the Apple logo, with the submenu on the correct item
2. Verify app icon appearance on Tiger or a Tiger-compatible system
3. Validate with a real AirPlay sender trace
4. Confirm RTSP/RTP negotiation matches actual sender behavior
5. Verify ALAC decoding and audio timing against genuine sender payloads
6. Check remaining PowerPC / Tiger compatibility specifics on legacy hardware

## Build verification
Last successful syntax-only compile command:

clang -fno-objc-arc -fsyntax-only -I. -IApp -IAudio -INetwork -IMetadata -IUI -framework Cocoa -framework CoreAudio -framework AudioToolbox -DAIRPLAY_GROWL_AVAILABLE=0 App/AirPlayReceiverAppDelegate.m App/GrowlNotifier.m App/main.m Audio/ALACDecoder.m Audio/CoreAudioPlayer.m Metadata/AirPlayMetadataParser.m Network/RAOPReceiver.m UI/CoverArtView.m

Result: exit code 0; no syntax or parser errors. Only deprecation warnings from the modern SDK appeared.

Limitation: Xcode 2.5 and the Tiger SDK are not available in this environment. Xcode 27 is installed, but it cannot open this Xcode 2.5 project. The syntax-only compile succeeds with legacy deprecation warnings; a full target build and runtime verification must happen on the Tiger machine.

## Runtime packaging status
`Project/MainMenu.xib` is the project-referenced source; a separate `Interface/MainMenu.xib` also exists and remains unchanged. Both `PowerPlay.xcodeproj` and the Xcode 2.5-compatible `PowerPlayApp.xcodeproj` now include `Project/MainMenu.nib` in the target Resources phase instead of copying the raw XIB. The user reports that the app now launches on the target machine.

The main menu source contains About, Hide, Hide Others, Show All, and Quit actions. The app's first target-side report showed only the `PowerPlay` menu title and no dropdown. The executable on the iMac was at `9069eaf` and contained the menu labels, but that did not prove the launch callback ran. Inspection found that `AirPlayReceiverAppDelegate` was declared in `Project/MainMenu.xib` but was not connected to `NSApplication`; therefore `applicationDidFinishLaunching` could not install the programmatic menu. The delegate outlet is now connected, and both nib files (`keyedobjects.nib` and `keyedobjects-101300.nib`) were regenerated with Xcode 27's `ibtool`; the compiled archive contains the delegate connection and menu labels.

A later Tiger-side symptom showed two `PowerPlay` entries in the menu bar: one bold item adjacent to the Apple logo and a second normal-weight item with the submenu. The root cause was a second runtime-created menu in `AirPlayReceiverAppDelegate` alongside the XIB menu. That extra menu creation was removed in commit `77618ad` (`Remove duplicate PowerPlay app menu`). The app should now leave the single bold `PowerPlay` application menu in place, with the submenu appearing on that same item.

Commit `77618ad` (`Remove duplicate PowerPlay app menu`) is pushed to `origin/main`. The Tiger machine still needs to rebuild from this commit and confirm that the main menu shows only one `PowerPlay` item with the submenu on the correct entry. The modern-compiled nib's Tiger runtime compatibility remains unverified. The project files pass `plutil -lint`. Xcode 27's `xcodebuild` rejects the Xcode 2.5 project format, so this environment cannot perform a full target build.

## App icon status
`Resources/Images/PowerPlay.icns` was replaced with a classic RGB/mask ICNS containing 16, 32, 48, and 128 pixel variants and no embedded PNG chunks. The container and decoding were validated with `iconutil`, but actual display on Tiger remains unverified. The source image is `Resources/Images/PowerPlay_icon.png`.

The icon and its source were committed and pushed to `origin/main` as `f864dcc` (`Add Tiger-compatible PowerPlay app icon`).

## Resume summary
Latest pushed commit: `77618ad` (`Remove duplicate PowerPlay app menu`). Earlier fixes included `bd1ea8b` (`Connect application delegate in main nib`) and `9069eaf` (`Build application menu programmatically`). The current task is to pull this latest fix onto the Tiger iMac, clean rebuild `PowerPlayApp.xcodeproj`, and confirm that a single bold `PowerPlay` menu item remains next to the Apple logo and that the submenu items are attached to that correct entry. The icon remains committed and pending on-device confirmation.

## Latest checkpoint
- The Tiger-side startup error was `Unable to load nib file: MainMenu, exiting`.
- Root cause: the bundle still had a `MainMenu` nib requested via `NSMainNibFile` in [Project/Info.plist](Project/Info.plist), even though the nib had been removed and the app is intended to create the menu programmatically in [App/AirPlayReceiverAppDelegate.m](App/AirPlayReceiverAppDelegate.m).
- Fix: removed the `NSMainNibFile` entry from [Project/Info.plist](Project/Info.plist) and removed the stale compiled nib resource from the Xcode project files so the app no longer loads an old menu definition.
- Current state: the app should boot without trying to load `MainMenu`, and only the runtime-created app menu should remain.
- Remaining verification: rebuild on the target Tiger iMac and confirm there is exactly one `PowerPlay` menu item next to the Apple logo, with the submenu attached to that same item.
- Verification on this host: the XIB XML parses cleanly and the Objective-C code compiles with exit code 0, with only legacy deprecation warnings.
