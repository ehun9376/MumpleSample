// Copyright 2012 The MumbleKit Developers.
// Modified 2025 by Chen YiHuang & ChatGPT (GPT-5)
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#import <MumbleKit/MKAudio.h>
#import "MKAudioDevice.h"
#import "MKiOSAudioDevice.h"

#import <AudioUnit/AudioUnit.h>
#import <AudioUnit/AUComponent.h>
#import <AudioToolbox/AudioToolbox.h>

@interface MKiOSAudioDevice () {
@public
    MKAudioSettings              _settings;
    AudioUnit                    _audioUnit;

    // Input (mic)
    AudioBufferList              _buflist;
    int                          _micFrequency;
    int                          _micSampleSize;
    int                          _numMicChannels;

    // Output (speaker)
    int                          _outBytesPerFrame;
    int                          _outChannels;
    BOOL                         _isNonInterleaved;
    void                        *_outScratch;
    size_t                       _outScratchSize;   // 🔧 安全追蹤目前 scratch buffer 大小

    MKAudioDeviceOutputFunc      _outputFunc;
    MKAudioDeviceInputFunc       _inputFunc;
}
@end

#pragma mark - Input Callback

static OSStatus inputCallback(void *udata,
                              AudioUnitRenderActionFlags *flags,
                              const AudioTimeStamp *ts,
                              UInt32 busnum,
                              UInt32 nframes,
                              AudioBufferList * /* not used */) {
    MKiOSAudioDevice *dev = (MKiOSAudioDevice *)udata;
    OSStatus err;

    if (!dev->_buflist.mBuffers->mData) {
        dev->_buflist.mNumberBuffers = 1;
        AudioBuffer *b = dev->_buflist.mBuffers;
        b->mNumberChannels = dev->_numMicChannels;
        b->mDataByteSize = (UInt32)(dev->_micSampleSize * nframes);
        b->mData = calloc(1, b->mDataByteSize);
        NSLog(@"MKiOSAudioDevice: Allocated mic buffer (%u bytes)", (unsigned)b->mDataByteSize);
    } else {
        UInt32 need = (UInt32)(dev->_micSampleSize * nframes);
        AudioBuffer *b = dev->_buflist.mBuffers;
        if (b->mDataByteSize < need) {
            free(b->mData);
            b->mData = calloc(1, need);
            b->mDataByteSize = need;
        }
    }

    // Render from bus 1 (input)
    err = AudioUnitRender(dev->_audioUnit, flags, ts, 1, nframes, &dev->_buflist);
    if (err != noErr) {
        NSLog(@"⚠️ MKiOSAudioDevice: AudioUnitRender failed (%d)", (int)err);
        return err;
    }

    if (dev->_inputFunc) {
        short *pcm = (short *)dev->_buflist.mBuffers->mData;
        dev->_inputFunc(pcm, nframes);
    }
    
    static uint32_t s_inCount = 0;
    if ((++s_inCount % 50) == 0) {
        short *pcm = (short *)dev->_buflist.mBuffers->mData;
        // 看個簡單能量（絕對值最大值）
        short peak = 0;
        for (UInt32 i = 0; i < nframes; i++) {
            short v = pcm[i];
            short a = (v >= 0) ? v : -v;
            if (a > peak) peak = a;
        }
    }
    
    return noErr;
}

#pragma mark - Output Callback

static OSStatus outputCallback(void *udata,
                               AudioUnitRenderActionFlags * /* flags */,
                               const AudioTimeStamp * /* ts */,
                               UInt32 busnum,
                               UInt32 nframes,
                               AudioBufferList *buflist) {
    MKiOSAudioDevice *dev = (MKiOSAudioDevice *)udata;

    if (buflist->mNumberBuffers > 1 && dev->_isNonInterleaved) {
        // 非交錯 (例如雙聲道 Float32)
        int bytesPerSample = dev->_outBytesPerFrame / dev->_outChannels;
        UInt32 needBytes = nframes * bytesPerSample;

        if (!dev->_outScratch || dev->_outScratchSize < needBytes) {
            if (dev->_outScratch) free(dev->_outScratch);
            dev->_outScratch = calloc(1, needBytes);
            dev->_outScratchSize = needBytes;
        }
        memset(dev->_outScratch, 0, needBytes);

        if (dev->_outputFunc) {
            dev->_outputFunc(dev->_outScratch, nframes);
        }

        // 複製 mono → 左右聲道
        for (UInt32 i = 0; i < buflist->mNumberBuffers; i++) {
            AudioBuffer *b = &buflist->mBuffers[i];
            if (!b->mData || b->mDataByteSize < needBytes) {
                b->mData = realloc(b->mData, needBytes);
            }
            memcpy(b->mData, dev->_outScratch, needBytes);
            b->mDataByteSize = needBytes;
        }
        return noErr;
    }

    // 交錯或單聲道模式
    AudioBuffer *buf = buflist->mBuffers;
    UInt32 needBytes = (UInt32)(nframes * dev->_outBytesPerFrame);

    if (!dev->_outScratch || dev->_outScratchSize < needBytes) {
        if (dev->_outScratch) free(dev->_outScratch);
        dev->_outScratch = calloc(1, needBytes);
        dev->_outScratchSize = needBytes;
    }

    memset(dev->_outScratch, 0, needBytes);
    buf->mData = dev->_outScratch;
    buf->mDataByteSize = needBytes;

    if (dev->_outputFunc) {
        dev->_outputFunc(buf->mData, nframes);
    }

    return noErr;
}

#pragma mark - Implementation

@implementation MKiOSAudioDevice

- (id)initWithSettings:(MKAudioSettings *)settings {
    if ((self = [super init])) {
        memcpy(&_settings, settings, sizeof(MKAudioSettings));
        memset(&_buflist, 0, sizeof(_buflist));
        _buflist.mNumberBuffers = 1;
        _outScratch = NULL;
        _outScratchSize = 0;
    }
    return self;
}

- (void)dealloc {
    [_inputFunc release];
    [_outputFunc release];
    if (_outScratch) {
        free(_outScratch);
        _outScratch = NULL;
        _outScratchSize = 0;
    }
    [super dealloc];
}

- (BOOL)setupDevice {
    OSStatus err;
    UInt32 val;
    AudioComponent comp;
    AudioComponentDescription desc = {0};

    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_RemoteIO;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;

    comp = AudioComponentFindNext(NULL, &desc);
    if (!comp) {
        NSLog(@"❌ MKiOSAudioDevice: Unable to find RemoteIO");
        return NO;
    }

    err = AudioComponentInstanceNew(comp, &_audioUnit);
    if (err != noErr) {
        NSLog(@"❌ MKiOSAudioDevice: Instance creation failed (%d)", (int)err);
        return NO;
    }

    // 啟用 I/O
    val = 1;
    AudioUnitSetProperty(_audioUnit, kAudioOutputUnitProperty_EnableIO,
                         kAudioUnitScope_Input, 1, &val, sizeof(val)); // mic in
    AudioUnitSetProperty(_audioUnit, kAudioOutputUnitProperty_EnableIO,
                         kAudioUnitScope_Output, 0, &val, sizeof(val)); // speaker out

    // 綁定 callbacks
    AURenderCallbackStruct inCb = {inputCallback, self};
    AudioUnitSetProperty(_audioUnit, kAudioOutputUnitProperty_SetInputCallback,
                         kAudioUnitScope_Global, 1, &inCb, sizeof(inCb));

    AURenderCallbackStruct outCb = {outputCallback, self};
    AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_SetRenderCallback,
                         kAudioUnitScope_Input, 0, &outCb, sizeof(outCb));

    // ===== Input format: 16-bit PCM, mono, 48k =====
    _micFrequency = 48000;
    _numMicChannels = 1;
    _micSampleSize = sizeof(int16_t) * _numMicChannels;

    AudioStreamBasicDescription fmt = {0};
    fmt.mSampleRate = _micFrequency;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    fmt.mBitsPerChannel = 16;
    fmt.mChannelsPerFrame = _numMicChannels;
    fmt.mFramesPerPacket = 1;
    fmt.mBytesPerFrame = _micSampleSize;
    fmt.mBytesPerPacket = _micSampleSize;

    AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_StreamFormat,
                         kAudioUnitScope_Output, 1, &fmt, sizeof(fmt)); // input bus (mic)

    // 嘗試設成相同格式的輸出（單 buffer）
    err = AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_StreamFormat,
                               kAudioUnitScope_Input, 0, &fmt, sizeof(fmt));
    _isNonInterleaved = NO;

    // 若裝置拒絕單 buffer，改用裝置本身格式
    if (err != noErr) {
        AudioStreamBasicDescription outFmt = {0};
        UInt32 outLen = sizeof(outFmt);
        AudioUnitGetProperty(_audioUnit, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Input, 0, &outFmt, &outLen);

        _outChannels = (int)outFmt.mChannelsPerFrame;
        _isNonInterleaved = (outFmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
        int bytesPerSample = (outFmt.mFormatFlags & kAudioFormatFlagIsFloat) ? sizeof(Float32) : sizeof(int16_t);
        _outBytesPerFrame = bytesPerSample * _outChannels;
    } else {
        _outChannels = 1;
        _outBytesPerFrame = sizeof(int16_t);
    }

    // 初始化
    err = AudioUnitInitialize(_audioUnit);
    if (err != noErr) {
        NSLog(@"❌ MKiOSAudioDevice: Initialize failed (%d)", (int)err);
        return NO;
    }

    NSLog(@"✅ MKiOSAudioDevice: AudioUnit initialized successfully (nonInterleaved=%@)",
          _isNonInterleaved ? @"YES" : @"NO");

    err = AudioOutputUnitStart(_audioUnit);
    if (err != noErr) {
        NSLog(@"❌ MKiOSAudioDevice: Start failed (%d)", (int)err);
        return NO;
    }

    return YES;
}

- (BOOL)teardownDevice {
    AudioOutputUnitStop(_audioUnit);
    AudioComponentInstanceDispose(_audioUnit);

    AudioBuffer *b = _buflist.mBuffers;
    if (b && b->mData) {
        free(b->mData);
        b->mData = NULL;
    }

    if (_outScratch) {
        free(_outScratch);
        _outScratch = NULL;
        _outScratchSize = 0;
    }

    NSLog(@"MKiOSAudioDevice: teardown finished.");
    return YES;
}

- (void)setupOutput:(MKAudioDeviceOutputFunc)outf {
    _outputFunc = [outf copy];
}

- (void)setupInput:(MKAudioDeviceInputFunc)inf {
    _inputFunc = [inf copy];
}

- (int)inputSampleRate { return _micFrequency; }
- (int)outputSampleRate { return _micFrequency; }
- (int)numberOfInputChannels { return _numMicChannels; }
- (int)numberOfOutputChannels { return _outChannels; }

@end
