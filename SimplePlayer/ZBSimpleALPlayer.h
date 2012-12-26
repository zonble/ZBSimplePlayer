#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <OpenAL/al.h>
#import <OpenAL/alc.h>

@interface ZBSimpleALPlayer : NSObject

- (id)initWithURL:(NSURL *)inURL;
- (double)framePerSecond;

@property (readonly, getter=isStopped) BOOL stopped;

@end
