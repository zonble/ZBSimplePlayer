#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

@interface ZBSimplePlayer : NSObject

- (id)initWithURL:(NSURL *)inURL;
- (double)framePerSecond;

@property (readonly, getter=isStopped) BOOL stopped;

@end
