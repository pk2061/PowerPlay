Tiger AirPlay Receiver Project Layout

This folder contains the project metadata and Tiger-era Xcode compatibility notes for the app skeleton.

The actual source files are organized in the project root under logical folders:

- ../App/          application delegate, main entry point, Growl notifier
- ../Audio/        ALAC decoder and CoreAudio output layer
- ../Network/      RAOP/RTSP/RTP receiver logic
- ../Metadata/     metadata parser for track and artwork
- ../UI/           Cocoa UI and cover-art view
- ../Resources/    resource files and app assets
- ../Build/       build helper output and generated artifacts

Required build configuration:
- Base SDK: 10.4-compatible Mac OS X SDK
- Architecture: PowerPC + i386
- Languages: Objective-C/Cocoa
- Frameworks: Cocoa, CoreAudio, AudioToolbox
- Optional: Growl framework when AIRPLAY_GROWL_AVAILABLE is enabled

Core source files by area:
- App/AirPlayReceiverAppDelegate.m / .h
- App/GrowlNotifier.m / .h
- App/main.m
- Audio/ALACDecoder.m / .h
- Audio/CoreAudioPlayer.m / .h
- Network/RAOPReceiver.m / .h
- Metadata/AirPlayMetadataParser.m / .h
- UI/CoverArtView.m / .h

Notes:
- This is a compatibility-oriented project layout for older Xcode/GCC toolchains.
- It is not a complete finished app, but it provides the correct architectural separation for a Tiger-era AirPlay receiver implementation.
