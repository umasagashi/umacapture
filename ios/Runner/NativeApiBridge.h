#ifndef NativeApiWrapper_h
#define NativeApiWrapper_h

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface NativeApiBridge : NSObject

-(void)setConfig:(NSString *)config;

-(void)updateFrame:(UIImage *)image;

-(void)setCallback:(void (^)(NSString *))method;

-(void)startEventLoop;

-(void)joinEventLoop;

@end

#endif /* NativeApiWrapper_h */
