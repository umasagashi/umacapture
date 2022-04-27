@interface ImageConverter : NSObject

- (id)initWithMinimumSize:(cv::Size)minimumSize;

- (cv::Mat)convertToMat:(CMSampleBufferRef)sampleBuffer;

@end
