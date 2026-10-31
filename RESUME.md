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
1. Rebuild on the target machine and verify the populated main menu appears
2. Verify app icon appearance on Tiger or a Tiger-compatible system
3. Validate with a real AirPlay sender trace
4. Confirm RTSP/RTP negotiation matches actual sender behavior
5. Verify ALAC decoding and audio timing against genuine sender payloads
6. Check remaining PowerPC / Tiger compatibility specifics on legacy hardware

## Build verification
Last successful syntax-only compile command:

clang -fno-objc-arc -fsyntax-only -I. -IApp -IAudio -INetwork -IMetadata -IUI -framework Cocoa -framework CoreAudio -framework AudioToolbox -DAIRPLAY_GROWL_AVAILABLE=0 App/AirPlayReceiverAppDelegate.m App/GrowlNotifier.m App/main.m Audio/ALACDecoder.m Audio/CoreAudioPlayer.m Metadata/AirPlayMetadataParser.m Network/RAOPReceiver.m UI/CoverArtView.m

Result: exit code 0; no syntax or parser errors. Only deprecation warnings from the modern SDK appeared.

Limitation: Xcode 2.5 and the Tiger SDK are not available in this environment. Xcode 27 is installed, but it cannot open this Xcode 2.5 project. The app has now been reported to launch on the target machine; the latest menu changes still need target-side verification.

## Runtime packaging status
`Project/MainMenu.xib` is the project-referenced source; a separate `Interface/MainMenu.xib` also exists and remains unchanged. Both `PowerPlay.xcodeproj` and the Xcode 2.5-compatible `PowerPlayApp.xcodeproj` now include `Project/MainMenu.nib` in the target Resources phase instead of copying the raw XIB. The user reports that the app now launches on the target machine.

The main menu source originally contained an empty PowerPlay submenu. It now contains About, Hide, Hide Others, Show All, and Quit actions. Xcode 27's `ibtool` successfully recompiled the XIB into the nib package (`keyedobjects.nib` and `keyedobjects-101300.nib`), and the compiled archive contains those menu labels. The app previously launched with an empty menu; rebuild with `PowerPlayApp.xcodeproj` and verify the menu appears. If it remains empty, inspect the rebuilt app's `Contents/Resources/MainMenu.nib` to confirm the new nib was copied. Runtime compatibility of this modern-compiled nib on Tiger is not fully verified.

The project files pass `plutil -lint`. Xcode 27's `xcodebuild` rejects the Xcode 2.5 project format, so this environment cannot perform a full target build.

## App icon status
`Resources/Images/PowerPlay.icns` was replaced with a classic RGB/mask ICNS containing 16, 32, 48, and 128 pixel variants and no embedded PNG chunks. The container and decoding were validated with `iconutil`, but actual display on Tiger remains unverified. The source image is `Resources/Images/PowerPlay_icon.png`.

The icon and its source were committed and pushed to `origin/main` as `f864dcc` (`Add Tiger-compatible PowerPlay app icon`).

## Resume summary
The source passes the recorded syntax-only compile. Commits `3a9f241` and `0f8f4cb` include the compiled nib and resource-phase wiring for both project files. `Project/MainMenu.xib` and the compiled nib package now contain the populated PowerPlay menu. Next, rebuild on the target machine and confirm the menu items appear. The new legacy-format icon is committed, pending on-device confirmation.
