// OpenCV must be imported before any Apple header due to duplication of NO macro definition.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#import <opencv2/opencv.hpp>
#import <opencv2/imgcodecs/ios.h>
#pragma clang diagnostic pop

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "../../native/src/native_api.h"

#import "ScopeExit.h"

#import "ImageConverter.h"

inline vImage_Buffer asBuffer(const cv::Mat &mat) {
    return {
        mat.data,
        vImagePixelCount(mat.rows),
        vImagePixelCount(mat.cols),
        mat.step
    };
}

inline cv::Mat extractPlane(CVImageBufferRef imageBuffer, int plane, int channels) {
    void *baseAddress = CVPixelBufferGetBaseAddressOfPlane(imageBuffer, plane);
    if (baseAddress == NULL) {
        return {};
    }
    return {
        CVPixelBufferGetHeightOfPlane(imageBuffer, plane),
        CVPixelBufferGetWidthOfPlane(imageBuffer, plane),
        CV_8UC(channels),
        baseAddress,
        CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, plane)
    };
}

inline cv::Size getCircumscribedSize(const cv::Size &source, const cv::Size &fitTo) {
    const float scale = std::max(float(fitTo.width) / float(source.width),
                                 float(fitTo.height) / float(source.height));
    return {
        int(std::round(float(source.width) * scale)),
        int(std::round(float(source.height) * scale))
    };
}

@implementation ImageConverter

cv::Size minimumSize_;

vImage_YpCbCrPixelRange pixelRange_;
vImage_YpCbCrToARGB conversionInfo_;
int interpolation_ = cv::INTER_LINEAR;

cv::Mat scaledLumaMat_;
cv::Mat scaledChromaMat_;

cv::Mat scaledYUVMat_;
cv::Mat scaledRGBMat_;

- (id)init {
    return nil;
}

- (id)initWithMinimumSize:(cv::Size)minimumSize {
    if ((self = [super init])) {
        minimumSize_ = minimumSize;
        
        pixelRange_ = vImage_YpCbCrPixelRange{
            .Yp_bias =  0,
            .CbCr_bias =  128,
            .YpRangeMax = 255,
            .CbCrRangeMax = 255,
            .YpMax = 255,
            .YpMin = 0,
            .CbCrMax = 255,
            .CbCrMin = 0
        };
        
        conversionInfo_ = vImage_YpCbCrToARGB();
        
        vImage_Error error = vImageConvert_YpCbCrToARGB_GenerateConversion(kvImage_YpCbCrToARGBMatrix_ITU_R_709_2,
                                                                           &pixelRange_,
                                                                           &conversionInfo_,
                                                                           kvImage420Yp8_CbCr8, // from
                                                                           kvImageARGB8888, // to
                                                                           vImage_Flags(kvImageNoFlags));
        assert(error == kvImageNoError);
    }
    return self;
}

- (cv::Mat) convertToMat:(CMSampleBufferRef)sampleBuffer {
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (imageBuffer == NULL) {
        return {};
    }
    
    if ((CVPixelBufferGetPixelFormatType(imageBuffer) != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        || (CVPixelBufferGetPlaneCount(imageBuffer) != 2)){
        return {};
    }
    
    if (CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        return {};
    }
    SCOPE_EXIT {
        CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
    };
    
    const cv::Mat &rawLumaMat = extractPlane(imageBuffer, 0, 1);
    if (rawLumaMat.empty()) {
        return {};
    }
    
    const cv::Mat &rawChromaMat = extractPlane(imageBuffer, 1, 2);
    if (rawChromaMat.empty()) {
        return {};
    }
    
    const cv::Size scaledSize = getCircumscribedSize(rawLumaMat.size(), minimumSize_);
    if (scaledLumaMat_.size() != scaledSize) {
        scaledLumaMat_ = cv::Mat(scaledSize, CV_8UC1);
        scaledChromaMat_ = cv::Mat(scaledSize, CV_8UC2);
        scaledYUVMat_ = cv::Mat(scaledSize, CV_8UC3);
        scaledRGBMat_ = cv::Mat(scaledSize, CV_8UC4);
    }

    cv::resize(rawLumaMat, scaledLumaMat_, scaledSize, 0, 0, interpolation_);
    cv::resize(rawChromaMat, scaledChromaMat_, scaledSize, 0, 0, interpolation_);
    cv::mixChannels(std::vector<cv::Mat>{scaledLumaMat_, scaledChromaMat_},
                    {scaledYUVMat_},
                    {0, 1, 1, 2, 2, 0});  // YpCbCr -> CrYpCb
    
    const uint8_t permuteMap[4] = {1, 2, 3, 0};  // ARGB -> RGBA
    vImage_Error error = vImageConvert_444CrYpCb8ToARGB8888(&asBuffer(scaledYUVMat_), // in
                                                            &asBuffer(scaledRGBMat_), // out
                                                            &conversionInfo_,
                                                            permuteMap,
                                                            255,
                                                            vImage_Flags(kvImageNoFlags));
    if (error != kvImageNoError) {
        return {};
    }

    cv::Mat mat = cv::Mat(scaledSize, CV_8UC3);
    cv::cvtColor(scaledRGBMat_, mat, cv::COLOR_RGBA2RGB);
//    CGImageRef _mat = MatToCGImage(mat);
    return mat;
}

@end
