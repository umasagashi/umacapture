// OpenCV must be imported before any Apple header due to duplication of NO macro definition.
#import <opencv2/opencv.hpp>
#import <opencv2/imgcodecs/ios.h>

#import "native_api.h"
#import "util/logger_util.h"

#import <Flutter/FlutterAppDelegate.h>
#import "Runner-Swift.h"
#import "NativeApiBridge.h"

#import <Foundation/Foundation.h>

@implementation NativeApiBridge

-(void)initializeNative {
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
}

-(void)setConfig:(NSString *)config {
    vlog_debug(config.length);
//    uma::NativeApi::instance().setConfig([config cStringUsingEncoding:NSUTF8StringEncoding]);
}

-(void)setNotifyCallback:(void (^)(NSString *))method {
    log_debug("");
    uma::app::NativeApi::instance().setNotifyCallback([=](const std::string &message) {
        NSString *buf = [NSString stringWithCString:message.c_str()
                                           encoding:[NSString defaultCStringEncoding]];
        method(buf);
    });
}

@end
