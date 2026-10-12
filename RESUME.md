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
1. Validate with a real AirPlay sender trace
2. Confirm RTSP/RTP negotiation matches actual sender behavior
3. Verify ALAC decoding against genuine sender payloads
4. Tune audio queue timing and latency under real packet flow
5. Check PowerPC / Tiger compatibility specifics on legacy hardware
6. Final Xcode packaging and project setup refinement

## Build verification
Last successful syntax-only compile command:

clang -fno-objc-arc -fsyntax-only -I. -IApp -IAudio -INetwork -IMetadata -IUI -framework Cocoa -framework CoreAudio -framework AudioToolbox -DAIRPLAY_GROWL_AVAILABLE=0 App/AirPlayReceiverAppDelegate.m App/GrowlNotifier.m App/main.m Audio/ALACDecoder.m Audio/CoreAudioPlayer.m Metadata/AirPlayMetadataParser.m Network/RAOPReceiver.m UI/CoverArtView.m

Result: exit code 0; no syntax or parser errors. Only deprecation warnings from the modern SDK appeared.

Limitation: Xcode 2.5 and the Tiger SDK are not available in this environment, so a real IDE build on the legacy toolchain is still unverified.

## Recommended next step
The most valuable next action is real sender capture validation: capture actual AirPlay RTP/RTSP/metadata traffic from a source device and compare it against the parsing rules in the receiver.

## Resume summary
Latest compatibility work replaced `NSUInteger` usages in `Audio/ALACDecoder.m` with legacy-safe `unsigned long` types and added an explicit Foundation import. The fix was committed and pushed to `origin/main` as `dcd8a5e` (`Fix legacy NSUInteger compatibility in ALAC decoder`). The worktree was clean when this handoff was prepared.

The receiver is structurally complete enough to continue as a real project. Next steps are to confirm a build with Xcode 2.5 on a Tiger SDK machine, then validate protocol correctness against real AirPlay traffic. Live sender behavior and genuine ALAC payload decoding remain unverified.
