#import "ZBSimplePlayer.h"

static void ZBAudioFileStreamPropertyListener(void * inClientData, AudioFileStreamID inAudioFileStream, AudioFileStreamPropertyID inPropertyID, UInt32 * ioFlags);
static	void ZBAudioFileStreamPacketsCallback(void * inClientData, UInt32 inNumberBytes, UInt32 inNumberPackets, const void * inInputData, AudioStreamPacketDescription *inPacketDescriptions);
static void ZBAudioQueueOutputCallback(void * inUserData, AudioQueueRef inAQ,AudioQueueBufferRef inBuffer);

typedef struct {
	size_t length;
	void *data;
} ZBPacketData;

@implementation ZBSimplePlayer
{
	NSURLConnection *URLConnection;
	BOOL stopped;
	BOOL paused;

	AudioFileStreamID audioFileStreamID;
	AudioQueueRef outputQueue;

	ZBPacketData *packetData;
	size_t packetCount;
	size_t maxPacketCount;
	size_t readHead;
}

- (void)dealloc
{
	AudioQueueReset(outputQueue);
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
		stopped = NO;
		paused = YES;
		packetCount = 0;
		maxPacketCount = 10240;
		packetData = (ZBPacketData *)calloc(maxPacketCount, sizeof(ZBPacketData));

		AudioFileStreamOpen(self, ZBAudioFileStreamPropertyListener, ZBAudioFileStreamPacketsCallback, kAudioFileMP3Type, &audioFileStreamID);
		URLConnection = [[NSURLConnection alloc] initWithRequest:[NSURLRequest requestWithURL:inURL] delegate:self];
	}
	return self;
}

- (double)framePerSecond
{
	return 44100.0/1152.0;
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
	if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
		if ([(NSHTTPURLResponse *)response statusCode] != 200) {
			NSLog(@"HTTP code:%ld", [(NSHTTPURLResponse *)response statusCode]);
			[connection cancel];
			stopped = YES;
		}
	}
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
	AudioFileStreamParseBytes(audioFileStreamID, (UInt32)[data length], [data bytes], 0);
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
	NSLog(@"Complete loading data");
//	stopped = YES;
}
- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
	NSLog(@"Complete loading data");
	stopped = YES;
}

- (void)_enqueueDataWithPacketsCount:(size_t)inPacketCount
{
	NSLog(@"%s", __PRETTY_FUNCTION__);
	if (!outputQueue) {
		return;
	}

	if (readHead + inPacketCount >= packetCount) {
		inPacketCount = packetCount - readHead;
	}

	UInt32 totalSize = 0;
	UInt32 index;

	for (index = 0 ; index < inPacketCount ; index++) {
		totalSize += packetData[index + (UInt32)readHead].length;
	}

	OSStatus status = 0;
	AudioQueueBufferRef buffer;
	status = AudioQueueAllocateBuffer(outputQueue, totalSize, &buffer);
	assert(status == noErr);
	buffer->mAudioDataByteSize = totalSize;
	buffer->mUserData = self;

	AudioStreamPacketDescription *packetDescs = calloc(inPacketCount, sizeof(AudioStreamPacketDescription));

	totalSize = 0;
	for (index = 0 ; index < inPacketCount ; index++) {
		size_t readIndex = index + readHead;
		memcpy(buffer->mAudioData + totalSize, packetData[readIndex].data, packetData[readIndex].length);
		AudioStreamPacketDescription description;
		description.mStartOffset = totalSize;
		description.mDataByteSize = (UInt32)packetData[readIndex].length;
		description.mVariableFramesInPacket = 0;
		totalSize += packetData[readIndex].length;
		memcpy(&(packetDescs[index]), &description, sizeof(AudioStreamPacketDescription));
	}
	status = AudioQueueEnqueueBuffer(outputQueue, buffer, (UInt32)inPacketCount, packetDescs);
	free(packetDescs);
	readHead += inPacketCount;
}

- (void)_createAudioQueueWithAudioStreamDescription:(AudioStreamBasicDescription *)audioStreamBasicDescription
{
	OSStatus status = AudioQueueNewOutput(audioStreamBasicDescription, ZBAudioQueueOutputCallback, self, CFRunLoopGetCurrent(), kCFRunLoopCommonModes, 0, &outputQueue);
	assert(status == noErr);
	AudioQueueStart(outputQueue, NULL);
}

- (void)_storePacketsWithNumberOfBytes:(UInt32)inNumberBytes numberOfPackets:(UInt32)inNumberPackets inputData:(const void *)inInputData packetDescriptions:(AudioStreamPacketDescription *)inPacketDescriptions
{
	for (int i = 0; i < inNumberPackets; ++i) {
		SInt64 frameStart = inPacketDescriptions[i].mStartOffset;
		UInt32 packetSize = inPacketDescriptions[i].mDataByteSize;
		assert(packetSize > 0);
		packetData[packetCount].length = (size_t)packetSize;
		packetData[packetCount].data = malloc(packetSize);
		memcpy(packetData[packetCount].data, inInputData + frameStart, packetSize);
		packetCount++;
	}
	if (readHead == 0 & packetCount > (int)([self framePerSecond] * 3)) {
		paused = NO;
		AudioQueueStart(outputQueue, NULL);
		[self _enqueueDataWithPacketsCount: (int)([self framePerSecond] * 2)];
	}
}
- (BOOL)isStopped
{
	return stopped;
}

@end

void ZBAudioFileStreamPropertyListener(void * inClientData, AudioFileStreamID inAudioFileStream, AudioFileStreamPropertyID inPropertyID, UInt32 * ioFlags)
{
	NSLog(@"%s", __PRETTY_FUNCTION__);

	ZBSimplePlayer *self = (ZBSimplePlayer *)inClientData;
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

		[self _createAudioQueueWithAudioStreamDescription:&audioStreamDescription];
	}
}

void ZBAudioFileStreamPacketsCallback(void * inClientData, UInt32 inNumberBytes, UInt32 inNumberPackets, const void * inInputData, AudioStreamPacketDescription *inPacketDescriptions)
{
	ZBSimplePlayer *self = (ZBSimplePlayer *)inClientData;
	[self _storePacketsWithNumberOfBytes:inNumberBytes numberOfPackets:inNumberPackets inputData:inInputData packetDescriptions:inPacketDescriptions];
}

static void ZBAudioQueueOutputCallback(void * inUserData, AudioQueueRef inAQ,AudioQueueBufferRef inBuffer)
{
	NSLog(@"%s", __PRETTY_FUNCTION__);
	AudioQueueFreeBuffer(inAQ, inBuffer);
	ZBSimplePlayer *self = (ZBSimplePlayer *)inUserData;
	[self _enqueueDataWithPacketsCount:(int)([self framePerSecond] * 5)];
}
