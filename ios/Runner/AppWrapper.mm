// OpenCV must be imported before any Apple header due to duplication of NO macro definition.
#import <opencv2/opencv.hpp>

#import "../../native/src/App.h"
#import "AppWrapper.h"

#import <Foundation/Foundation.h>

@implementation AppWrapper

-(void)setConfig:(NSString *)config {
    App::instance().setConfig([config cStringUsingEncoding:NSUTF8StringEncoding]);
}

@end
