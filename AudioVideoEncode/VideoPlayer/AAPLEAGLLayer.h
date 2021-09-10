//
//  AAPLEAGLLayer.h
//

#include <QuartzCore/QuartzCore.h>
#include <CoreVideo/CoreVideo.h>

@interface AAPLEAGLLayer : CAEAGLLayer
@property CVPixelBufferRef pixelBuffer;
- (id)initWithFrame:(CGRect)frame;
- (void)resetRenderBuffer;
@end
