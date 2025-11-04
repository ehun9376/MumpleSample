// Copyright 2009-2012 The MumbleKit Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#import <MumbleKit/MKAudio.h>
#import "MKUtils.h"
#import "MKAudioDevice.h"
#import "MKAudioInput.h"
#import "MKAudioOutput.h"
#import "MKAudioOutputSidetone.h"
#import <MumbleKit/MKConnection.h>

#if TARGET_OS_IPHONE == 1
# import "MKVoiceProcessingDevice.h"
# import "MKiOSAudioDevice.h"
#elif TARGET_OS_MAC == 1
# import "MKVoiceProcessingDevice.h"
# import "MKMacAudioDevice.h"
#endif

#import <AudioUnit/AudioUnit.h>
#import <AudioUnit/AUComponent.h>
#import <AudioToolbox/AudioToolbox.h>

#if TARGET_OS_IPHONE || TARGET_IPHONE_SIMULATOR
#import <UIKit/UIKit.h>
#endif

NSString *MKAudioDidRestartNotification = @"MKAudioDidRestartNotification";

@interface MKAudio () {
    id<MKAudioDelegate>      _delegate;
    MKAudioDevice            *_audioDevice;
    MKAudioInput             *_audioInput;
    MKAudioOutput            *_audioOutput;
    MKAudioOutputSidetone    *_sidetoneOutput;
    MKConnection             *_connection;
    MKAudioSettings          _audioSettings;
    BOOL                     _running;
}
- (BOOL) _audioShouldBeRunning;
@end

#if TARGET_OS_IPHONE == 1
static void MKAudio_InterruptCallback(void *udata, UInt32 interrupt) {
    MKAudio *audio = (MKAudio *) udata;

    if (interrupt == kAudioSessionBeginInterruption) {
        [audio stop];
    } else if (interrupt == kAudioSessionEndInterruption) {
        UInt32 val = TRUE;
        OSStatus err = AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers, sizeof(val), &val);
        if (err != kAudioSessionNoError) {
            NSLog(@"MKAudio: unable to set MixWithOthers property in InterruptCallback.");
        }

        if ([audio _audioShouldBeRunning]) {
            [audio start];
        }
    }
}

static void MKAudio_AudioInputAvailableCallback(MKAudio *audio, AudioSessionPropertyID prop, UInt32 len, uint32_t *avail) {
    BOOL audioInputAvailable;
    UInt32 val;
    OSStatus err;

    if (avail) {
        audioInputAvailable = *avail;
        val = audioInputAvailable ? kAudioSessionCategory_PlayAndRecord : kAudioSessionCategory_MediaPlayback;
        err = AudioSessionSetProperty(kAudioSessionProperty_AudioCategory, sizeof(val), &val);
        if (err != kAudioSessionNoError) {
            NSLog(@"MKAudio: unable to set AudioCategory property.");
            return;
        }

        if (val == kAudioSessionCategory_PlayAndRecord) {
            MKAudioSettings settings;
            [audio readAudioSettings:&settings];
            val = 1;
            if (settings.preferReceiverOverSpeaker) {
                val = 0;
            }
            err = AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryDefaultToSpeaker, sizeof(val), &val);
            if (err != kAudioSessionNoError) {
                NSLog(@"MKAudio: unable to set OverrideCategoryDefaultToSpeaker property.");
                return;
            }
        }
        
        UInt32 val = TRUE;
        OSStatus err = AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers, sizeof(val), &val);
        if (err != kAudioSessionNoError) {
            NSLog(@"MKAudio: unable to set MixWithOthers property in AudioInputAvailableCallback.");
        }

        if ([audio _audioShouldBeRunning]) {
            [audio restart];
        } else {
            [audio stop];
        }
    }
}

static void MKAudio_AudioRouteChangedCallback(MKAudio *audio, AudioSessionPropertyID prop, UInt32 len, NSDictionary *dict) {
    int reason = [[dict objectForKey:(id)kAudioSession_RouteChangeKey_Reason] intValue];
    switch (reason) {
        case kAudioSessionRouteChangeReason_Override:
        case kAudioSessionRouteChangeReason_CategoryChange:
        case kAudioSessionRouteChangeReason_NoSuitableRouteForCategory:
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 70000
        case kAudioSessionRouteChangeReason_RouteConfigurationChange:
#endif
            NSLog(@"MKAudio: audio route changed, skipping; reason=%i", reason);
            return;
    }

    UInt32 val = TRUE;
    OSStatus err = AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers, sizeof(val), &val);
    if (err != kAudioSessionNoError) {
        NSLog(@"MKAudio: unable to set MixWithOthers property in AudioRouteChangedCallback.");
    }
    
    if ([audio _audioShouldBeRunning]) {
        NSLog(@"MKAudio: audio route changed, restarting audio; reason=%i", reason);
        [audio restart];
    } else {
        NSLog(@"MKAudio: audio route changed, stopping audio (because delegate said so); reason=%i", reason);
        [audio stop];
    }
}

static void MKAudio_SetupAudioSession(MKAudio *audio) {
    // ⚠️ iOS 13+ 之後不再使用 AudioSession API，由外部 (AVAudioSession) 控制。
       NSLog(@"[MKAudio] Skipping legacy AudioSession initialization (using AVAudioSession).");
}

static void MKAudio_UpdateAudioSessionSettings(MKAudio *audio) {
    OSStatus err;
    UInt32 val, valSize;
    BOOL audioInputAvailable = YES;
    

    // To be able to select the correct category, we must query whethe audio input is available.
    valSize = sizeof(UInt32);
    err = AudioSessionGetProperty(kAudioSessionProperty_AudioInputAvailable, &valSize, &val);
    if (err != kAudioSessionNoError || valSize != sizeof(UInt32)) {
        NSLog(@"MKAudio: unable to query for input availability.");
        return;
    }
    audioInputAvailable = (BOOL) val;
    
    if (audioInputAvailable) {
        // The OverrideCategoryDefaultToSpeaker property makes us output to the speakers of the iOS device
        // as long as there's not a headset connected. However, if the user prefers the audio to be output
        // to the receiver, honor that.
        MKAudioSettings settings;
        [audio readAudioSettings:&settings];
        val = 1;
        if (settings.preferReceiverOverSpeaker) {
            val = 0;
        }
        err = AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryDefaultToSpeaker, sizeof(val), &val);
        if (err != kAudioSessionNoError) {
            NSLog(@"MKAudio: unable to set OverrideCategoryDefaultToSpeaker property.");
            return;
        }
    }
}
#else
static void MKAudio_SetupAudioSession(MKAudio *audio) {
    (void) audio;
}

static void MKAudio_UpdateAudioSessionSettings(MKAudio *audio) {
    (void) audio;
}
#endif

@implementation MKAudio

+ (MKAudio *) sharedAudio {
    static dispatch_once_t pred;
    static MKAudio *audio;

    dispatch_once(&pred, ^{
        audio = [[MKAudio alloc] init];
        MKAudio_SetupAudioSession(audio);
    });

    return audio;
}

- (void) setDelegate:(id<MKAudioDelegate>)delegate {
    @synchronized(self) {
        _delegate = delegate;
    }
}

- (id<MKAudioDelegate>) delegate {
    id<MKAudioDelegate> delegate;
    @synchronized(self) {
        delegate = _delegate;
    }
    return delegate;
}

// Read the current audio engine settings
- (void) readAudioSettings:(MKAudioSettings *)settings {
    if (settings == NULL)
        return;

    @synchronized(self) {
        memcpy(settings, &_audioSettings, sizeof(MKAudioSettings));
    }
}

// Set new settings for the audio engine
- (void) updateAudioSettings:(MKAudioSettings *)settings {
    @synchronized(self) {
        memcpy(&_audioSettings, settings, sizeof(MKAudioSettings));
    }
}

// Should audio be running?
- (BOOL) _audioShouldBeRunning {
    id<MKAudioDelegate> delegate;
    @synchronized(self) {
        delegate = _delegate;
    }
    // If a delegate is provided, we should call that.
    if ([(id)delegate respondsToSelector:@selector(audioShouldBeRunning:)]) {
        return [delegate audioShouldBeRunning:self];
    }
    
    // If no delegate is available, or the audioShouldBeRunning:
    // method is not implemented in the delegate, fall back to something
    // relatively sane.
#if TARGET_OS_IPHONE == 1
    return [[UIApplication sharedApplication] applicationState] == UIApplicationStateActive;
#else
    return YES;
#endif
}

// Has MKAudio been started?
- (BOOL) isRunning {
    return _running;
}

// Stop the audio engine
- (void) stop {
    @synchronized(self) {
        [_audioInput release];
        _audioInput = nil;
        [_audioOutput release];
        _audioOutput = nil;
        [_audioDevice teardownDevice];
        [_audioDevice release];
        _audioDevice = nil;
        [_sidetoneOutput release];
        _sidetoneOutput = nil;
        _running = NO;
    }
#if TARGET_OS_IPHONE == 1
//    AudioSessionSetActive(NO);
#endif
}

// Start the audio engine
- (void) start {
#if TARGET_OS_IPHONE == 1
    // 使用新版 AVAudioSession 控制，避免與舊 API 衝突。
    NSLog(@"[MKAudio] Using AVAudioSession externally; skipping AudioSessionSetActive(YES).");
#endif
    @synchronized(self) {
#if TARGET_OS_IPHONE == 1
        // 永遠使用 iOS AudioDevice，避免 VoiceProcessing 初始化失敗
        _audioDevice = [[MKiOSAudioDevice alloc] initWithSettings:&_audioSettings];
#elif TARGET_OS_MAC == 1
        _audioDevice = [[MKMacAudioDevice alloc] initWithSettings:&_audioSettings];
#else
# error Missing MKAudioDevice
#endif
        [_audioDevice setupDevice];
        _audioInput = [[MKAudioInput alloc] initWithDevice:_audioDevice andSettings:&_audioSettings];
        [_audioInput setMainConnectionForAudio:_connection];
        _audioOutput = [[MKAudioOutput alloc] initWithDevice:_audioDevice andSettings:&_audioSettings];
        if (_audioSettings.enableSideTone) {
            _sidetoneOutput = [[MKAudioOutputSidetone alloc] initWithSettings:&_audioSettings];
        }
        _running = YES;
    }
}


// Restart the audio engine
- (void) restart {
    [self stop];
    MKAudio_UpdateAudioSessionSettings(self);
    [self start];
    
    [[NSNotificationCenter defaultCenter] postNotificationName:MKAudioDidRestartNotification object:self];
}

- (void) setMainConnectionForAudio:(MKConnection *)conn {
    @synchronized(self) {
        [conn retain];
        [_audioInput setMainConnectionForAudio:conn];
        [_connection release];
        _connection = conn;
    }
}

- (void) addFrameToBufferWithSession:(NSUInteger)session data:(NSData *)data sequence:(NSUInteger)seq type:(MKUDPMessageType)msgType {
    @synchronized(self) {
        [_audioOutput addFrameToBufferWithSession:session data:data sequence:seq type:msgType];
    }
}

- (MKAudioOutputSidetone *) sidetoneOutput {
    return _sidetoneOutput;
}

- (MKTransmitType) transmitType {
    @synchronized(self) {
        return _audioSettings.transmitType;
    }
}

- (BOOL) forceTransmit {
    @synchronized(self) {
        return [_audioInput forceTransmit];
    }
}

- (void) setForceTransmit:(BOOL)flag {
    @synchronized(self) {
        [_audioInput setForceTransmit:flag];
    }
}

- (float) speechProbablity {
    @synchronized(self) {
        return [_audioInput speechProbability];
    }
}

- (float) peakCleanMic {
    @synchronized(self) {
        return [_audioInput peakCleanMic];
    }
}

- (void) setSelfMuted:(BOOL)selfMuted {
    @synchronized(self) {
        [_audioInput setSelfMuted:selfMuted];
    }
}

- (void) setSuppressed:(BOOL)suppressed {
    @synchronized(self) {
        [_audioInput setSuppressed:suppressed];
    }
}

- (void) setMuted:(BOOL)muted {
    @synchronized(self) {
        [_audioInput setMuted:muted];
    }
}

- (BOOL) echoCancellationAvailable {
#if TARGET_OS_IPHONE || TARGET_IPHONE_SIMULATOR
    NSDictionary *dict = nil;
    UInt32 valSize = sizeof(NSDictionary *);
    OSStatus err = AudioSessionGetProperty(kAudioSessionProperty_AudioRouteDescription, &valSize, &dict);
    if (err != kAudioSessionNoError) {
        return NO;
    }

    NSArray *inputs = [dict objectForKey:(id)kAudioSession_AudioRouteKey_Inputs];
    if ([inputs count] == 0) {
        return NO;
    }

    NSDictionary *input = [inputs objectAtIndex:0]; 
    NSString *inputKind = [input objectForKey:(id)kAudioSession_AudioRouteKey_Type];

    if ([inputKind isEqualToString:(NSString *)kAudioSessionInputRoute_BuiltInMic])
        return YES;
#endif
    return NO;
}

- (NSDictionary *) copyAudioOutputMixerDebugInfo {
    return [_audioOutput copyMixerInfo];
}

@end
