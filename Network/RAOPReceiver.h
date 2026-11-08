#import <Foundation/Foundation.h>
#import <Foundation/NSNetServices.h>

#if defined(__OBJC__)
@class NSNetService;
@protocol NSNetServiceDelegate;
#endif

#ifndef NSINTEGER_DEFINED
typedef long NSInteger;
#define NSINTEGER_DEFINED 1
#endif

#ifndef NSUINTEGER_DEFINED
typedef unsigned long NSUInteger;
#define NSUINTEGER_DEFINED 1
#endif

#import <CoreServices/CoreServices.h>
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#import "ALACDecoder.h"
#import "AirPlayMetadataParser.h"
#import "CoreAudioPlayer.h"

extern NSString * const PowerPlayMetadataDidChangeNotification;
extern NSString * const PowerPlayVolumeDidChangeNotification;
extern NSString * const PowerPlayPlaybackProgressDidChangeNotification;

@interface RAOPReceiver : NSObject <NSNetServiceDelegate> {
    NSNetService *publishedService;
    NSNetService *resolvedService;
    NSString *deviceIdentifier;
    int listenerSocket;
    int rtpControlSocket;
    volatile BOOL acceptingRTSP;
    NSString *deviceName;
    NSString *connectedDeviceName;
    NSString *currentTitle;
    NSData *coverArtData;
    BOOL isPlaying;
    BOOL incomingSessionActive;
    float volume;
    double elapsedPlaybackTime;
    double trackDuration;
    double progressReferenceTime;
    double lastAudioPacketTime;
    double progressResumeOffset;
    uint32_t lastProgressStartTimestamp;
    uint32_t lastProgressCurrentTimestamp;
    BOOL hasProgressTimestamp;
    BOOL resumeProgressPending;
    BOOL progressIsRelative;
    NSString *rtspSessionId;
    NSString *hostAddress;
    NSInteger controlPort;
    NSInteger audioPort;
    NSInteger timingPort;
    NSInteger rtpControlPort;
    NSInteger senderTimingPort;
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
    NSData *audioAESKey;
    NSData *audioAESIV;
    ALACDecoder *alacDecoder;
    AirPlayMetadataParser *metadataParser;
    CoreAudioPlayer *audioPlayer;
}

- (id)init;
- (void)startReceiver;
- (void)stopReceiver;
- (void)acceptRTSPConnections;
- (void)handleRTSPConnection:(int)incomingSocket;
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
- (void)receiveAudioPackets;
- (void)receiveControlPackets;
- (void)receiveTimingPackets;
- (void)bindRTPTransportOnPort:(NSInteger)port socket:(int *)socketHandle;
- (void)readAudioPackets;
- (void)readTimingPackets;
- (void)handleRTPPacket:(NSData *)packet;
- (void)handleMetadataPacket:(NSData *)packet;
- (void)parseMetadataFromPlistData:(NSData *)plistData;
- (void)applyParsedMetadata:(NSDictionary *)parsedMetadata;
- (void)notifyMetadataDidChange;
- (void)notifyTrackChangeIfNeeded;

- (NSString *)currentTitle;
- (NSString *)connectedDeviceName;
- (NSString *)artistName;
- (NSString *)albumName;
- (NSString *)trackName;
- (float)volumeValue;
- (double)elapsedPlaybackTimeValue;
- (double)trackDurationValue;
- (NSData *)coverArtData;
- (BOOL)isPlaying;
- (BOOL)isConnected;
- (BOOL)isSessionReady;
- (void)teardownSession;

@end
