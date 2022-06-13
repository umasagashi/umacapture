// OpenCV must be imported before any Apple header due to duplication of NO macro definition.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#import <opencv2/opencv.hpp>
#import <opencv2/imgcodecs/ios.h>
#pragma clang diagnostic pop

#import <Foundation/Foundation.h>

#import "util/json_util.h"

#import "native_api.h"
#import "util/logger_util.h"

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

- (bool)createDirectory:(NSURL *)directory {
    auto result = [[NSFileManager defaultManager] createDirectoryAtURL:directory
                                           withIntermediateDirectories:YES
                                                            attributes:nil
                                                                 error:nil];
    return result == YES;
}

- (void)broadcastStartedWithSetupInfo:(NSDictionary<NSString *,NSObject *> *)setupInfo {
    uma::app::NativeApi::instance().setLoggingCallback([](const auto &message){
        NSString *buf = [NSString stringWithCString:message.c_str()
                                           encoding:[NSString defaultCStringEncoding]];
        NSLog(buf);
    });
    uma::logger_util::init();
    
    vlog_trace(1, 2, 3);
    vlog_debug(1, 2, 3);
    vlog_info(1, 2, 3);
    vlog_warning(1, 2, 3);
    vlog_error(1, 2, 3);
    vlog_fatal(1, 2, 3);
    
    uma::app::NativeApi::instance().setMkdirCallback([self](const auto &message){
        NSString *buf = [NSString stringWithCString:message.c_str()
                                           encoding:[NSString defaultCStringEncoding]];
        NSURL *url = [NSURL fileURLWithPath:buf];
        const auto ret = [self createDirectory:url];
        vlog_debug(ret);
    });

    auto userDefaults = [[NSUserDefaults alloc] initWithSuiteName: APP_GROUP];
    NSString *config = [userDefaults objectForKey:@"config"];
    auto configJson = uma::json_util::Json::parse([config cStringUsingEncoding:NSUTF8StringEncoding]);
    
    NSURL *imageDirectory = [self getSharedDirectoryURL:@"images"];
//    [self resetDirectory:imageDirectory];
    [[NSFileManager defaultManager] removeItemAtURL:imageDirectory error:nil];
    
    configJson["chara_detail"]["scraping_dir"] = [imageDirectory.path cStringUsingEncoding:NSUTF8StringEncoding];
    
    cv::Size minimumSize = {540, 960};
    assert(imageConverter == nil);
    imageConverter = [[ImageConverter alloc] initWithMinimumSize:minimumSize];
    
    uma::app::NativeApi::instance().startEventLoop(configJson.dump(0));
    log_debug("finished");
}

- (void)broadcastPaused {
    // Should stop native threads, but won't.
    // I don't want to be able to control all threads from here,
    // and if there is any delay while resuming, it will exceed the memory limit instantly.
}

- (void)broadcastResumed {
}

- (void)broadcastFinished {
    log_debug("");
    uma::app::NativeApi::instance().joinEventLoop();
    imageConverter = nil;
}

int counter_for_debug = 0;

- (void)processSampleBuffer:(CMSampleBufferRef)sampleBuffer withType:(RPSampleBufferType)sampleBufferType {
    switch (sampleBufferType) {
        case RPSampleBufferTypeVideo: {
            if (counter_for_debug++ % 10 != 0) {  // TODO: Check the queue size. This is reqired to prevent OOM in debug build.
                break;
            }
            const auto ts = uma::chrono_util::timestamp();
            cv::Mat mat = [imageConverter convertToMat:sampleBuffer];
            uma::app::NativeApi::instance().updateFrame(mat, ts);
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
