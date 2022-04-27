// OpenCV must be imported before any Apple header due to duplication of NO macro definition.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#import <opencv2/opencv.hpp>
#import <opencv2/imgcodecs/ios.h>
#pragma clang diagnostic pop

#import <Foundation/Foundation.h>

#import "../../native/src/native_api.h"

#import "ImageConverter.h"
#import "SampleHandler.h"

@implementation SampleHandler

NSString *APP_GROUP = @"group.com.umasagashi";

ImageConverter *imageConverter = nil;

- (NSURL *)getSharedDirectoryURL:(NSString *)name {
    NSURL *root = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:APP_GROUP];
    if (root == nil) {
        return nil;
    }
    
    return [root URLByAppendingPathComponent:name];
}

- (bool)resetDirectory:(NSURL *)directory {
    [[NSFileManager defaultManager] removeItemAtURL:directory error:nil];
    auto result = [[NSFileManager defaultManager] createDirectoryAtURL:directory
                                           withIntermediateDirectories:YES
                                                            attributes:nil
                                                                 error:nil];
    return result == YES;
}

- (void)broadcastStartedWithSetupInfo:(NSDictionary<NSString *,NSObject *> *)setupInfo {
    NSLog(@"[UMABE]: broadcastStarted");
    
    auto userDefaults = [[NSUserDefaults alloc] initWithSuiteName: APP_GROUP];
    NSString *config = [userDefaults objectForKey:@"config"];
    NSLog(@"[UMABE]: %@", config);
    
    NSURL *imageDirectory = [self getSharedDirectoryURL:@"images"];
    [self resetDirectory:imageDirectory];
    
    NSString *dirConfig = [NSString stringWithFormat:@"{ \"directory\": \"%@\"}", imageDirectory.path];
    NSLog(@"[UMABE]: dir - %@", dirConfig);
    
    NativeApi::instance().setConfig([config cStringUsingEncoding:NSUTF8StringEncoding]);
    NativeApi::instance().setConfig([dirConfig cStringUsingEncoding:NSUTF8StringEncoding]);
    
    cv::Size minimumSize = {540, 960};
    assert(imageConverter == nil);
    imageConverter = [[ImageConverter alloc] initWithMinimumSize:minimumSize];
    
    std::function<void(const std::string &)> callback = [=](const std::string &message) {
        NSString *buf = [NSString stringWithCString:message.c_str()
                                           encoding:[NSString defaultCStringEncoding]];
        NSLog(@"[UMABE]: Callback: %@", buf);
    };
    NativeApi::instance().setCallback(callback);
    
    NativeApi::instance().startEventLoop();
}

- (void)broadcastPaused {
    // Should stop native threads, but won't.
    // I don't want to be able to control all threads from here,
    // and if there is any delay while resuming, it will exceed the memory limit instantly.
}

- (void)broadcastResumed {
}

- (void)broadcastFinished {
    NSLog(@"[UMABE]: broadcastFinished before");
    NativeApi::instance().joinEventLoop();
    imageConverter = nil;
    NSLog(@"[UMABE]: broadcastFinished after");
}

int counter_for_debug = 0;

- (void)processSampleBuffer:(CMSampleBufferRef)sampleBuffer withType:(RPSampleBufferType)sampleBufferType {
    switch (sampleBufferType) {
        case RPSampleBufferTypeVideo: {
            if (counter_for_debug++ > 100) {  // delay for debug
                cv::Mat mat = [imageConverter convertToMat:sampleBuffer];
                NativeApi::instance().updateFrame(mat);
            }
            break;
        }
        case RPSampleBufferTypeAudioApp:
            break;
        case RPSampleBufferTypeAudioMic:
            break;
        default:
            break;
    }
}

@end
