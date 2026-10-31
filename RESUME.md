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
1. Verify app startup and icon appearance on Tiger or a Tiger-compatible system
2. Validate with a real AirPlay sender trace
3. Confirm RTSP/RTP negotiation matches actual sender behavior
4. Verify ALAC decoding and audio timing against genuine sender payloads
5. Check remaining PowerPC / Tiger compatibility specifics on legacy hardware

## Build verification
Last successful syntax-only compile command:

clang -fno-objc-arc -fsyntax-only -I. -IApp -IAudio -INetwork -IMetadata -IUI -framework Cocoa -framework CoreAudio -framework AudioToolbox -DAIRPLAY_GROWL_AVAILABLE=0 App/AirPlayReceiverAppDelegate.m App/GrowlNotifier.m App/main.m Audio/ALACDecoder.m Audio/CoreAudioPlayer.m Metadata/AirPlayMetadataParser.m Network/RAOPReceiver.m UI/CoverArtView.m

Result: exit code 0; no syntax or parser errors. Only deprecation warnings from the modern SDK appeared.

Limitation: Xcode 2.5 and the Tiger SDK are not available in this environment. Xcode 27 is installed, but it cannot open this Xcode 2.5 project, so a full build on the legacy toolchain is still unverified.

## Runtime packaging status
`Project/MainMenu.xib` is the project-referenced source; a separate `Interface/MainMenu.xib` also exists. Xcode 27's `ibtool` compiled the project source into `Project/MainMenu.nib`, and the target's Resources phase now includes the compiled nib instead of the raw XIB. The source declares macOS 10.4 deployment, but successful compilation does not prove runtime compatibility; startup still needs verification on Tiger.

The compiled nib is a package containing `keyedobjects.nib` and `keyedobjects-101300.nib`. `plutil -lint` accepts the project file, but Xcode 27's `xcodebuild` rejects its Xcode 2.5 project format. Do not rename the XIB to `.nib`; verify the resulting app bundle on Tiger using the legacy toolchain.

## App icon status
`Resources/Images/PowerPlay.icns` was replaced with a classic RGB/mask ICNS containing 16, 32, 48, and 128 pixel variants and no embedded PNG chunks. The container and decoding were validated with `iconutil`, but actual display on Tiger remains unverified. The source image is `Resources/Images/PowerPlay_icon.png`.

The icon and its source were committed and pushed to `origin/main` as `f864dcc` (`Add Tiger-compatible PowerPlay app icon`).

## Resume summary
The source passes the recorded syntax-only compile, and the compiled main nib is now included in the target's Resources phase. Xcode 2.5/Tiger build and runtime validation remain outstanding. The new legacy-format icon is committed, pending on-device confirmation.
