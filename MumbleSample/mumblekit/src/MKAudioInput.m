// Copyright 2005-2012 The MumbleKit Developers.
// Modified 2025-10-22 for stable Opus + SpeexPreprocess pipeline.
// Use of this source code is governed by a BSD-style license.

#import <MumbleKit/MKServerModel.h>
#import <MumbleKit/MKVersion.h>
#import <MumbleKit/MKConnection.h>
#import "MKPacketDataStream.h"
#import "MKAudioInput.h"
#import "MKAudioOutputSidetone.h"
#import "MKAudioDevice.h"

#include <speex/speex.h>
#include <speex/speex_preprocess.h>
#include <speex/speex_echo.h>
#include <speex/speex_resampler.h>
#include <speex/speex_jitter.h>
#include <speex/speex_types.h>
#include <opus.h>
#import <AVFoundation/AVFoundation.h>


#ifndef SAMPLE_RATE
#define SAMPLE_RATE 48000
#endif

@interface MKAudioInput () {
@public
    int                    micSampleSize;
    int                    numMicChannels;

@private
    MKAudioDevice          *_device;
    MKAudioSettings        _settings;

    SpeexPreprocessState   *_preprocessorState;
    SpeexResamplerState    *_micResampler;
    SpeexBits              _speexBits;
    void                   *_speexEncoder; // unused (kept for compatibility)
    OpusEncoder            *_opusEncoder;

    int                    frameSize;     // samples per 10ms
    int                    micFrequency;  // device input Hz
    int                    sampleRate;    // internal pipeline Hz

    int                    micFilled;
    int                    micLength;
    int                    bitrate;
    int                    frameCounter;
    int                    _bufferedFrames;

    BOOL                   doResetPreprocessor;

    short                  *psMic;
    short                  *psOut;

    MKUDPMessageType       udpMessageType;
    NSMutableArray         *frameList;

    MKCodecFormat          _codecFormat;
    BOOL                   _doTransmit;
    BOOL                   _forceTransmit;
    BOOL                   _lastTransmit;

    signed long            _preprocRunningAvg;
    signed long            _preprocAvgItems;

    float                  _speechProbability;
    float                  _peakCleanMic;

    BOOL                   _selfMuted;
    BOOL                   _muted;
    BOOL                   _suppressed;

    BOOL                   _vadGateEnabled;
    double                 _vadGateTimeSeconds;
    double                 _vadOpenLastTime;

    NSMutableData          *_encodingOutputBuffer;
    NSMutableData          *_opusBuffer;

    MKConnection           *_connection;
}
@end

@implementation MKAudioInput

#pragma mark - Lifecycle

- (id) initWithDevice:(MKAudioDevice *)device andSettings:(MKAudioSettings *)settings {
    self = [super init];
    if (!self) return nil;
    
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *sessionError = nil;
    
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayAndRecord
                                     withOptions:AVAudioSessionCategoryOptionDefaultToSpeaker |
                                                 AVAudioSessionCategoryOptionAllowBluetoothA2DP |
                                                 AVAudioSessionCategoryOptionAllowBluetooth |
                                                 AVAudioSessionCategoryOptionMixWithOthers
                                           error:nil];
    [[AVAudioSession sharedInstance] setMode:AVAudioSessionModeVoiceChat error:nil];

    _device = [device retain];
    memcpy(&_settings, settings, sizeof(MKAudioSettings));

    // ✅ 強制使用 Opus + 立即送封包 + 開前處理（降噪/AGC）
    _settings.codec              = MKCodecFormatOpus;
    _settings.enablePreprocessor = YES;
    _settings.transmitType       = MKTransmitTypeVAD;
    _settings.audioPerPacket     = 1;
    _settings.quality            = 48000; // target bitrate (CBR)

    _preprocessorState = NULL;
    _micResampler      = NULL;
    _speexEncoder      = NULL;
    _opusEncoder       = NULL;
    frameCounter       = 0;
    _bufferedFrames    = 0;

    _vadGateEnabled    = NO;
    _forceTransmit     = NO;
    _doTransmit        = NO;
    _lastTransmit      = NO;
    doResetPreprocessor= YES;

    // 🔧 內部採樣率 48k / 10ms
    sampleRate = SAMPLE_RATE;
    frameSize  = SAMPLE_RATE / 100;

    int oerr = 0;
    _opusEncoder = opus_encoder_create(sampleRate, 1, OPUS_APPLICATION_VOIP, &oerr);
    if (oerr != OPUS_OK || !_opusEncoder) {
        NSLog(@"❌ Opus encoder init failed: %d", oerr);
        [self release];
        return nil;
    }
    opus_encoder_ctl(_opusEncoder, OPUS_SET_VBR(0));                 // 固定碼率 CBR
    opus_encoder_ctl(_opusEncoder, OPUS_SET_BITRATE(_settings.quality));
    opus_encoder_ctl(_opusEncoder, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));
    opus_encoder_ctl(_opusEncoder, OPUS_SET_COMPLEXITY(5));
    opus_encoder_ctl(_opusEncoder, OPUS_SET_GAIN(0));
    opus_encoder_ctl(_opusEncoder, OPUS_SET_DTX(1));                 // 靜音時節流
    opus_encoder_ctl(_opusEncoder, OPUS_SET_VBR_CONSTRAINT(1));  // 穩定碼率
    opus_encoder_ctl(_opusEncoder, OPUS_SET_INBAND_FEC(1));      // 前向錯誤修復（FEC）

    NSLog(@"🎤 MKAudioInput: Opus ready %d Hz, frame=%d, bitrate=%d",
          sampleRate, frameSize, _settings.quality);

    frameList = [[NSMutableArray alloc] initWithCapacity:_settings.audioPerPacket];
    udpMessageType = UDPVoiceOpusMessage;

    micFrequency   = [_device inputSampleRate];
    numMicChannels = [_device numberOfInputChannels];

    [self initializeMixer];

    __block typeof(self) weakSelf = self;
    [_device setupInput:^BOOL(short *frames, unsigned int nsamp) {
        [weakSelf addMicrophoneDataWithBuffer:frames amount:nsamp];
        return YES;
    }];



    return self;
}

- (void) dealloc {
    [_device setupInput:NULL];

    if (psMic) { free(psMic); psMic = NULL; }
    if (psOut) { free(psOut); psOut = NULL; }

    if (_speexEncoder) { speex_encoder_destroy(_speexEncoder); _speexEncoder = NULL; }
    if (_micResampler) { speex_resampler_destroy(_micResampler); _micResampler = NULL; }
    if (_preprocessorState) { speex_preprocess_state_destroy(_preprocessorState); _preprocessorState = NULL; }
    if (_opusEncoder) { opus_encoder_destroy(_opusEncoder); _opusEncoder = NULL; }

    [frameList release]; frameList = nil;
    [_opusBuffer release]; _opusBuffer = nil;
    [_encodingOutputBuffer release]; _encodingOutputBuffer = nil;

    [_device release]; _device = nil;

    [super dealloc];
}

#pragma mark - Public

- (void) setMainConnectionForAudio:(MKConnection *)conn {
    @synchronized (self) {
        _connection = conn;
        NSLog(@"[MKAudioInput] setMainConnectionForAudio: conn=%p", conn);
    }
}

- (void) setForceTransmit:(BOOL)flag { _forceTransmit = flag; }
- (BOOL)  forceTransmit { return _forceTransmit; }

- (long)  preprocessorAvgRuntime { return _preprocRunningAvg; }
- (float) speechProbability { return _speechProbability; }
- (float) peakCleanMic { return _peakCleanMic; }

- (void) setSelfMuted:(BOOL)selfMuted { _selfMuted = selfMuted; }
- (void) setSuppressed:(BOOL)suppressed { _suppressed = suppressed; }
- (void) setMuted:(BOOL)muted { _muted = muted; }

#pragma mark - Mixer / IO

- (void) initializeMixer {
    NSLog(@"MKAudioInput: initializeMixer -- iMicFreq=%u, iSampleRate=%u", micFrequency, sampleRate);

    micLength = (frameSize * micFrequency) / sampleRate;

    if (_micResampler) { speex_resampler_destroy(_micResampler); _micResampler = NULL; }
    if (psMic) { free(psMic); psMic = NULL; }
    if (psOut) { free(psOut); psOut = NULL; }

    // 僅在裝置採樣率與內部採樣率不同時啟用 resampler
    if (micFrequency != sampleRate) {
        int rerr = 0;
        _micResampler = speex_resampler_init(1, micFrequency, sampleRate, 3, &rerr);
        NSLog(@"MKAudioInput: initialized resampler (%iHz -> %iHz), err=%d", micFrequency, sampleRate, rerr);
    }

    psMic = (short *)malloc(micLength * sizeof(short));
    psOut = (short *)malloc(frameSize * sizeof(short));
    micSampleSize = numMicChannels * sizeof(short);
    doResetPreprocessor = YES;

    NSLog(@"MKAudioInput: Initialized mixer for %i ch %i Hz (echo 0ch 0Hz)", numMicChannels, micFrequency);
}

- (void) addMicrophoneDataWithBuffer:(short *)input amount:(NSUInteger)nsamp {
    while (nsamp > 0) {
        NSUInteger left = MIN(nsamp, (NSUInteger)(micLength - micFilled));
        short *output = psMic + micFilled;

        // copy mono (already nonInterleaved=NO in device)
        for (NSUInteger i = 0; i < left; i++) output[i] = input[i];

        input     += left;
        micFilled += (int)left;
        nsamp     -= left;

        if (micFilled == micLength) {
            if (_micResampler) {
                spx_uint32_t inlen = (spx_uint32_t)micLength;
                spx_uint32_t outlen = (spx_uint32_t)frameSize;
                speex_resampler_process_int(_micResampler, 0, psMic, &inlen, psOut, &outlen);
            } else {
                // 同採樣率下直接搬運
                memcpy(psOut, psMic, frameSize * sizeof(short));
            }
            micFilled = 0;
            [self processAndEncodeAudioFrame];
        }
    }
}

#pragma mark - Side tone (optional)

- (void) processSidetone {
    if (micFrequency == 48000) {
        NSData *data = [[NSData alloc] initWithBytes:psMic length:micLength*sizeof(short)];
        [[[MKAudio sharedAudio] sidetoneOutput] addFrame:data];
        [data release];
    }
}

#pragma mark - Preprocessor

- (void) resetPreprocessor {
    _preprocAvgItems = 0;
    _preprocRunningAvg = 0;

    if (_preprocessorState) {
        speex_preprocess_state_destroy(_preprocessorState);
        _preprocessorState = NULL;
    }

    _preprocessorState = speex_preprocess_state_init(frameSize, sampleRate);
    if (!_preprocessorState) {
        NSLog(@"❌ speex_preprocess_state_init failed");
        return;
    }

    int on = 1;
    int off = 0;

    speex_preprocess_ctl(_preprocessorState, SPEEX_PREPROCESS_SET_DENOISE, &on);
    speex_preprocess_ctl(_preprocessorState, SPEEX_PREPROCESS_SET_AGC, &on);
    speex_preprocess_ctl(_preprocessorState, SPEEX_PREPROCESS_SET_DEREVERB, &on);
    speex_preprocess_ctl(_preprocessorState, SPEEX_PREPROCESS_SET_VAD, &on);
    speex_preprocess_ctl(_preprocessorState, SPEEX_PREPROCESS_SET_AGC, &off);


    // 🧩 調強降噪
    int noiseSuppress = -50; // 原為 -40，越小越強
    speex_preprocess_ctl(_preprocessorState, SPEEX_PREPROCESS_SET_NOISE_SUPPRESS, &noiseSuppress);

    // 🧩 降低 AGC 強度
    int agcLevel = 24000; // 原 30000，避免爆音
    speex_preprocess_ctl(_preprocessorState, SPEEX_PREPROCESS_SET_AGC_TARGET, &agcLevel);

    // 🧩 提高 VAD 靈敏度
    int probStart = 98;
    int probContinue = 95;
    speex_preprocess_ctl(_preprocessorState, SPEEX_PREPROCESS_SET_PROB_START, &probStart);
    speex_preprocess_ctl(_preprocessorState, SPEEX_PREPROCESS_SET_PROB_CONTINUE, &probContinue);

    // 🧩 關閉 Dereverb（iPhone 麥克風空間反射小）
    speex_preprocess_ctl(_preprocessorState, SPEEX_PREPROCESS_SET_DEREVERB, &off);

    NSLog(@"✅ Speex preprocessor tuned: noise=%d, agc=%d, probStart=%d/%d",
          noiseSuppress, agcLevel, probStart, probContinue);
}


#pragma mark - Encode path

- (int) encodeAudioFrameOfSpeech:(BOOL)isSpeech intoBuffer:(unsigned char *)encbuf ofSize:(NSUInteger)max  {
    if (max < 1500) return -1; // 預留足夠空間

    BOOL resampled = (micFrequency != sampleRate);

    // 使用 Opus 路徑
    udpMessageType = UDPVoiceOpusMessage;
    if (_opusBuffer == nil) _opusBuffer = [[NSMutableData alloc] init];

    _bufferedFrames++;
    [_opusBuffer appendBytes:(resampled ? psOut : psMic) length:frameSize*sizeof(short)];

    // 立即送出（audioPerPacket=1）
    if (_bufferedFrames < _settings.audioPerPacket) return -1;

    if (!_lastTransmit) opus_encoder_ctl(_opusEncoder, OPUS_RESET_STATE, NULL);
    opus_encoder_ctl(_opusEncoder, OPUS_SET_BITRATE(_settings.quality));

    int len = opus_encode(_opusEncoder,
                          (short *)[_opusBuffer bytes],
                          (opus_int32)(_bufferedFrames * frameSize),
                          encbuf,
                          (opus_int32)max);

    [_opusBuffer setLength:0];
    if (len <= 0) {
        bitrate = 0;
        return -1;
    }
    bitrate = (len * 100 * 8) / _bufferedFrames;
    return len;
}

- (void) processAndEncodeAudioFrame {
    frameCounter++;

    if (doResetPreprocessor) {
        [self resetPreprocessor];
        doResetPreprocessor = NO;
    }

    BOOL resampled = (micFrequency != sampleRate);
    short *frame = resampled ? psOut : psMic;

    // -------- 1) 先全域衰減 + 簡易軟式限幅，避免爆音/失真 --------
    for (int i = 0; i < frameSize; i++) {
        float s = (float)frame[i];

        // 軟式限幅：超過 ~30000 以比例壓回，避免硬剪裁破音
        if (s > 30000.0f) {
            s = 30000.0f + (s - 30000.0f) * 0.2f;
        } else if (s < -30000.0f) {
            s = -30000.0f + (s + 30000.0f) * 0.2f;
        }
        frame[i] = (short)lrintf(s);
    }

    // -------- 2) Speex 前處理（只跑一次）；同時拿到 isSpeech --------
    int isSpeech = 1;
    if (_settings.enablePreprocessor && _preprocessorState) {
        isSpeech = speex_preprocess_run(_preprocessorState, frame); // 1=有語音, 0=非語音
    }

    // -------- 3) 監控音量（RMS / dB）--------
    float sum = 1.0f;
    for (int i = 0; i < frameSize; i++) {
        float v = (float)frame[i];
        sum += v * v;
    }
    float micLevel = sqrtf(sum / frameSize);
    float peakSignal = 20.0f * log10f(micLevel / 32768.0f);
    if (peakSignal < -96.0f) peakSignal = -96.0f;

    spx_int32_t prob = 0;
    if (_preprocessorState) speex_preprocess_ctl(_preprocessorState, SPEEX_PREPROCESS_GET_PROB, &prob);
    _speechProbability = prob / 100.0f;

    int agcGain = 0;
    if (_preprocessorState) speex_preprocess_ctl(_preprocessorState, SPEEX_PREPROCESS_GET_AGC_GAIN, &agcGain);
    _peakCleanMic = peakSignal - (float)agcGain;
    if (_peakCleanMic < -96.0f) _peakCleanMic = -96.0f;

    // -------- 4) Noise gate：超低音量一律視為背景直接靜音（抹掉沙沙聲）--------
    // 門檻可調：400~800 之間；值越大越嚴格
    const float kNoiseGateRMS = 500.0f;
    if (isSpeech == 0 && micLevel < kNoiseGateRMS) {
        memset(frame, 0, frameSize * sizeof(short));
    }

    // -------- 5) 由 VAD 控制傳輸，再加「尾音保留」(hangover/gate) --------
    // 預設 gate 0.4 秒，避免句尾被吃掉；若尚未初始化，就設一個合理值
    if (_vadGateTimeSeconds <= 0.0) {
        _vadGateTimeSeconds = 0.40;
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();

    _doTransmit = (isSpeech == 1);

    if (_doTransmit) {
        _vadOpenLastTime = now; // 有語音：更新最後開啟時間
    } else {
        // 無語音：在 gate 期間內仍維持傳送，確保尾音不被截斷
        if ((now - _vadOpenLastTime) < _vadGateTimeSeconds) {
            _doTransmit = YES;
        }
    }

    // 靜音/抑制狀態下一律不送
    if (_selfMuted || _muted || _suppressed) {
        _doTransmit = NO;
    }

    // 側音：僅在發送中（或剛結束）才播放
    if (_settings.enableSideTone && (_doTransmit || _lastTransmit)) {
        [self processSidetone];
    }

    // 完全不需要發送就退出（避免無謂編碼）
    if (!_doTransmit && !_lastTransmit) {
        _lastTransmit = _doTransmit;
        return;
    }

    // -------- 6) 編碼並送出 --------
    if (_encodingOutputBuffer == nil) {
        _encodingOutputBuffer = [[NSMutableData alloc] initWithLength:1500];
    }

    int len = [self encodeAudioFrameOfSpeech:_doTransmit
                                  intoBuffer:[_encodingOutputBuffer mutableBytes]
                                     ofSize:[_encodingOutputBuffer length]];
    if (len >= 0) {
        NSData *outputBuffer = [[NSData alloc] initWithBytes:[_encodingOutputBuffer bytes] length:len];
        [self flushCheck:outputBuffer terminator:!_doTransmit]; // 若關閉傳送，帶 terminator
        [outputBuffer release];

        if ((frameCounter % 10) == 0) {
         
        }
    }

    _lastTransmit = _doTransmit;
}


- (void) flushCheck:(NSData *)codedSpeech terminator:(BOOL)terminator {
    if (!codedSpeech) return;
    [frameList addObject:codedSpeech];

    if (!terminator && _bufferedFrames < _settings.audioPerPacket) return;

    int flags = 0;
    flags |= (udpMessageType << 5);

    unsigned char data[2048];
    data[0] = (unsigned char)(flags & 0xff);

    int frames = _bufferedFrames;
    _bufferedFrames = 0;

    MKPacketDataStream *pds = [[MKPacketDataStream alloc] initWithBuffer:(data+1) length:2047];
    [pds addVarint:(frameCounter - frames)];

    if (udpMessageType == UDPVoiceOpusMessage) {
        NSData *frame = [frameList objectAtIndex:0];
        uint64_t header = [frame length];
        if (terminator) header |= (1ULL << 13); // Opus terminator flag
        [pds addVarint:header];
        [pds appendBytes:(unsigned char *)[frame bytes] length:[frame length]];
    } else {
        // 目前不走 Speex/CELT
        for (NSData *frame in frameList) {
            unsigned char head = (unsigned char)[frame length];
            [pds appendValue:head];
            [pds appendBytes:(unsigned char *)[frame bytes] length:[frame length]];
        }
    }

    [frameList removeAllObjects];

    NSUInteger len = [pds size] + 1;
    NSData *msgData = [[NSData alloc] initWithBytes:data length:len];
    [pds release];

    @synchronized (self) {
        if (_connection) {
            [_connection sendVoiceData:msgData];
        } else {
            NSLog(@"⚠️ No connection bound. Drop voice packet.");
        }
    }

    [msgData release];
}

#pragma mark - Debug helper

- (void) encodeAudioFrame {
    NSLog(@"[MKAudioInput] encodeAudioFrame: conn=%p forceTx=%d selfMuted=%d",
          _connection, _forceTransmit, _selfMuted);
    NSLog(@"[MKAudioInput] encoding audio frame");
}

@end
