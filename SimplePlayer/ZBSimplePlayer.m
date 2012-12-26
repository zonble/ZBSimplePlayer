#import "ZBSimplePlayer.h"

static void ZBAudioFileStreamPropertyListener(void * inClientData, AudioFileStreamID inAudioFileStream, AudioFileStreamPropertyID inPropertyID, UInt32 * ioFlags);
static void ZBAudioFileStreamPacketsCallback(void * inClientData, UInt32 inNumberBytes, UInt32 inNumberPackets, const void * inInputData, AudioStreamPacketDescription *inPacketDescriptions);
static void ZBAudioQueueOutputCallback(void * inUserData, AudioQueueRef inAQ,AudioQueueBufferRef inBuffer);
static void ZBAudioQueueRunningListener(void * inUserData, AudioQueueRef inAQ, AudioQueuePropertyID inID);


typedef struct {
	size_t length;
	void *data;
} ZBPacketData;

@implementation ZBSimplePlayer
{
	NSURLConnection *URLConnection;
	struct {
		BOOL stopped;
		BOOL loaded;
	} playerStatus ;

	AudioFileStreamID audioFileStreamID;
	AudioQueueRef outputQueue;

	AudioStreamBasicDescription streamDescription;
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
}
- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
	NSLog(@"Failed to load data: %@", [error localizedDescription]);
	playerStatus.stopped = YES;
}

#pragma mark -
#pragma mark Audio Parser and Audio Queue callbacks

- (void)_enqueueDataWithPacketsCount:(size_t)inPacketCount
{
	NSLog(@"%s", __PRETTY_FUNCTION__);
	if (!outputQueue) {
		return;
	}

	if (readHead == packetCount) {
		// 第六步：已經把所有 packet 都播完了，檔案播放結束。
		if (playerStatus.loaded) {
			AudioQueueStop(outputQueue, false);
			playerStatus.stopped = YES;
			return;
		}
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
	memcpy(&streamDescription, audioStreamBasicDescription, sizeof(AudioStreamBasicDescription));
	OSStatus status = AudioQueueNewOutput(audioStreamBasicDescription, ZBAudioQueueOutputCallback, self, CFRunLoopGetCurrent(), kCFRunLoopCommonModes, 0, &outputQueue);
	assert(status == noErr);
	status = AudioQueueAddPropertyListener(outputQueue, kAudioQueueProperty_IsRunning, ZBAudioQueueRunningListener, self);
	AudioQueuePrime(outputQueue, 0, NULL);
	AudioQueueStart(outputQueue, NULL);
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

	//	第五步，因為 parse 出來的 packets 夠多，緩衝內容夠大，因此開始
	//	播放

	if (readHead == 0 & packetCount > (int)([self framePerSecond] * 3)) {
		AudioQueueStart(outputQueue, NULL);
		[self _enqueueDataWithPacketsCount: (int)([self framePerSecond] * 2)];
	}
}

- (void)_audioQueueDidStart
{
	NSLog(@"Audio Queue did start");
}

- (void)_audioQueueDidStop
{
	NSLog(@"Audio Queue did stop");
	playerStatus.stopped = YES;
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

		// 第三步： Audio Parser 成功 parse 出 audio 檔案格式，我們根據
		// 檔案格式資訊，建立 Audio Queue，同時監聽 Audio Queue 是否正
		// 在執行

		[self _createAudioQueueWithAudioStreamDescription:&audioStreamDescription];
	}
}

void ZBAudioFileStreamPacketsCallback(void * inClientData, UInt32 inNumberBytes, UInt32 inNumberPackets, const void * inInputData, AudioStreamPacketDescription *inPacketDescriptions)
{
	// 第四步： Audio Parser 成功 parse 出 packets，我們將這些資料儲存
	// 起來

	ZBSimplePlayer *self = (ZBSimplePlayer *)inClientData;
	[self _storePacketsWithNumberOfBytes:inNumberBytes numberOfPackets:inNumberPackets inputData:inInputData packetDescriptions:inPacketDescriptions];
}

static void ZBAudioQueueOutputCallback(void * inUserData, AudioQueueRef inAQ,AudioQueueBufferRef inBuffer)
{
	AudioQueueFreeBuffer(inAQ, inBuffer);
	ZBSimplePlayer *self = (ZBSimplePlayer *)inUserData;
	[self _enqueueDataWithPacketsCount:(int)([self framePerSecond] * 5)];
}

static void ZBAudioQueueRunningListener(void * inUserData, AudioQueueRef inAQ, AudioQueuePropertyID inID)
{
	ZBSimplePlayer *self = (ZBSimplePlayer *)inUserData;
	UInt32 dataSize;
	OSStatus status = 0;
	status = AudioQueueGetPropertySize(inAQ, inID, &dataSize);
	if (inID == kAudioQueueProperty_IsRunning) {
		UInt32 running;
		status = AudioQueueGetProperty(inAQ, inID, &running, &dataSize);
		running ? [self _audioQueueDidStart] : [self _audioQueueDidStop];
	}
}
