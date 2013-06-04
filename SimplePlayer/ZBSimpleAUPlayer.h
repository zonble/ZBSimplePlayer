#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>

@interface ZBSimpleAUPlayer : NSObject

- (id)initWithURL:(NSURL *)inURL;
- (double)framePerSecond;

@property (readonly, getter=isStopped) BOOL stopped;

@end
