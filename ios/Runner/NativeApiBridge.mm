// OpenCV must be imported before any Apple header due to duplication of NO macro definition.
#import <opencv2/opencv.hpp>
#import <opencv2/imgcodecs/ios.h>

#import "../../native/src/native_api.h"

#import <Flutter/FlutterAppDelegate.h>
#import "Runner-Swift.h"
#import "NativeApiBridge.h"

#import <Foundation/Foundation.h>

@implementation NativeApiBridge

-(void)setConfig:(NSString *)config {
//    NSLog(@"setConfig: %@", config);
    NativeApi::instance().setConfig([config cStringUsingEncoding:NSUTF8StringEncoding]);
}

-(void)updateFrame:(UIImage *)image {
    //    NSLog(@"updateFrame:");
    cv::Mat mat;
    UIImageToMat(image, mat);
    cv::cvtColor(mat, mat, cv::COLOR_BGR2RGB);
    NativeApi::instance().updateFrame(mat);
}

-(void)setCallback:(void (^)(NSString *))method {
    std::function<void(const std::string &)> callback = [=](const std::string &message) {
        NSString *buf = [NSString stringWithCString:message.c_str()
                                           encoding:[NSString defaultCStringEncoding]];
        //        NSLog(@"Callback: %@", buf);
        method(buf);
    };
    NativeApi::instance().setCallback(callback);
}

-(void)startEventLoop {
    NativeApi::instance().startEventLoop();
}

-(void)joinEventLoop {
    NativeApi::instance().joinEventLoop();
}

@end
