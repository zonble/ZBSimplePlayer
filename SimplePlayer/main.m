#import <Foundation/Foundation.h>
#import "ZBSimplePlayer.h"
#import "ZBSimpleALPlayer.h"

int main (int argc, const char * argv[])
{
	NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];
//	ZBSimplePlayer *player = [[ZBSimplePlayer alloc] initWithURL:[NSURL URLWithString:@"http://zonble.net/MIDI/orz.mp3"]];
	ZBSimpleALPlayer *player = [[ZBSimpleALPlayer alloc] initWithURL:[NSURL URLWithString:@"http://zonble.net/MIDI/orz.mp3"]];
	while (!player.stopped) {
		[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
	}
	[pool drain];
	return 0;
}

