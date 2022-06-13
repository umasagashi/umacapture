#ifndef NativeApiWrapper_h
#define NativeApiWrapper_h

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface NativeApiBridge : NSObject

-(void)initializeNative;

-(void)setConfig:(NSString *)config;

-(void)setNotifyCallback:(void (^)(NSString *))method;

@end

#endif /* NativeApiWrapper_h */
