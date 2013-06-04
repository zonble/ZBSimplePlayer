#import "ZBSimpleALPlayer.h"

static void ZBAudioFileStreamPropertyListener(void * inClientData, AudioFileStreamID inAudioFileStream, AudioFileStreamPropertyID inPropertyID, UInt32 * ioFlags);
static void ZBAudioFileStreamPacketsCallback(void * inClientData, UInt32 inNumberBytes, UInt32 inNumberPackets, const void * inInputData, AudioStreamPacketDescription *inPacketDescriptions);
static OSStatus ZBPlayerConverterFiller (AudioConverterRef inAudioConverter, UInt32* ioNumberDataPackets, AudioBufferList* ioData, AudioStreamPacketDescription** outDataPacketDescription, void* inUserData);

typedef struct {
	size_t length;
	void *data;
} ZBPacketData;

@implementation ZBSimpleALPlayer
{
	NSURLConnection *URLConnection;
	struct {
		BOOL stopped;
		BOOL loaded;
	} playerStatus ;

	AudioFileStreamID audioFileStreamID;
	AudioConverterRef converter;
	ALCcontext* mContext;
	ALCdevice* mDevice;

	ALuint sourceID;
	ALuint lastBufferID;

	AudioStreamBasicDescription streamDescription;
	ZBPacketData *packetData;
	size_t packetCount;
	size_t maxPacketCount;
	size_t readHead;
}

- (void)dealloc
{
	alcDestroyContext(mContext);
	alcCloseDevice(mDevice);
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
		playerStatus.stopped = NO;
		packetCount = 0;
		maxPacketCount = 10240;
		packetData = (ZBPacketData *)calloc(maxPacketCount, sizeof(ZBPacketData));

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
	[self _enqueueDataWithPacketsCount:packetCount];
}
- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
	NSLog(@"Failed to load data: %@", [error localizedDescription]);
	playerStatus.stopped = YES;
}

#pragma mark -
#pragma mark Audio Parser and Audio Queue callbacks

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

//- (void)enqueue
//{
//	[self _enqueueDataWithPacketsCount:(int)([self framePerSecond] * 10)];
//}

- (void)_enqueueDataWithPacketsCount:(size_t)inPacketCount
{
	NSLog(@"%s", __PRETTY_FUNCTION__);

	if (!mDevice) {
		return;
	}
	if (!mContext) {
		return;
	}

	if (readHead >= packetCount) {
		if (playerStatus.loaded) {
			playerStatus.stopped = YES;
			return;
		}
	}


	CGFloat second = ((CGFloat)inPacketCount / [self framePerSecond]);;
	UInt32 packetSize = 44100 * second * 4;
	NSLog(@"%d", packetSize);

	AudioBufferList *list = (AudioBufferList *)calloc(1, sizeof(UInt32) + sizeof(AudioBuffer));

	list->mNumberBuffers = 1;
	list->mBuffers[0].mNumberChannels = 0;
	list->mBuffers[0].mDataByteSize = packetSize;
	list->mBuffers[0].mData = calloc(1, packetSize);

	OSStatus status;
	status = AudioConverterFillComplexBuffer(converter, ZBPlayerConverterFiller, self, &packetSize, list, NULL);


	ALuint bufferID;
	alGenBuffers(1, &bufferID);
	alBufferData(bufferID,AL_FORMAT_STEREO16, list->mBuffers[0].mData ,list->mBuffers[0].mDataByteSize,44100);

	if (!sourceID) {
		alGenSources(1, &sourceID);
		NSLog(@"the id is %i", sourceID);
//		alSourceQueueBuffers(sourceID, 1, &bufferID);

		alSourcei(sourceID, AL_BUFFER, bufferID);
//		alSourcef(sourceID, AL_PITCH, 3.0f);
//		alSourcef(sourceID, AL_GAIN, 1.0f);
//		alSource3f(sourceID, AL_POSITION, 3.0, 0.5, 1.5);
//		alSourcei(sourceID, AL_SOURCE_TYPE, AL_STREAMING);

		alSourcePlay(sourceID);

	}
//	[self performSelector:@selector(enqueue) withObject:nil afterDelay:10.0];
}

- (void)_createAudioConverterWithAudioStreamDescription:(AudioStreamBasicDescription *)audioStreamBasicDescription
{
	memcpy(&streamDescription, audioStreamBasicDescription, sizeof(AudioStreamBasicDescription));
	mDevice = alcOpenDevice(NULL);
	mContext = alcCreateContext(mDevice,NULL);
	alcMakeContextCurrent(mContext);

	AudioStreamBasicDescription destFormat;
	bzero(&destFormat, sizeof(AudioStreamBasicDescription));
	destFormat.mSampleRate = 44100.0;
	destFormat.mFormatID = kAudioFormatLinearPCM;
	destFormat.mFormatFlags = 0;
	destFormat.mFramesPerPacket = 1;
	destFormat.mBytesPerPacket = 4;
	destFormat.mBytesPerFrame = 4;
	destFormat.mChannelsPerFrame = 2;
	destFormat.mBitsPerChannel = 16;
	destFormat.mReserved = 0;

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

//	if (readHead == 0 & packetCount > (int)([self framePerSecond] * 12)) {
//		[self _enqueueDataWithPacketsCount: (int)([self framePerSecond] * 10)];
//	}
}

#pragma mark -
#pragma mark Properties

- (BOOL)isStopped
{
	return playerStatus.stopped;
}

@end

void ZBAudioFileStreamPropertyListener(void * inClientData, AudioFileStreamID inAudioFileStream, AudioFileStreamPropertyID inPropertyID, UInt32 * ioFlags)
{
	ZBSimpleALPlayer *self = (ZBSimpleALPlayer *)inClientData;
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
	ZBSimpleALPlayer *self = (ZBSimpleALPlayer *)inClientData;
	[self _storePacketsWithNumberOfBytes:inNumberBytes numberOfPackets:inNumberPackets inputData:inInputData packetDescriptions:inPacketDescriptions];
}

OSStatus ZBPlayerConverterFiller (AudioConverterRef inAudioConverter, UInt32* ioNumberDataPackets, AudioBufferList* ioData, AudioStreamPacketDescription** outDataPacketDescription, void* inUserData)
{
	ZBSimpleALPlayer *self = (ZBSimpleALPlayer *)inUserData;
	*ioNumberDataPackets = 1;
	[self _fillConverterBufferWithBufferlist:ioData packetDescription:outDataPacketDescription];
	return noErr;
}
