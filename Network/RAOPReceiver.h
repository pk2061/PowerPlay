#import <Cocoa/Cocoa.h>
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#import "ALACDecoder.h"
#import "AirPlayMetadataParser.h"
#import "CoreAudioPlayer.h"

@interface RAOPReceiver : NSObject <NSNetServiceBrowserDelegate, NSNetServiceDelegate> {
    NSNetServiceBrowser *serviceBrowser;
    NSMutableArray *discoveredServices;
    NSNetService *resolvedService;
    NSString *deviceName;
    NSString *currentTitle;
    NSData *coverArtData;
    BOOL isPlaying;
    float volume;
    NSString *rtspSessionId;
    NSString *hostAddress;
    NSInteger controlPort;
    NSInteger audioPort;
    NSInteger timingPort;
    int controlSocket;
    int audioSocket;
    int timingSocket;
    NSInteger nextCSeq;
    BOOL rtspSessionEstablished;
    BOOL rtpSessionReady;
    BOOL isSetupComplete;
    NSString *artistName;
    NSString *albumName;
    NSString *trackName;
    NSMutableDictionary *metadata;
    ALACDecoder *alacDecoder;
    AirPlayMetadataParser *metadataParser;
    CoreAudioPlayer *audioPlayer;
}

- (id)init;
- (void)startBrowsing;
- (void)stopBrowsing;
- (void)connectToService:(NSNetService *)service;
- (void)play;
- (void)pause;
- (void)nextTrack;
- (void)previousTrack;
- (void)setVolume:(float)newVolume;
- (void)beginRTSPSession;
- (BOOL)openUDPListenerOnPort:(NSInteger)port socket:(int *)socketHandle;
- (BOOL)parseTransportHeader:(NSString *)transportHeader;
- (void)sendRTSPCommand:(NSString *)method path:(NSString *)path headers:(NSDictionary *)headers body:(NSData *)body;
- (NSDictionary *)parseRTSPResponseData:(NSData *)responseData;
- (NSDictionary *)parseNegotiationTrace:(NSData *)traceData;
- (BOOL)validateRTSPTrace:(NSData *)traceData;
- (BOOL)validateRTPPacket:(NSData *)packet;
- (void)setupRTPStreams;
- (void)bindRTPTransportOnPort:(NSInteger)port socket:(int *)socketHandle;
- (void)readAudioPackets;
- (void)readTimingPackets;
- (void)handleRTPPacket:(NSData *)packet;
- (void)handleMetadataPacket:(NSData *)packet;
- (void)parseMetadataFromPlistData:(NSData *)plistData;
- (void)notifyTrackChangeIfNeeded;

- (NSString *)currentTitle;
- (NSString *)artistName;
- (NSString *)albumName;
- (NSString *)trackName;
- (float)volumeValue;
- (NSData *)coverArtData;
- (BOOL)isPlaying;
- (BOOL)isConnected;
- (BOOL)isSessionReady;
- (void)teardownSession;

@end
