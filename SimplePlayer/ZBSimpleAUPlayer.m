#import "ZBSimpleAUPlayer.h"

static void ZBAudioFileStreamPropertyListener(void * inClientData, AudioFileStreamID inAudioFileStream, AudioFileStreamPropertyID inPropertyID, UInt32 * ioFlags);
static void ZBAudioFileStreamPacketsCallback(void * inClientData, UInt32 inNumberBytes, UInt32 inNumberPackets, const void * inInputData, AudioStreamPacketDescription *inPacketDescriptions);

static OSStatus ZBPlayerConverterFiller (AudioConverterRef inAudioConverter, UInt32* ioNumberDataPackets, AudioBufferList* ioData, AudioStreamPacketDescription** outDataPacketDescription, void* inUserData);

//static
OSStatus ZBPlayerAURenderCallback(void *userData, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData);

void ZBAudioUnitPropertyListenerProc(void *inRefCon, AudioUnit ci, AudioUnitPropertyID inID, AudioUnitScope inScope, AudioUnitElement inElement);


typedef struct {
	size_t length;
	void *data;
} ZBPacketData;

AudioStreamBasicDescription LFPCMStreamDescription()
{
	AudioStreamBasicDescription destFormat;
	bzero(&destFormat, sizeof(AudioStreamBasicDescription));
	destFormat.mSampleRate = 44100.0;
	destFormat.mFormatID = kAudioFormatLinearPCM;
	destFormat.mFormatFlags = kLinearPCMFormatFlagIsBigEndian | kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
	destFormat.mFramesPerPacket = 1;
	destFormat.mBytesPerPacket = 4;
	destFormat.mBytesPerFrame = 4;
	destFormat.mChannelsPerFrame = 2;
	destFormat.mBitsPerChannel = 16;
	destFormat.mReserved = 0;

	return destFormat;
}

@implementation ZBSimpleAUPlayer
{
	NSURLConnection *URLConnection;
	struct {
		BOOL stopped;
		BOOL loaded;
	} playerStatus ;

	AudioFileStreamID audioFileStreamID;
	AudioConverterRef converter;
	AudioBufferList *list;
	size_t renderBufferSize;
	
	AUGraph audioGraph;
	AUNode outputNode;
	AudioUnit outputUnit;

	AudioStreamBasicDescription streamDescription;
	ZBPacketData *packetData;
	size_t packetCount;
	size_t maxPacketCount;
	size_t readHead;
}

- (void)dealloc
{
	AUGraphStop(audioGraph);
	AUGraphUninitialize(audioGraph);
	AUGraphClose(audioGraph);
	DisposeAUGraph(audioGraph);

	AudioConverterDispose(converter);
	AudioFileStreamClose(audioFileStreamID);

	for (size_t index = 0 ; index < packetCount ; index++) {
		void *data = packetData[index].data;
		if (data) {
			free(data);
			packetData[index].data = nil;
			packetData[index].length = 0;
		}
	}
	free(packetData);

	[URLConnection cancel];
	[URLConnection release];
	[super dealloc];
}

- (id)initWithURL:(NSURL *)inURL
{
	self = [super init];
	if (self) {
		playerStatus.stopped = YES;
		packetCount = 0;
		maxPacketCount = 10240;
		packetData = (ZBPacketData *)calloc(maxPacketCount, sizeof(ZBPacketData));

		UInt32 second = 5;
		UInt32 packetSize = 44100 * second * 8;
		renderBufferSize = packetSize;
		list = (AudioBufferList *)calloc(1, sizeof(UInt32) + sizeof(AudioBuffer));

		list->mNumberBuffers = 1;
		list->mBuffers[0].mNumberChannels = 2;
		list->mBuffers[0].mDataByteSize = packetSize;
		list->mBuffers[0].mData = calloc(1, packetSize);

		OSStatus status;
		status = NewAUGraph(&audioGraph);
		assert(noErr == status);

		AudioComponentDescription cdesc;
		bzero(&cdesc, sizeof(AudioComponentDescription));
		cdesc.componentType = kAudioUnitType_Output;
		cdesc.componentSubType = kAudioUnitSubType_DefaultOutput;
//		cdesc.componentSubType = kAudioUnitSubType_SystemOutput;
		cdesc.componentManufacturer = kAudioUnitManufacturer_Apple;
		cdesc.componentFlags = 0;
		cdesc.componentFlagsMask = 0;
		AUGraphAddNode(audioGraph, &cdesc, &outputNode);

		status = AUGraphOpen(audioGraph);
		assert(noErr == status);

		status = AUGraphNodeInfo(audioGraph, outputNode, &cdesc, &outputUnit);
		assert(noErr == status);

		AudioStreamBasicDescription destFormat = LFPCMStreamDescription();

		status = AudioUnitSetProperty(outputUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &destFormat, sizeof(destFormat));
		assert(noErr == status);

		AURenderCallbackStruct callbackStruct;
		callbackStruct.inputProc = ZBPlayerAURenderCallback;
		callbackStruct.inputProcRefCon = self;

		status = AudioUnitSetProperty(outputUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callbackStruct, sizeof(callbackStruct));
		assert(noErr == status);

		status = AudioUnitAddPropertyListener(outputUnit, kAudioOutputUnitProperty_IsRunning, ZBAudioUnitPropertyListenerProc, self);
		assert(noErr == status);

		status = AUGraphInitialize(audioGraph);
		assert(noErr == status);

		status = AudioUnitSetParameter(outputUnit, kHALOutputParam_Volume, kAudioUnitScope_Global, 0, 1.0, 0);
		assert(noErr == status);

		CAShow(audioGraph);

		AudioDeviceID defaultOutputDevice = 0;
		UInt32 adIDSize = sizeof(defaultOutputDevice);
		AudioObjectPropertyAddress outputDeviceAddress;
		outputDeviceAddress.mSelector = kAudioHardwarePropertyDefaultOutputDevice;
		status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &outputDeviceAddress, 0, NULL, &adIDSize, &defaultOutputDevice);
		assert(noErr == status);

#define MAX_FRAME_SIZE_ARRAY_COUNT 2
		UInt32 numFrames = 0;
		UInt32 dataSize = sizeof(numFrames);
		AudioObjectPropertyAddress bufferSizeAddress;
		bufferSizeAddress.mSelector = kAudioDevicePropertyBufferFrameSize;

		UInt32 maxFrameSizeArray[MAX_FRAME_SIZE_ARRAY_COUNT] = {2048, 1024};

		for (size_t i = 0 ; i < MAX_FRAME_SIZE_ARRAY_COUNT ; i++) {
			numFrames = maxFrameSizeArray[i];
			dataSize = sizeof(numFrames);

			status = AudioObjectSetPropertyData(defaultOutputDevice, &bufferSizeAddress, 0, NULL, dataSize, &numFrames);
			if (status == noErr) {
				break;
			}
		}
#undef MAX_FRAME_SIZE_ARRAY_COUNT


		// 第一步：建立 Audio Parser，指定 callback，以及建立 HTTP 連線，
		// 開始下載檔案
		AudioFileStreamOpen(self, ZBAudioFileStreamPropertyListener, ZBAudioFileStreamPacketsCallback, kAudioFileMP3Type, &audioFileStreamID);
		URLConnection = [[NSURLConnection alloc] initWithRequest:[NSURLRequest requestWithURL:inURL] delegate:self];
	}
	return self;
}

- (double)framePerSecond
{
	if (streamDescription.mFramesPerPacket) {
		return streamDescription.mSampleRate / streamDescription.mFramesPerPacket;
	}

	return 44100.0/1152.0;
}

#pragma mark -
#pragma mark NSURLConnectionDelegate

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
	if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
		if ([(NSHTTPURLResponse *)response statusCode] != 200) {
			NSLog(@"HTTP code:%ld", [(NSHTTPURLResponse *)response statusCode]);
			[connection cancel];
			playerStatus.stopped = YES;
		}
	}
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
	// 第二步：抓到了部分檔案，就交由 Audio Parser 開始 parse 出 data
	// stream 中的 packet。
	AudioFileStreamParseBytes(audioFileStreamID, (UInt32)[data length], [data bytes], 0);
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
	NSLog(@"Complete loading data");
	playerStatus.loaded = YES;
}
- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
	NSLog(@"Failed to load data: %@", [error localizedDescription]);
	playerStatus.stopped = YES;
}

- (OSStatus)_enqueueDataWithPacketsCount:(UInt32)inPacketCount ioData:(AudioBufferList  *)ioData
{
	OSStatus result = -1;
	@synchronized (self) {
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		UInt32 packetSize = inPacketCount;
		//	NSLog(@"inNumberFrames %lu", inNumberFrames);
		OSStatus status = AudioConverterFillComplexBuffer(converter, ZBPlayerConverterFiller, self, &packetSize, list, NULL);
		if (noErr != status || !packetSize) {
//			AudioUnitSetParameter(self->outputUnit, kHALOutputParam_Volume, kAudioUnitScope_Global, 0, 0.0, 0);
			playerStatus.stopped = YES;
			AUGraphStop(audioGraph);
			AudioConverterReset(self->converter);
			list->mNumberBuffers = 1;
			list->mBuffers[0].mNumberChannels = 2;
			list->mBuffers[0].mDataByteSize = renderBufferSize;
			bzero(list->mBuffers[0].mData, renderBufferSize);
			AudioUnitSetParameter(outputUnit, kHALOutputParam_Volume, kAudioUnitScope_Global, 0, 0.0, 0);
		}
		else if (!self->playerStatus.stopped) {
			ioData->mNumberBuffers = 1;
			ioData->mBuffers[0].mNumberChannels = 2;
			ioData->mBuffers[0].mDataByteSize = self->list->mBuffers[0].mDataByteSize;
			ioData->mBuffers[0].mData = self->list->mBuffers[0].mData;
			list->mBuffers[0].mDataByteSize = renderBufferSize;
			result = noErr;
		}
		[pool drain];
	}
	return result;
}

- (OSStatus)_fillConverterBufferWithBufferlist:(AudioBufferList *)ioData packetDescription:(AudioStreamPacketDescription** )outDataPacketDescription
{
	static AudioStreamPacketDescription aspdesc;

	ioData->mNumberBuffers = 1;
	void *data = packetData[readHead].data;
	UInt32 length = (UInt32)packetData[readHead].length;
	ioData->mBuffers[0].mData = data;
	ioData->mBuffers[0].mDataByteSize = length;

	*outDataPacketDescription = &aspdesc;
	aspdesc.mDataByteSize = length;
	aspdesc.mStartOffset = 0;
	aspdesc.mVariableFramesInPacket = 1;

	readHead++;
	return 0;
}

- (void)_createAudioConverterWithAudioStreamDescription:(AudioStreamBasicDescription *)audioStreamBasicDescription
{
	memcpy(&streamDescription, audioStreamBasicDescription, sizeof(AudioStreamBasicDescription));

	AudioStreamBasicDescription destFormat = LFPCMStreamDescription();
	AudioConverterNew(audioStreamBasicDescription, &destFormat, &converter);
}

- (void)_storePacketsWithNumberOfBytes:(UInt32)inNumberBytes numberOfPackets:(UInt32)inNumberPackets inputData:(const void *)inInputData packetDescriptions:(AudioStreamPacketDescription *)inPacketDescriptions
{
	for (int i = 0; i < inNumberPackets; ++i) {
		SInt64 packetStart = inPacketDescriptions[i].mStartOffset;
		UInt32 packetSize = inPacketDescriptions[i].mDataByteSize;
		assert(packetSize > 0);
		packetData[packetCount].length = (size_t)packetSize;
		packetData[packetCount].data = malloc(packetSize);
		memcpy(packetData[packetCount].data, inInputData + packetStart, packetSize);
		packetCount++;
	}

	if (readHead == 0 & packetCount > (int)([self framePerSecond] * 12)) {
		if (playerStatus.stopped) {
//			NSLog(@"start audio graph :%p", audioGraph);
			self->playerStatus.stopped = NO;
			AudioConverterReset(converter);
			OSStatus status = AUGraphStart(audioGraph);
			assert(noErr == status);
		}
//		[self _enqueueDataWithPacketsCount: (int)([self framePerSecond] * 10)];
	}
}


@end

void ZBAudioFileStreamPropertyListener(void * inClientData, AudioFileStreamID inAudioFileStream, AudioFileStreamPropertyID inPropertyID, UInt32 * ioFlags)
{
	ZBSimpleAUPlayer *self = (ZBSimpleAUPlayer *)inClientData;
	if (inPropertyID == kAudioFileStreamProperty_DataFormat) {
		UInt32 dataSize	 = 0;
		OSStatus status = 0;
		AudioStreamBasicDescription audioStreamDescription;
		Boolean writable = false;
		status = AudioFileStreamGetPropertyInfo(inAudioFileStream, kAudioFileStreamProperty_DataFormat, &dataSize, &writable);
		status = AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_DataFormat, &dataSize, &audioStreamDescription);

		NSLog(@"mSampleRate: %f", audioStreamDescription.mSampleRate);
		NSLog(@"mFormatID: %u", audioStreamDescription.mFormatID);
		NSLog(@"mFormatFlags: %u", audioStreamDescription.mFormatFlags);
		NSLog(@"mBytesPerPacket: %u", audioStreamDescription.mBytesPerPacket);
		NSLog(@"mFramesPerPacket: %u", audioStreamDescription.mFramesPerPacket);
		NSLog(@"mBytesPerFrame: %u", audioStreamDescription.mBytesPerFrame);
		NSLog(@"mChannelsPerFrame: %u", audioStreamDescription.mChannelsPerFrame);
		NSLog(@"mBitsPerChannel: %u", audioStreamDescription.mBitsPerChannel);
		NSLog(@"mReserved: %u", audioStreamDescription.mReserved);
		[self _createAudioConverterWithAudioStreamDescription:&audioStreamDescription];
	}
}

void ZBAudioFileStreamPacketsCallback(void * inClientData, UInt32 inNumberBytes, UInt32 inNumberPackets, const void * inInputData, AudioStreamPacketDescription *inPacketDescriptions)
{
//	NSLog(@"%s", __PRETTY_FUNCTION__);
	ZBSimpleAUPlayer *self = (ZBSimpleAUPlayer *)inClientData;
	[self _storePacketsWithNumberOfBytes:inNumberBytes numberOfPackets:inNumberPackets inputData:inInputData packetDescriptions:inPacketDescriptions];
}

OSStatus ZBPlayerConverterFiller (AudioConverterRef inAudioConverter, UInt32* ioNumberDataPackets, AudioBufferList* ioData, AudioStreamPacketDescription** outDataPacketDescription, void* inUserData)
{
//	NSLog(@"%s", __PRETTY_FUNCTION__);
	ZBSimpleAUPlayer *self = (ZBSimpleAUPlayer *)inUserData;
	*ioNumberDataPackets = 1;
	[self _fillConverterBufferWithBufferlist:ioData packetDescription:outDataPacketDescription];
	return noErr;
}


OSStatus ZBPlayerAURenderCallback(void *inUserData, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData)
{
//	NSLog(@"%s", __PRETTY_FUNCTION__);
	ZBSimpleAUPlayer *self = (ZBSimpleAUPlayer *)inUserData;
	return [self _enqueueDataWithPacketsCount:inNumberFrames ioData:ioData];
}

void ZBAudioUnitPropertyListenerProc(void *inRefCon, AudioUnit ci, AudioUnitPropertyID inID, AudioUnitScope inScope, AudioUnitElement inElement)
{
	ZBSimpleAUPlayer *self = (ZBSimpleAUPlayer *)inRefCon;
	UInt32 property = 0;
	UInt32 propertySize = sizeof(property);
	AudioUnitGetProperty(ci, kAudioOutputUnitProperty_IsRunning, inScope, inElement, &property, &propertySize);
	NSLog(@"%s %d", __PRETTY_FUNCTION__, property);
}
