#import <Foundation/Foundation.h>
#import "ZBSimplePlayer.h"
#import "ZBSimpleAUPlayer.h"
#import "ZBSimpleALPlayer.h"

int main (int argc, const char * argv[])
{
	NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];
	NSString *URL = @"http://zonble.net/MIDI/orz.mp3";
	URL = @"http://zonble.net/MIDI/orz-rock.mp3";
	URL = @"http://zonble.net/MIDI/zk3.mp3";
//	ZBSimplePlayer *player = [[ZBSimplePlayer alloc] initWithURL:[NSURL URLWithString:URL]];
//	ZBSimpleALPlayer *player = [[ZBSimpleALPlayer alloc] initWithURL:[NSURL URLWithString:URL]];
	ZBSimpleAUPlayer *player = [[ZBSimpleAUPlayer alloc] initWithURL:[NSURL URLWithString:URL]];
	player.semitones = -3;
	while (!player.stopped) {
		[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
	}
	[pool drain];
	return 0;
}

