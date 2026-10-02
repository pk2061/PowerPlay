#!/bin/zsh

# Minimal build helper for local syntax validation and Tiger-oriented project layout.
# This is a placeholder for a real Xcode project build on an older Tiger toolchain.

cd "$(dirname "$0")/.."
clang -fsyntax-only -x objective-c -fno-objc-arc \
    -framework Cocoa \
    -I. -IApp -IAudio -INetwork -IMetadata -IUI \
    -DAIRPLAY_GROWL_AVAILABLE=0 \
    Audio/ALACDecoder.m Metadata/AirPlayMetadataParser.m Audio/CoreAudioPlayer.m \
    Network/RAOPReceiver.m App/AirPlayReceiverAppDelegate.m UI/CoverArtView.m \
    App/GrowlNotifier.m App/main.m

printf "\nSyntax check completed.\n"
