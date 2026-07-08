// OpenCV must be imported before any Apple header due to duplication of NO macro definition.
#import <opencv2/opencv.hpp>
#import <opencv2/imgcodecs/ios.h>

#import "native_api.h"
#import "util/logger_util.h"

#import <Flutter/FlutterAppDelegate.h>
#import "Runner-Swift.h"
#import "NativeApiBridge.h"

#import <Foundation/Foundation.h>

// NOTE: This iOS bridge is a leftover from the early proof-of-concept phase and is NOT maintained.
// Windows is the only supported platform today. It is kept (rather than deleted) so a future iOS port has
// a starting point. It is intentionally non-functional: no FlutterMethodChannel is registered, so none of
// the Dart-side methods (setConfig/setPlatformConfig/startCapture/stopCapture/updateRecord/
// copyToClipboardFromFile/takeScreenshot) are wired, and setConfig below is commented out.
//
// TODO(ios): before shipping iOS, (1) register a FlutterMethodChannel named
// "dev.flutter.umasagashi/capturing_channel" and forward every method to NativeApi, and (2) replace the
// two defaultCStringEncoding uses below with NSUTF8StringEncoding -- the native payloads are UTF-8 JSON
// (record ids, factor data), so the current encoding would corrupt any non-ASCII bytes.

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
