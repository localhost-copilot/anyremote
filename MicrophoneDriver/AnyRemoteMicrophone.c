// AnyRemote Microphone: a Core Audio server plug-in that gives this Mac a
// microphone whose sound comes from another Mac.
//
// It publishes two devices that share one clock and one ring buffer:
//
//   - "AnyRemote Microphone", an input-only device that apps record from;
//   - "AnyRemote Microphone Feed", a hidden output-only device that AnyRemote
//     plays the viewer's microphone into.
//
// Both devices count samples from the same anchor host time, so a sample the
// feed writes for sample time T is the sample the microphone reads for T.
// The feed writes ahead of the clock and the microphone reads behind it, so
// the sound passes through with only the two devices' I/O buffers as delay.
// Frames the feed hasn't written (it isn't running, or fell behind) read as
// silence, never as stale sound.
//
// Apps record from it like any microphone, with the usual Microphone
// permission. (A Core Audio process tap exposed as an aggregate device would
// need no driver, but coreaudiod then requires every recording app to hold
// the System Audio Recording permission, which ordinary apps never ask for.)

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <string.h>

// MARK: - Constants

enum {
    kObjectPlugIn = kAudioObjectPlugInObject,
    kObjectMicrophone = 2,
    kObjectMicrophoneStream = 3,
    kObjectFeed = 4,
    kObjectFeedStream = 5,
};

#define kSampleRate 48000.0
#define kChannels 1
#define kBytesPerFrame (sizeof(Float32) * kChannels)
#define kZeroTimeStampPeriod 16384
// A power of two, and several times any I/O buffer, so neither side can lap
// the other.
#define kRingFrames 65536

#define kManufacturer CFSTR("AnyRemote")
#define kMicrophoneName CFSTR("AnyRemote Microphone")
#define kMicrophoneUID CFSTR("com.localhost-copilot.anyremote.microphone")
#define kFeedName CFSTR("AnyRemote Microphone Feed")
#define kFeedUID CFSTR("com.localhost-copilot.anyremote.microphone.feed")
#define kModelUID CFSTR("com.localhost-copilot.anyremote.microphone.model")

// MARK: - State

static AudioServerPlugInHostRef gHost = NULL;
static _Atomic UInt32 gRefCount = 0;

static UInt64 gAnchorHostTime = 0;
static Float64 gHostTicksPerFrame = 0;

static _Atomic UInt32 gMicrophoneIOCount = 0;
static _Atomic UInt32 gFeedIOCount = 0;

static Float32 gRing[kRingFrames * kChannels];
// The written sample-time range [gWriteStart, gWriteEnd): what the feed has
// written in its current unbroken run.
static _Atomic Float64 gWriteStart = 0;
static _Atomic Float64 gWriteEnd = 0;

// MARK: - Helpers

static bool IsDevice(AudioObjectID object) {
    return object == kObjectMicrophone || object == kObjectFeed;
}

static bool IsStream(AudioObjectID object) {
    return object == kObjectMicrophoneStream || object == kObjectFeedStream;
}

static AudioObjectID StreamOfDevice(AudioObjectID device) {
    return device == kObjectMicrophone ? kObjectMicrophoneStream : kObjectFeedStream;
}

static AudioObjectID DeviceOfStream(AudioObjectID stream) {
    return stream == kObjectMicrophoneStream ? kObjectMicrophone : kObjectFeed;
}

/// Whether `device` has a stream in `scope`: the microphone only for input,
/// the feed only for output.
static bool DeviceHasScope(AudioObjectID device, AudioObjectPropertyScope scope) {
    if (scope == kAudioObjectPropertyScopeGlobal) return true;
    if (device == kObjectMicrophone) return scope == kAudioObjectPropertyScopeInput;
    return scope == kAudioObjectPropertyScopeOutput;
}

static AudioStreamBasicDescription Format(void) {
    AudioStreamBasicDescription format = {0};
    format.mSampleRate = kSampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    format.mBytesPerPacket = kBytesPerFrame;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = kBytesPerFrame;
    format.mChannelsPerFrame = kChannels;
    format.mBitsPerChannel = 32;
    return format;
}

/// Writes `size` bytes of `value` to `outData` if it has room, and always
/// reports the size: so one routine answers both GetPropertyDataSize (with
/// `outData` NULL) and GetPropertyData.
#define ANSWER(type, value)                                                                 \
    do {                                                                                    \
        if (outData != NULL) {                                                              \
            if (inDataSize < sizeof(type)) return kAudioHardwareBadPropertySizeError;      \
            *(type *)outData = (value);                                                     \
        }                                                                                   \
        *outDataSize = sizeof(type);                                                        \
        return noErr;                                                                       \
    } while (0)

/// Answers with a list of object IDs, truncated to the room given.
static OSStatus AnswerIDs(const AudioObjectID *ids, UInt32 count, UInt32 inDataSize, UInt32 *outDataSize,
                          void *outData) {
    UInt32 room = outData != NULL ? inDataSize / sizeof(AudioObjectID) : count;
    UInt32 n = count < room ? count : room;
    if (outData != NULL && n > 0) memcpy(outData, ids, n * sizeof(AudioObjectID));
    *outDataSize = n * sizeof(AudioObjectID);
    return noErr;
}

static void NotifyRunning(AudioObjectID device) {
    if (gHost == NULL) return;
    AudioObjectPropertyAddress address = {kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal,
                                          kAudioObjectPropertyElementMain};
    // Property notifications must not be sent from inside the HAL's call.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        gHost->PropertiesChanged(gHost, device, 1, &address);
    });
}

// MARK: - Properties

static OSStatus Property(AudioObjectID object, pid_t client, const AudioObjectPropertyAddress *address,
                         UInt32 qualifierSize, const void *qualifier, UInt32 inDataSize, UInt32 *outDataSize,
                         void *outData);

static OSStatus PlugInProperty(const AudioObjectPropertyAddress *address, UInt32 qualifierSize,
                               const void *qualifier, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    static const AudioObjectID devices[] = {kObjectMicrophone, kObjectFeed};
    switch (address->mSelector) {
    case kAudioObjectPropertyBaseClass: ANSWER(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: ANSWER(AudioClassID, kAudioPlugInClassID);
    case kAudioObjectPropertyOwner: ANSWER(AudioObjectID, kAudioObjectUnknown);
    case kAudioObjectPropertyManufacturer: ANSWER(CFStringRef, (CFStringRef)CFRetain(kManufacturer));
    case kAudioObjectPropertyOwnedObjects:
    case kAudioPlugInPropertyDeviceList: return AnswerIDs(devices, 2, inDataSize, outDataSize, outData);
    case kAudioPlugInPropertyTranslateUIDToDevice: {
        AudioObjectID found = kAudioObjectUnknown;
        if (qualifierSize >= sizeof(CFStringRef) && qualifier != NULL) {
            CFStringRef uid = *(const CFStringRef *)qualifier;
            if (uid != NULL && CFEqual(uid, kMicrophoneUID)) found = kObjectMicrophone;
            if (uid != NULL && CFEqual(uid, kFeedUID)) found = kObjectFeed;
        }
        ANSWER(AudioObjectID, found);
    }
    case kAudioPlugInPropertyResourceBundle: ANSWER(CFStringRef, (CFStringRef)CFRetain(CFSTR("")));
    default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus DeviceProperty(AudioObjectID device, const AudioObjectPropertyAddress *address, UInt32 inDataSize,
                               UInt32 *outDataSize, void *outData) {
    bool microphone = device == kObjectMicrophone;
    bool inScope = DeviceHasScope(device, address->mScope);
    AudioObjectID stream = StreamOfDevice(device);
    switch (address->mSelector) {
    case kAudioObjectPropertyBaseClass: ANSWER(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: ANSWER(AudioClassID, kAudioDeviceClassID);
    case kAudioObjectPropertyOwner: ANSWER(AudioObjectID, kObjectPlugIn);
    case kAudioObjectPropertyName:
        ANSWER(CFStringRef, (CFStringRef)CFRetain(microphone ? kMicrophoneName : kFeedName));
    case kAudioObjectPropertyManufacturer: ANSWER(CFStringRef, (CFStringRef)CFRetain(kManufacturer));
    case kAudioObjectPropertyOwnedObjects:
        return AnswerIDs(&stream, inScope ? 1 : 0, inDataSize, outDataSize, outData);
    case kAudioObjectPropertyControlList: return AnswerIDs(NULL, 0, inDataSize, outDataSize, outData);
    case kAudioDevicePropertyDeviceUID:
        ANSWER(CFStringRef, (CFStringRef)CFRetain(microphone ? kMicrophoneUID : kFeedUID));
    case kAudioDevicePropertyModelUID: ANSWER(CFStringRef, (CFStringRef)CFRetain(kModelUID));
    case kAudioDevicePropertyTransportType: ANSWER(UInt32, kAudioDeviceTransportTypeVirtual);
    case kAudioDevicePropertyRelatedDevices: return AnswerIDs(&device, 1, inDataSize, outDataSize, outData);
    case kAudioDevicePropertyClockDomain: ANSWER(UInt32, 0);
    case kAudioDevicePropertyDeviceIsAlive: ANSWER(UInt32, 1);
    case kAudioDevicePropertyDeviceIsRunning:
        ANSWER(UInt32, atomic_load(microphone ? &gMicrophoneIOCount : &gFeedIOCount) > 0 ? 1 : 0);
    case kAudioDevicePropertyDeviceCanBeDefaultDevice: ANSWER(UInt32, microphone && inScope ? 1 : 0);
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: ANSWER(UInt32, 0);
    case kAudioDevicePropertyLatency: ANSWER(UInt32, 0);
    case kAudioDevicePropertySafetyOffset: ANSWER(UInt32, 0);
    case kAudioDevicePropertyStreams:
        return AnswerIDs(&stream, inScope ? 1 : 0, inDataSize, outDataSize, outData);
    case kAudioDevicePropertyNominalSampleRate: ANSWER(Float64, kSampleRate);
    case kAudioDevicePropertyAvailableNominalSampleRates: {
        AudioValueRange range = {kSampleRate, kSampleRate};
        ANSWER(AudioValueRange, range);
    }
    case kAudioDevicePropertyIsHidden: ANSWER(UInt32, microphone ? 0 : 1);
    case kAudioDevicePropertyZeroTimeStampPeriod: ANSWER(UInt32, kZeroTimeStampPeriod);
    case kAudioDevicePropertyPreferredChannelsForStereo: {
        if (outData != NULL) {
            if (inDataSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            ((UInt32 *)outData)[0] = 1;
            ((UInt32 *)outData)[1] = 1;
        }
        *outDataSize = 2 * sizeof(UInt32);
        return noErr;
    }
    case kAudioDevicePropertyPreferredChannelLayout: {
        AudioChannelLayout layout = {0};
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
        layout.mNumberChannelDescriptions = 1;
        layout.mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Mono;
        ANSWER(AudioChannelLayout, layout);
    }
    default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus StreamProperty(AudioObjectID stream, const AudioObjectPropertyAddress *address, UInt32 inDataSize,
                               UInt32 *outDataSize, void *outData) {
    bool microphone = stream == kObjectMicrophoneStream;
    switch (address->mSelector) {
    case kAudioObjectPropertyBaseClass: ANSWER(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: ANSWER(AudioClassID, kAudioStreamClassID);
    case kAudioObjectPropertyOwner: ANSWER(AudioObjectID, DeviceOfStream(stream));
    case kAudioObjectPropertyOwnedObjects: return AnswerIDs(NULL, 0, inDataSize, outDataSize, outData);
    case kAudioStreamPropertyIsActive: ANSWER(UInt32, 1);
    case kAudioStreamPropertyDirection: ANSWER(UInt32, microphone ? 1 : 0);
    case kAudioStreamPropertyTerminalType:
        ANSWER(UInt32, microphone ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeLine);
    case kAudioStreamPropertyStartingChannel: ANSWER(UInt32, 1);
    case kAudioStreamPropertyLatency: ANSWER(UInt32, 0);
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat: ANSWER(AudioStreamBasicDescription, Format());
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats: {
        AudioStreamRangedDescription ranged = {Format(), {kSampleRate, kSampleRate}};
        ANSWER(AudioStreamRangedDescription, ranged);
    }
    default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus Property(AudioObjectID object, pid_t client, const AudioObjectPropertyAddress *address,
                         UInt32 qualifierSize, const void *qualifier, UInt32 inDataSize, UInt32 *outDataSize,
                         void *outData) {
    (void)client;
    if (address == NULL || outDataSize == NULL) return kAudioHardwareIllegalOperationError;
    if (object == kObjectPlugIn)
        return PlugInProperty(address, qualifierSize, qualifier, inDataSize, outDataSize, outData);
    if (IsDevice(object)) return DeviceProperty(object, address, inDataSize, outDataSize, outData);
    if (IsStream(object)) return StreamProperty(object, address, inDataSize, outDataSize, outData);
    return kAudioHardwareBadObjectError;
}

// MARK: - Driver interface

static HRESULT QueryInterface(void *driver, REFIID uuid, LPVOID *outInterface);
static ULONG AddRef(void *driver);
static ULONG Release(void *driver);

static OSStatus Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host) {
    (void)driver;
    gHost = host;
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    Float64 ticksPerSecond = 1e9 * (Float64)timebase.denom / (Float64)timebase.numer;
    gHostTicksPerFrame = ticksPerSecond / kSampleRate;
    gAnchorHostTime = mach_absolute_time();
    return noErr;
}

static OSStatus CreateDevice(AudioServerPlugInDriverRef driver, CFDictionaryRef description,
                             const AudioServerPlugInClientInfo *client, AudioObjectID *outDevice) {
    (void)driver; (void)description; (void)client; (void)outDevice;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus DestroyDevice(AudioServerPlugInDriverRef driver, AudioObjectID device) {
    (void)driver; (void)device;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus AddDeviceClient(AudioServerPlugInDriverRef driver, AudioObjectID device,
                                const AudioServerPlugInClientInfo *client) {
    (void)driver; (void)device; (void)client;
    return noErr;
}

static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef driver, AudioObjectID device,
                                   const AudioServerPlugInClientInfo *client) {
    (void)driver; (void)device; (void)client;
    return noErr;
}

static OSStatus PerformConfigurationChange(AudioServerPlugInDriverRef driver, AudioObjectID device,
                                           UInt64 action, void *info) {
    (void)driver; (void)device; (void)action; (void)info;
    return noErr;
}

static OSStatus AbortConfigurationChange(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt64 action,
                                         void *info) {
    (void)driver; (void)device; (void)action; (void)info;
    return noErr;
}

static Boolean HasProperty(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t client,
                           const AudioObjectPropertyAddress *address) {
    (void)driver;
    UInt32 size = 0;
    // Asking for the size alone answers whether the property exists. The
    // UID translation needs no qualifier for that.
    return Property(object, client, address, 0, NULL, 0, &size, NULL) == noErr;
}

static OSStatus IsPropertySettable(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t client,
                                   const AudioObjectPropertyAddress *address, Boolean *outSettable) {
    if (!HasProperty(driver, object, client, address)) return kAudioHardwareUnknownPropertyError;
    *outSettable = false;
    return noErr;
}

static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t client,
                                    const AudioObjectPropertyAddress *address, UInt32 qualifierSize,
                                    const void *qualifier, UInt32 *outDataSize) {
    (void)driver;
    return Property(object, client, address, qualifierSize, qualifier, 0, outDataSize, NULL);
}

static OSStatus GetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t client,
                                const AudioObjectPropertyAddress *address, UInt32 qualifierSize,
                                const void *qualifier, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    (void)driver;
    if (outData == NULL) return kAudioHardwareIllegalOperationError;
    return Property(object, client, address, qualifierSize, qualifier, inDataSize, outDataSize, outData);
}

static OSStatus SetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t client,
                                const AudioObjectPropertyAddress *address, UInt32 qualifierSize,
                                const void *qualifier, UInt32 inDataSize, const void *inData) {
    (void)driver; (void)object; (void)client; (void)address; (void)qualifierSize; (void)qualifier;
    (void)inDataSize; (void)inData;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus StartIO(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client) {
    (void)driver; (void)client;
    if (!IsDevice(device)) return kAudioHardwareBadObjectError;
    if (atomic_fetch_add(device == kObjectMicrophone ? &gMicrophoneIOCount : &gFeedIOCount, 1) == 0)
        NotifyRunning(device);
    return noErr;
}

static OSStatus StopIO(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client) {
    (void)driver; (void)client;
    if (!IsDevice(device)) return kAudioHardwareBadObjectError;
    _Atomic UInt32 *count = device == kObjectMicrophone ? &gMicrophoneIOCount : &gFeedIOCount;
    UInt32 old = atomic_load(count);
    while (old > 0 && !atomic_compare_exchange_weak(count, &old, old - 1)) {}
    if (old == 1) NotifyRunning(device);
    return noErr;
}

/// Both devices run on one clock: whole periods since the anchor.
static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client,
                                 Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    (void)driver; (void)device; (void)client;
    Float64 ticksPerPeriod = gHostTicksPerFrame * kZeroTimeStampPeriod;
    UInt64 periods = (UInt64)((Float64)(mach_absolute_time() - gAnchorHostTime) / ticksPerPeriod);
    *outSampleTime = (Float64)periods * kZeroTimeStampPeriod;
    *outHostTime = gAnchorHostTime + (UInt64)((Float64)periods * ticksPerPeriod);
    *outSeed = 1;
    return noErr;
}

static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client,
                                  UInt32 operation, Boolean *outWillDo, Boolean *outWillDoInPlace) {
    (void)driver; (void)client;
    bool will = (device == kObjectMicrophone && operation == kAudioServerPlugInIOOperationReadInput)
        || (device == kObjectFeed && operation == kAudioServerPlugInIOOperationWriteMix);
    if (outWillDo != NULL) *outWillDo = will;
    if (outWillDoInPlace != NULL) *outWillDoInPlace = true;
    return noErr;
}

static OSStatus BeginIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client,
                                 UInt32 operation, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle) {
    (void)driver; (void)device; (void)client; (void)operation; (void)frames; (void)cycle;
    return noErr;
}

static void WriteFeed(const Float32 *samples, UInt32 frames, Float64 sampleTime) {
    Float64 end = atomic_load(&gWriteEnd);
    // A gap, or a jump back after the feed restarted: begin a new run, so
    // nothing from the old one is read as part of it.
    if (sampleTime > end || sampleTime + frames <= end - kRingFrames || sampleTime < atomic_load(&gWriteStart))
        atomic_store(&gWriteStart, sampleTime);
    UInt64 start = (UInt64)sampleTime;
    for (UInt32 i = 0; i < frames; i++) {
        UInt64 slot = (start + i) & (kRingFrames - 1);
        memcpy(&gRing[slot * kChannels], &samples[i * kChannels], kBytesPerFrame);
    }
    atomic_store(&gWriteEnd, sampleTime + frames);
}

static void ReadMicrophone(Float32 *samples, UInt32 frames, Float64 sampleTime) {
    Float64 start = atomic_load(&gWriteStart);
    Float64 end = atomic_load(&gWriteEnd);
    Float64 oldest = end - kRingFrames > start ? end - kRingFrames : start;
    UInt64 first = (UInt64)sampleTime;
    for (UInt32 i = 0; i < frames; i++) {
        Float64 time = sampleTime + i;
        if (time >= oldest && time < end) {
            UInt64 slot = (first + i) & (kRingFrames - 1);
            memcpy(&samples[i * kChannels], &gRing[slot * kChannels], kBytesPerFrame);
        } else {
            memset(&samples[i * kChannels], 0, kBytesPerFrame);
        }
    }
}

static OSStatus DoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID device, AudioObjectID stream,
                              UInt32 client, UInt32 operation, UInt32 frames,
                              const AudioServerPlugInIOCycleInfo *cycle, void *mainBuffer, void *secondaryBuffer) {
    (void)driver; (void)stream; (void)client; (void)secondaryBuffer;
    if (mainBuffer == NULL || cycle == NULL) return noErr;
    if (device == kObjectFeed && operation == kAudioServerPlugInIOOperationWriteMix)
        WriteFeed((const Float32 *)mainBuffer, frames, cycle->mOutputTime.mSampleTime);
    else if (device == kObjectMicrophone && operation == kAudioServerPlugInIOOperationReadInput)
        ReadMicrophone((Float32 *)mainBuffer, frames, cycle->mInputTime.mSampleTime);
    return noErr;
}

static OSStatus EndIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client,
                               UInt32 operation, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle) {
    (void)driver; (void)device; (void)client; (void)operation; (void)frames; (void)cycle;
    return noErr;
}

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    QueryInterface,
    AddRef,
    Release,
    Initialize,
    CreateDevice,
    DestroyDevice,
    AddDeviceClient,
    RemoveDeviceClient,
    PerformConfigurationChange,
    AbortConfigurationChange,
    HasProperty,
    IsPropertySettable,
    GetPropertyDataSize,
    GetPropertyData,
    SetPropertyData,
    StartIO,
    StopIO,
    GetZeroTimeStamp,
    WillDoIOOperation,
    BeginIOOperation,
    DoIOOperation,
    EndIOOperation,
};
static AudioServerPlugInDriverInterface *gInterfacePointer = &gInterface;
static AudioServerPlugInDriverRef gDriver = &gInterfacePointer;

static HRESULT QueryInterface(void *driver, REFIID uuid, LPVOID *outInterface) {
    if (driver != gDriver || outInterface == NULL) return kAudioHardwareBadObjectError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, uuid);
    bool known = CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(requested);
    if (!known) return E_NOINTERFACE;
    atomic_fetch_add(&gRefCount, 1);
    *outInterface = gDriver;
    return S_OK;
}

static ULONG AddRef(void *driver) {
    if (driver != gDriver) return 0;
    return atomic_fetch_add(&gRefCount, 1) + 1;
}

static ULONG Release(void *driver) {
    if (driver != gDriver) return 0;
    UInt32 old = atomic_load(&gRefCount);
    while (old > 0 && !atomic_compare_exchange_weak(&gRefCount, &old, old - 1)) {}
    return old > 0 ? old - 1 : 0;
}

/// The factory named in Info.plist's CFPlugInFactories.
void *AnyRemoteMicrophoneFactory(CFAllocatorRef allocator, CFUUIDRef requestedType) {
    (void)allocator;
    if (!CFEqual(requestedType, kAudioServerPlugInTypeUUID)) return NULL;
    return gDriver;
}
