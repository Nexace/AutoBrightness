#import <AppKit/AppKit.h>
static NSColor *RGB(unsigned value, CGFloat alpha) {
    return [NSColor colorWithSRGBRed:((value>>16)&255)/255.0 green:((value>>8)&255)/255.0 blue:(value&255)/255.0 alpha:alpha];
}
static NSBezierPath *Round(NSRect rect, CGFloat r) { return [NSBezierPath bezierPathWithRoundedRect:rect xRadius:r yRadius:r]; }
int main(int argc, const char **argv) { @autoreleasepool {
    if (argc != 2) return 2;
    NSString *folder = [NSString stringWithUTF8String:argv[1]];
    [[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    // Only the sizes the iconset uses; the 1024-point drawing space is scaled to each.
    for (NSNumber *sizeValue in @[@16,@32,@64,@128]) {
        NSInteger size = sizeValue.integerValue;
        NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:size pixelsHigh:size bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap]];
        NSAffineTransform *scale = [NSAffineTransform transform];[scale scaleBy:size/1024.0];[scale concat];
        NSBezierPath *tile=Round(NSMakeRect(32,32,960,960),216);
        [[[NSGradient alloc] initWithColors:@[RGB(0x2b3a67,1),RGB(0x4f6bb0,1),RGB(0x9bb7e8,1)]] drawInBezierPath:tile angle:62];
        NSBezierPath *rim=Round(NSMakeRect(35,35,954,954),213);rim.lineWidth=3;[RGB(0xffffff,.22) setStroke];[rim stroke];
        NSPoint c=NSMakePoint(512,512);
        NSBezierPath *rays=[NSBezierPath bezierPath];rays.lineWidth=58;rays.lineCapStyle=NSLineCapStyleRound;
        for(int i=0;i<8;i++){ CGFloat a=i*M_PI/4,cs=cos(a),sn=sin(a);
            [rays moveToPoint:NSMakePoint(c.x+cs*270,c.y+sn*270)];[rays lineToPoint:NSMakePoint(c.x+cs*385,c.y+sn*385)]; }
        [RGB(0xffd36b,1) setStroke];[rays stroke];
        NSBezierPath *disc=[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x-175,c.y-175,350,350)];
        [[[NSGradient alloc] initWithStartingColor:RGB(0xfff1b8,1) endingColor:RGB(0xffb52e,1)] drawInBezierPath:disc angle:90];
        [NSGraphicsContext restoreGraphicsState];
        NSData *png=[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        NSString *name=[NSString stringWithFormat:@"autobrightness-%ld.png",(long)size];
        if (![png writeToFile:[folder stringByAppendingPathComponent:name] atomically:YES])return 1;
    }
    return 0;
} }
