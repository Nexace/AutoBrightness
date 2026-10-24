#import <AppKit/AppKit.h>
#import <mach/mach.h>
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurface.h>
#include <sys/file.h>
#include <fcntl.h>
#include <errno.h>
#include <malloc/malloc.h>
#include <objc/message.h>
#import "auto.h"

enum { PanelWidth = 260, PanelHeight = 164 };

// Tests replace these to exercise failure states without touching the real display.
static CGDirectDisplayID (*FindDisplay)(void) = BuiltInDisplay;
static int ReduceTransparencyOverride = -1;
static BOOL ReduceTransparency(void) {
    return ReduceTransparencyOverride >= 0 ? ReduceTransparencyOverride : NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceTransparency;
}

// WindowServer's native backdrop blur avoids creating a separate local effect renderer.
// This private per-window API is also used by native terminal/windowing implementations.
static int32_t LastBlurError;
static BOOL ApplyBackdrop(NSWindow *window) {
    static int32_t (*connection)(void);
    static int32_t (*blur)(int32_t,uint32_t,uint32_t);
    static BOOL loaded;
    if(!loaded) {
        loaded=YES;
        void *library=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_LAZY|RTLD_LOCAL);
        if(library){connection=dlsym(library,"SLSMainConnectionID");blur=dlsym(library,"SLSSetWindowBackgroundBlurRadius");}
    }
    if(!connection||!blur)return NO;
    LastBlurError=blur(connection(),(uint32_t)window.windowNumber,ReduceTransparency()?0:36);return LastBlurError==0;
}

static NSColor *Muted(NSView *view) {
    BOOL dark=[[view.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]]isEqual:NSAppearanceNameDarkAqua];
    return [NSColor colorWithWhite:dark?.94:.08 alpha:.72];
}
static void Round(NSRect r, CGFloat radius, NSColor *color) { [color setFill]; [[NSBezierPath bezierPathWithRoundedRect:r xRadius:radius yRadius:radius] fill]; }
static void Text(NSString *s, NSPoint point, CGFloat size, NSFontWeight weight, NSColor *color) {
    @autoreleasepool { [s drawAtPoint:point withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:size weight:weight], NSForegroundColorAttributeName:color}]; }
}
static void Wrapped(NSString *s, NSRect rect, CGFloat size, NSColor *color) {
    @autoreleasepool { [s drawInRect:rect withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:size], NSForegroundColorAttributeName:color}]; }
}
// A sun drawn from native paths so one routine serves menu bar and panel: filled = on, outline = off.
typedef NS_ENUM(NSInteger, SunStyle) { SunRing, SunFilled };
static void Sun(NSPoint center, CGFloat radius, NSColor *color, SunStyle style) {
    [color set];
    NSBezierPath *p=[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(center.x-radius*.42,center.y-radius*.42,radius*.84,radius*.84)];p.lineWidth=radius*.17;
    if(style==SunFilled)[p fill];else [p stroke];
    p=[NSBezierPath bezierPath];p.lineWidth=radius*.17;p.lineCapStyle=NSLineCapStyleRound;
    for(int i=0;i<8;i++) {
        CGFloat a=i*M_PI/4,c=cos(a),s=sin(a);
        [p moveToPoint:NSMakePoint(center.x+c*radius*.72,center.y+s*radius*.72)];[p lineToPoint:NSMakePoint(center.x+c*radius,center.y+s*radius)];
    }
    [p stroke];
}
// `alpha` < 1 marks an unavailable setting; template images keep their alpha.
static NSImage *StatusIcon(SunStyle style,CGFloat alpha) {
    NSImage *image=[NSImage imageWithSize:NSMakeSize(22,18) flipped:NO drawingHandler:^BOOL(NSRect rect){(void)rect;Sun(NSMakePoint(11,9),8,[NSColor.blackColor colorWithAlphaComponent:alpha],style);return YES;}];
    image.template=YES;return image;
}

static double KernelPeak;
static double Footprint(void) {
    task_vm_info_data_t t={0};mach_msg_type_number_t c=TASK_VM_INFO_COUNT;
    if(task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&t,&c)!=KERN_SUCCESS||c<TASK_VM_INFO_REV3_COUNT){KernelPeak=INFINITY;return INFINITY;}
    if(t.ledger_phys_footprint_peak>0)KernelPeak=t.ledger_phys_footprint_peak/1000000.0;
    return t.phys_footprint/1000000.0;
}

@interface AutoPanel : NSPanel
@end
@implementation AutoPanel
- (BOOL)canBecomeKeyWindow { return YES; }
@end

static void PaintSurface(NSView *view,id __strong *storage) {
    // ponytail: one shared surface for the whole panel; add buffering if tearing is observed.
    // This avoids vector-renderer caches and repeated bitmap copies.
    @autoreleasepool {
        CGFloat scale=view.window.backingScaleFactor?:2;
        size_t width=MAX(1,(size_t)ceil(view.bounds.size.width*scale));
        size_t height=MAX(1,(size_t)ceil(view.bounds.size.height*scale));
        IOSurfaceRef surface=(__bridge IOSurfaceRef)(*storage);
        if(!surface||IOSurfaceGetWidth(surface)!=width||IOSurfaceGetHeight(surface)!=height) {
            surface=IOSurfaceCreate((__bridge CFDictionaryRef)@{
                (__bridge NSString *)kIOSurfaceWidth:@(width),(__bridge NSString *)kIOSurfaceHeight:@(height),
                (__bridge NSString *)kIOSurfaceBytesPerElement:@4,(__bridge NSString *)kIOSurfaceBytesPerRow:@(width*4),
                (__bridge NSString *)kIOSurfacePixelFormat:@(0x42475241)});
            if(!surface)return;
            *storage=CFBridgingRelease(surface);
        }
        if(IOSurfaceLock(surface,0,NULL)!=kIOReturnSuccess)return;
        CGColorSpaceRef color=CGColorSpaceCreateDeviceRGB();
        CGContextRef context=CGBitmapContextCreate(IOSurfaceGetBaseAddress(surface),width,height,8,IOSurfaceGetBytesPerRow(surface),color,kCGImageAlphaPremultipliedFirst|kCGBitmapByteOrder32Little);
        CGColorSpaceRelease(color);
        if(context) {
            CGContextClearRect(context,CGRectMake(0,0,width,height));CGContextScaleCTM(context,scale,scale);
            [NSGraphicsContext saveGraphicsState];
            NSGraphicsContext.currentContext=[NSGraphicsContext graphicsContextWithCGContext:context flipped:NO];
            [view.effectiveAppearance performAsCurrentDrawingAppearance:^{[view drawRect:view.bounds];}];
            [NSGraphicsContext restoreGraphicsState];CGContextRelease(context);
        }
        IOSurfaceUnlock(surface,0,NULL);
        [CATransaction begin];[CATransaction setDisableActions:YES];
        view.layer.contentsFormat=kCAContentsFormatRGBA8Uint;view.layer.contentsScale=scale;
        view.layer.contents=nil;view.layer.contents=(__bridge id)surface;
        [CATransaction commit];
    }
}

typedef NS_ENUM(NSInteger, ControlKind) { KindSwitch, KindLink, KindPill };

// Controls own input and accessibility only; the panel view paints them into its single surface.
@interface PanelControl : NSControl
@property ControlKind kind;
@property (copy) NSString *label;
@property (copy) NSString *help;
@property (copy) NSString *valueText;
@property BOOL on;
@property BOOL focusVisible;
- (void)paintInParent;
- (BOOL)press;
@end
@implementation PanelControl
- (BOOL)wantsUpdateLayer { return YES; }
- (void)updateLayer {}
- (BOOL)acceptsFirstResponder { return self.enabled && !self.hidden; }
- (NSTextInputContext *)inputContext { return nil; }
- (void)redraw { self.superview.needsDisplay=YES; }
- (BOOL)becomeFirstResponder { self.focusVisible=NSApp.currentEvent.type==NSEventTypeKeyDown;[self redraw];return YES; }
- (BOOL)resignFirstResponder { self.focusVisible=NO;[self redraw];return YES; }
- (BOOL)isAccessibilityElement { return YES; }
- (NSString *)accessibilityRole { return self.kind==KindSwitch?NSAccessibilityCheckBoxRole:NSAccessibilityButtonRole; }
- (NSString *)accessibilitySubrole { return self.kind==KindSwitch?NSAccessibilitySwitchSubrole:nil; }
- (NSString *)accessibilityLabel { return self.label; }
- (NSString *)accessibilityHelp { return self.help; }
- (id)accessibilityValue { return self.kind==KindSwitch?@(self.on):nil; }
- (NSString *)accessibilityValueDescription { return self.kind==KindSwitch?self.valueText:nil; }
- (BOOL)isAccessibilityEnabled { return self.enabled; }
- (BOOL)accessibilityPerformPress { return [self press]; }
- (BOOL)press { if(!self.enabled||self.hidden)return NO;[self sendAction:self.action to:self.target];return YES; }
- (void)mouseDown:(NSEvent *)event {
    if(!self.enabled)return;[self.window makeFirstResponder:self];self.focusVisible=NO;[self redraw];
    while(event.type!=NSEventTypeLeftMouseUp) {
        event=[self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged|NSEventMaskLeftMouseUp];
        if(!event)return;
    }
    if(NSPointInRect([self convertPoint:event.locationInWindow fromView:nil],self.bounds))[self press];
}
- (void)keyDown:(NSEvent *)event {
    if(event.keyCode==49||event.keyCode==36){self.focusVisible=YES;[self press];}else [super keyDown:event];
}
- (void)paintInParent {
    NSRect f=self.frame;CGFloat alpha=self.enabled?1:.45;
    switch(self.kind) {
        case KindSwitch:
            Round(NSMakeRect(f.origin.x+1,f.origin.y+4,30,18),9,self.on?[NSColor.controlAccentColor colorWithAlphaComponent:alpha]:[NSColor.labelColor colorWithAlphaComponent:.16*alpha]);
            Round(NSMakeRect(f.origin.x+(self.on?15:3),f.origin.y+6,14,14),7,[NSColor.whiteColor colorWithAlphaComponent:alpha]);
            break;
        case KindLink:
            Text(self.label,NSMakePoint(f.origin.x,f.origin.y+5),11,NSFontWeightRegular,Muted(self.superview));
            break;
        case KindPill: {
            Round(f,8,NSColor.controlAccentColor);
            NSDictionary *a=@{NSFontAttributeName:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium]};
            Text(self.label,NSMakePoint(NSMidX(f)-[self.label sizeWithAttributes:a].width/2,f.origin.y+7),12,NSFontWeightMedium,NSColor.whiteColor);
            break; }
    }
    if(self.focusVisible && self.window.firstResponder==self) {
        [[NSColor keyboardFocusIndicatorColor]setStroke];
        NSBezierPath *p=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(f,self.kind==KindPill?-2:1,self.kind==KindPill?-2:1) xRadius:self.kind==KindPill?10:7 yRadius:self.kind==KindPill?10:7];p.lineWidth=2;[p stroke];
    }
}
@end

typedef NS_ENUM(NSInteger, AutoState) { AutoChecking, AutoOn, AutoOff, AutoUnsupported, AutoUnreadable };

@interface AutoView : NSView
@property PanelControl *toggle;
@property PanelControl *settings;
@property PanelControl *openPill;
@property PanelControl *quit;
@property AutoState state;
@property (copy) NSString *message; // why unsupported, or why the last read/write failed
@property BOOL working;
@property (strong) id rasterSurface;
@end
@implementation AutoView
- (BOOL)wantsUpdateLayer { return YES; }
- (void)updateLayer { PaintSurface(self,&_rasterSurface); }
- (BOOL)isAccessibilityElement { return YES; }
- (NSString *)accessibilityRole { return NSAccessibilityGroupRole; }
- (NSString *)accessibilityLabel { return @"Automatic brightness"; }
- (NSString *)accessibilityValue { return self.message; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSBezierPath *surface=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,.5,.5) xRadius:20 yRadius:20];
    BOOL dark=[[self.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]]isEqual:NSAppearanceNameDarkAqua];
    if(ReduceTransparency()) { [NSColor.windowBackgroundColor setFill];[surface fill]; }
    else { [[NSColor colorWithWhite:dark?.16:.98 alpha:dark?.69:.66]setFill];[surface fill]; }
    surface.lineWidth=1;[[NSColor colorWithWhite:1 alpha:dark?.23:.66]setStroke];[surface stroke];
    NSColor *ink=NSColor.labelColor,*muted=Muted(self);
    Sun(NSMakePoint(27,144),9,ink,SunRing);
    Text(@"Automatic brightness",NSMakePoint(44,136),13,NSFontWeightMedium,ink);
    if(self.state==AutoUnsupported) {
        Wrapped(self.message,NSMakeRect(18,78,224,50),11,muted);
    } else {
        Wrapped(@"When on, your Mac’s ambient light sensor adjusts the built-in display’s brightness to match your surroundings.",NSMakeRect(18,78,224,50),11,muted);
        NSString *status=self.working?@"Applying…":self.state==AutoOn?@"On — follows ambient light":self.state==AutoOff?@"Off — brightness stays where you set it":self.state==AutoChecking?@"Checking…":nil;
        if(self.message) {
            Round(NSMakeRect(19,60,6,6),3,NSColor.systemRedColor);
            Wrapped(self.message,NSMakeRect(30,44,212,26),10.5,muted);
        } else if(status) {
            Round(NSMakeRect(19,54,6,6),3,self.state==AutoOn?NSColor.systemGreenColor:NSColor.tertiaryLabelColor);
            Text(status,NSMakePoint(30,50),11,NSFontWeightRegular,ink);
        }
    }
    [NSColor.separatorColor setFill];NSRectFill(NSMakeRect(15,38,230,.5));
    for(PanelControl *c in self.subviews)if(!c.hidden)[c paintInParent];
}
- (void)cancelOperation:(id)sender { (void)sender;[NSApp.delegate performSelector:@selector(closePanel:) withObject:nil]; }
@end

@interface AutoApp : NSObject <NSApplicationDelegate>
@property NSStatusItem *item;
@property AutoPanel *panel;
@property AutoView *view;
@property id globalMonitor;
@property id localMonitor;
@property (nonatomic) dispatch_queue_t queue;
@property BOOL busy;
@property NSInteger writes;
@property BOOL verifying;
@property BOOL profiling;
@property BOOL failed;
@property double peak;
@property BOOL originalCaptured;
@property BOOL original;
@property CGDirectDisplayID originalDisplay;
@property int cycle;
@property BOOL expected;
@property id signalSources;
@property AutoState iconState;
@property NSTask *hoverTask; // the child process showing the delayed name/description label
@property NSArray<NSString *> *hoverArguments; // set only in the child (`--hover`)
@property NSPanel *hoverWindow;
@property BOOL finished; // verification is over: no further steps or writes
@property NSInteger generation; // bumped by every open/close so a stale deferred release is ignored
@property BOOL retainPanel; // tests keep the panel alive; the app frees it on close
@end
@implementation AutoApp
- (dispatch_queue_t)queue {
    if(!_queue)_queue=dispatch_queue_create("local.amogh.AutoBrightness.backend",DISPATCH_QUEUE_SERIAL);
    return _queue;
}
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    (void)note;
    if(self.hoverArguments){[self runHoverChild:self.hoverArguments];return;}
    self.item=[[NSStatusBar systemStatusBar]statusItemWithLength:NSSquareStatusItemLength];
    self.item.button.target=self;self.item.button.action=@selector(statusClicked:);
    [self.item.button sendActionOn:NSEventMaskLeftMouseUp|NSEventMaskRightMouseUp];
    self.item.button.accessibilityLabel=@"Automatic brightness";
    self.item.button.accessibilityCustomActions=@[[[NSAccessibilityCustomAction alloc]initWithName:@"Show options" target:self selector:@selector(showOptions:)]];
    self.item.autosaveName=@"AutoBrightness";self.item.visible=YES;
    [self.item.button addTrackingArea:[[NSTrackingArea alloc]initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited|NSTrackingActiveAlways|NSTrackingInVisibleRect owner:self userInfo:nil]];
    if(!self.verifying && !self.profiling)[self registerLoginItem];
    [self updateIcon];[self refresh]; // the icon must show the real setting from the start
    if(self.verifying || self.profiling) {
        [self performSelector:self.profiling?@selector(profileOpen):@selector(beginVerification) withObject:nil afterDelay:3];
    }
}
- (void)applicationWillTerminate:(NSNotification *)note { (void)note;[self restoreOriginal]; }

- (void)makePanel {
    self.panel=[[AutoPanel alloc]initWithContentRect:NSMakeRect(0,0,PanelWidth,PanelHeight) styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
    self.panel.colorSpace=NSColorSpace.sRGBColorSpace;self.panel.backgroundColor=NSColor.clearColor;self.panel.opaque=NO;self.panel.hasShadow=NO;self.panel.level=NSPopUpMenuWindowLevel;self.panel.hidesOnDeactivate=NO;
    self.view=[[AutoView alloc]initWithFrame:NSMakeRect(0,0,PanelWidth,PanelHeight)];
    self.view.wantsLayer=YES;self.panel.contentView=self.view;
    PanelControl *(^make)(ControlKind,NSRect,NSString *,SEL)=^PanelControl *(ControlKind kind,NSRect frame,NSString *label,SEL action) {
        PanelControl *c=[[PanelControl alloc]initWithFrame:frame];c.kind=kind;c.label=label;c.enabled=YES;c.target=self;c.action=action;
        [self.view addSubview:c];return c;
    };
    self.view.toggle=make(KindSwitch,NSMakeRect(210,131,32,26),@"Automatic brightness",@selector(toggleAuto:));
    self.view.toggle.help=@"When on, your Mac’s ambient light sensor adjusts the built-in display’s brightness.";
    self.view.openPill=make(KindPill,NSMakeRect(18,50,224,28),@"Open Displays Settings",@selector(openSettings:));
    self.view.settings=make(KindLink,NSMakeRect(18,8,118,24),@"Displays Settings…",@selector(openSettings:));
    self.view.quit=make(KindLink,NSMakeRect(210,8,32,24),@"Quit",@selector(quit:));
    self.view.toggle.nextKeyView=self.view.settings;self.view.settings.nextKeyView=self.view.openPill;
    self.view.openPill.nextKeyView=self.view.quit;self.view.quit.nextKeyView=self.view.toggle;
    self.panel.initialFirstResponder=self.view.toggle;
    self.view.state=self.iconState;[self render];
}
// Brings the controls in line with view.state; the switch moves only after macOS confirms a value.
- (void)render {
    AutoView *v=self.view;if(!v)return;BOOL unsupported=v.state==AutoUnsupported;
    v.toggle.hidden=unsupported;v.settings.hidden=unsupported;v.openPill.hidden=!unsupported;
    v.toggle.on=v.state==AutoOn;v.toggle.enabled=(v.state==AutoOn||v.state==AutoOff)&&!self.busy;
    v.toggle.valueText=v.state==AutoOn?@"On":v.state==AutoOff?@"Off":@"Unavailable";
    v.needsDisplay=YES;
    NSAccessibilityPostNotification(v.toggle,NSAccessibilityValueChangedNotification);
    if(!self.busy && self.panel.visible && self.panel.isKeyWindow) { // keep focus put while a change is in flight
        NSResponder *current=self.panel.firstResponder;
        if(!current || ![current isKindOfClass:PanelControl.class] || !((PanelControl *)current).acceptsFirstResponder)
            [self.panel makeFirstResponder:unsupported?v.openPill:(v.toggle.enabled?v.toggle:v.quit)];
    }
}
- (void)apply:(BOOL)enabled message:(NSString *)message unsupported:(BOOL)unsupported known:(BOOL)known {
    self.busy=NO;self.view.working=NO;self.view.message=message;
    self.iconState=unsupported?AutoUnsupported:!known?AutoUnreadable:enabled?AutoOn:AutoOff;
    self.view.state=self.iconState;
    [self updateIcon];[self render];
}
- (void)updateIcon {
    static NSImage *images[3];
    int variant=self.iconState==AutoOn?1:self.iconState==AutoOff?0:2;
    if(!images[variant])images[variant]=StatusIcon(variant==1?SunFilled:SunRing,variant==2?.45:1);
    NSButton *button=self.item.button;button.image=images[variant];
    NSString *state=self.iconState==AutoOn?@"On":self.iconState==AutoOff?@"Off":@"Unavailable";
    button.accessibilityValueDescription=state;
    if(button)NSAccessibilityPostNotification(button,NSAccessibilityValueChangedNotification);
    button.accessibilityHelp=self.hoverLines[2];
}
// Left click changes the setting directly; right/Control click, or the accessibility action, opens the panel.
- (void)statusClicked:(id)sender {
    (void)sender;[self hideHover];NSEvent *event=NSApp.currentEvent;
    BOOL fromButton=event.window==self.item.button.window; // an accessibility press can leave a stale event
    [self click:fromButton && (event.type==NSEventTypeRightMouseUp || (event.modifierFlags&NSEventModifierFlagControl))];
}
- (void)click:(BOOL)secondary {
    if(self.panel.visible){[self closePanel:nil];return;}
    if(secondary||self.iconState==AutoUnsupported||self.iconState==AutoUnreadable)[self openPanel:YES];
    else if(self.iconState==AutoChecking)[self refresh];
    else [self change:YES to:NO];
}
- (BOOL)showOptions:(id)sender { (void)sender;[self openPanel:YES];return YES; }
// Reads on a background queue: the system service may be slow, and the menu bar must never hang.
- (void)refresh {
    if(self.busy)return;self.busy=YES;
    [self render];
    dispatch_async(self.queue,^{
        BOOL enabled=NO,unsupported=NO;NSString *issue=LoadSystemBackend();
        if(issue)unsupported=YES;else issue=ReadAuto(FindDisplay(),&enabled,&unsupported);
        dispatch_async(dispatch_get_main_queue(),^{[self apply:enabled message:issue unsupported:unsupported known:issue==nil];});
    });
}
// flip=YES toggles whatever macOS has right now; otherwise sets `on`. A change made while another
// is in flight is ignored. The UI shows only values macOS confirmed by independent readback.
- (void)change:(BOOL)flip to:(BOOL)on {
    if(self.busy)return;self.busy=YES;self.writes++;self.view.working=YES;self.view.message=nil;[self render];
    dispatch_async(self.queue,^{
        CGDirectDisplayID display=FindDisplay();BOOL enabled=on,unsupported=NO;NSString *issue=LoadSystemBackend(),*readIssue=nil;
        if(issue)unsupported=YES;
        else {
            BOOL target=on;
            if(flip){BOOL current=NO;issue=readIssue=ReadAuto(display,&current,&unsupported);target=!current;}
            if(!issue){
                issue=WriteAuto(display,target);enabled=target;
                if(issue)readIssue=ReadAuto(display,&enabled,&unsupported); // show what macOS really has after a failure
            }
        }
        dispatch_async(dispatch_get_main_queue(),^{
            NSString *message=issue?:readIssue;
            if(message&&!self.panel)[self makePanel];
            [self apply:enabled message:message unsupported:unsupported known:readIssue==nil];
            if(message&&!self.panel.visible)[self openPanel:NO]; // a failed menu bar click explains itself
        });
    });
}
- (void)toggleAuto:(id)sender { (void)sender;[self change:NO to:!self.view.toggle.on]; }

- (void)togglePanel:(id)sender {
    (void)sender;if(self.panel.visible){[self closePanel:nil];return;}
    [self openPanel:YES];
}
#pragma mark - Launch at login
// Registers the app as a login item once, when it runs from an Applications folder. Apple's
// SMAppService is loaded only for that first run; later launches never touch it, so turning
// the item off in System Settings → General → Login Items is respected.
- (void)registerLoginItem {
    NSString *path=NSBundle.mainBundle.bundlePath;
    if(![path hasPrefix:@"/Applications/"] && ![path hasPrefix:[NSHomeDirectory() stringByAppendingPathComponent:@"Applications/"]])return;
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
    if([defaults boolForKey:@"LoginItemRequested"])return;
    if(!dlopen("/System/Library/Frameworks/ServiceManagement.framework/ServiceManagement",RTLD_LAZY|RTLD_LOCAL))return;
    Class type=NSClassFromString(@"SMAppService");SEL mainApp=NSSelectorFromString(@"mainAppService");
    if(!type||![type respondsToSelector:mainApp])return;
    id service=((id(*)(Class,SEL))objc_msgSend)(type,mainApp);
    NSError *error=nil;
    BOOL ok=((BOOL(*)(id,SEL,NSError **))objc_msgSend)(service,NSSelectorFromString(@"registerAndReturnError:"),&error);
    NSInteger status=((NSInteger(*)(id,SEL))objc_msgSend)(service,NSSelectorFromString(@"status"));
    if(ok||status==1||status==2)[defaults setBool:YES forKey:@"LoginItemRequested"]; // 1 enabled, 2 needs approval
    else fprintf(stderr,"Launch at login failed: %s\n",error.localizedDescription.UTF8String);
}

#pragma mark - Hover label
- (NSArray<NSString *> *)hoverLines {
    NSString *state=self.iconState==AutoOn?@"Automatic brightness: On":self.iconState==AutoOff?@"Automatic brightness: Off":@"Automatic brightness: unavailable";
    NSString *hint=self.iconState==AutoOn?@"Click to turn off · Right-click for options":self.iconState==AutoOff?@"Click to turn on · Right-click for options":@"Right-click for options";
    return @[@"AutoBrightness",state,hint];
}
- (void)mouseEntered:(NSEvent *)event {
    (void)event;[self hideHover];
    if(!self.panel.visible)[self performSelector:@selector(showHover) withObject:nil afterDelay:.5];
}
- (void)mouseExited:(NSEvent *)event { (void)event;[self hideHover]; }
// The label is drawn by a short-lived copy of this executable (`--hover`), because AppKit's Liquid
// Glass keeps several MB resident in whatever process shows it. The icon process just starts and
// stops that child; the child also exits by itself after eight seconds.
static NSTask *SpawnHover(NSArray<NSString *> *arguments) {
    NSTask *task=[NSTask new];task.executableURL=[NSURL fileURLWithPath:NSBundle.mainBundle.executablePath];task.arguments=arguments;
    NSError *error=nil;return [task launchAndReturnError:&error]?task:nil;
}
static NSTask *(*HoverSpawner)(NSArray<NSString *> *)=SpawnHover;
- (void)showHover {
    if(self.hoverTask||self.panel.visible)return;
    NSScreen *screen=nil;NSRect anchor=[self iconAnchor:&screen];NSRect area=screen.visibleFrame;
    NSMutableArray *arguments=[@[@"--hover",@(NSMidX(anchor)).stringValue,@(NSMaxY(area)).stringValue,@(NSMinX(area)).stringValue,@(NSMaxX(area)).stringValue]mutableCopy];
    [arguments addObjectsFromArray:self.hoverLines];
    self.hoverTask=HoverSpawner(arguments);
    [self performSelector:@selector(hideHover) withObject:nil afterDelay:8];
}
- (void)hideHover {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(showHover) object:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideHover) object:nil];
    [self.hoverTask terminate];self.hoverTask=nil;
}
// Child process side: builds the label window (native Liquid Glass, or an opaque card under
// Reduce Transparency) centered under `midX`, below `top`, clamped to [minX, maxX].
- (NSPanel *)makeHoverWindow:(NSArray<NSString *> *)lines midX:(CGFloat)midX top:(CGFloat)top minX:(CGFloat)minX maxX:(CGFloat)maxX {
    NSMutableArray *labels=[NSMutableArray array];CGFloat width=0,height=20;
    for(NSUInteger i=0;i<lines.count;i++) {
        NSTextField *label=[NSTextField labelWithString:lines[i]];
        // Apple's own text styles (SF at the system sizes) rather than hand-picked sizes.
        label.font=[NSFont preferredFontForTextStyle:i==0?NSFontTextStyleHeadline:i==1?NSFontTextStyleBody:NSFontTextStyleSubheadline options:@{}];
        label.textColor=i==2?NSColor.secondaryLabelColor:NSColor.labelColor;[label sizeToFit];
        width=fmax(width,label.frame.size.width);height+=label.frame.size.height+(i?1:0);[labels addObject:label];
    }
    width+=28;
    NSPanel *window=[[NSPanel alloc]initWithContentRect:NSMakeRect(0,0,width,height) styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
    window.backgroundColor=NSColor.clearColor;window.opaque=NO;window.hasShadow=NO;window.level=NSPopUpMenuWindowLevel;window.ignoresMouseEvents=YES;window.hidesOnDeactivate=NO;
    NSView *content=[[NSView alloc]initWithFrame:NSMakeRect(0,0,width,height)];
    if(!ReduceTransparency()) {
        NSGlassEffectView *glass=[[NSGlassEffectView alloc]initWithFrame:NSMakeRect(0,0,width,height)];
        glass.cornerRadius=14;glass.contentView=content;window.contentView=glass;window.hasShadow=YES;
    } else {
        BOOL dark=[[NSApp.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]]isEqual:NSAppearanceNameDarkAqua];
        content.wantsLayer=YES;window.contentView=content;
        content.layer.cornerRadius=14;content.layer.borderWidth=1;
        content.layer.backgroundColor=[NSColor colorWithWhite:dark?.16:.98 alpha:1].CGColor;
        content.layer.borderColor=[NSColor colorWithWhite:1 alpha:dark?.23:.66].CGColor;
    }
    CGFloat y=height-10;
    for(NSTextField *label in labels){y-=label.frame.size.height;[label setFrameOrigin:NSMakePoint(14,y)];[content addSubview:label];y-=1;}
    [window setFrameOrigin:NSMakePoint(fmin(fmax(midX-width/2,minX+8),fmax(minX+8,maxX-width-8)),top-height-6)];
    [window orderFrontRegardless];
    return window;
}
- (void)runHoverChild:(NSArray<NSString *> *)arguments { // arguments: midX top minX maxX line1 line2 line3
    self.hoverWindow=[self makeHoverWindow:[arguments subarrayWithRange:NSMakeRange(4,arguments.count-4)] midX:arguments[0].doubleValue top:arguments[1].doubleValue minX:arguments[2].doubleValue maxX:arguments[3].doubleValue];
    [NSApp performSelector:@selector(terminate:) withObject:nil afterDelay:8];
}

// Where the menu bar icon is on screen, and which screen it is on.
- (NSRect)iconAnchor:(NSScreen **)screenOut {
    NSButton *button=self.item.button;NSRect anchor=[button.window convertRectToScreen:[button convertRect:button.bounds toView:nil]];
    NSScreen *screen=button.window.screen?:NSScreen.mainScreen;
    NSPoint pointer=NSEvent.mouseLocation;
    // Hosted status items may expose a placeholder frame before their first click.
    if(anchor.size.width<=1 || !NSIntersectsRect(anchor,screen.frame) || NSMaxY(anchor)<NSMaxY(screen.visibleFrame)) {
        for(NSScreen *candidate in NSScreen.screens)if(NSPointInRect(pointer,candidate.frame)){screen=candidate;break;}
        anchor=NSMakeRect(pointer.x-11,NSMaxY(screen.visibleFrame),22,22);
    }
    *screenOut=screen;return anchor;
}
- (void)openPanel:(BOOL)refreshing {
    if(self.panel.visible)return;
    [self hideHover];
    self.generation++;
    if(!self.panel)[self makePanel];
    NSButton *button=self.item.button;NSScreen *screen=nil;NSRect anchor=[self iconAnchor:&screen];
    CGFloat x=fmin(fmax(NSMidX(anchor)-PanelWidth/2,NSMinX(screen.visibleFrame)+8),NSMaxX(screen.visibleFrame)-PanelWidth-8);
    [self.panel setFrameOrigin:NSMakePoint(x,NSMaxY(screen.visibleFrame)-PanelHeight-6)];
    self.view.needsDisplay=YES;
    [self.panel makeKeyAndOrderFront:nil];
    [self.panel makeFirstResponder:self.view.toggle.acceptsFirstResponder?self.view.toggle:nil];
    BOOL backdrop=ApplyBackdrop(self.panel);
    if(self.profiling||self.verifying){printf("Native backdrop: %s (window %ld, error %d)\n",backdrop?"confirmed":"unavailable",(long)self.panel.windowNumber,LastBlurError);fflush(stdout);}
    if(!backdrop && self.panel.contentView==self.view) {
        NSVisualEffectView *fallback=[[NSVisualEffectView alloc]initWithFrame:self.view.bounds];
        fallback.material=NSVisualEffectMaterialPopover;fallback.blendingMode=NSVisualEffectBlendingModeBehindWindow;fallback.state=NSVisualEffectStateActive;
        self.panel.contentView=fallback;[fallback addSubview:self.view];
    }
    [button highlight:YES];
    __weak AutoApp *weakSelf=self;
    self.globalMonitor=[NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown|NSEventMaskRightMouseDown handler:^(NSEvent *e){(void)e;[weakSelf closePanel:nil];}];
    self.localMonitor=[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown|NSEventMaskRightMouseDown|NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event){
        if(event.type==NSEventTypeKeyDown && event.keyCode==53){[weakSelf closePanel:nil];return nil;}
        if(event.type!=NSEventTypeKeyDown && event.window!=weakSelf.panel && event.window!=weakSelf.item.button.window)[weakSelf closePanel:nil];return event;
    }];
    if(refreshing)[self refresh];
}
- (void)closePanel:(id)sender {
    (void)sender;[self.panel orderOut:nil];[self.item.button highlight:NO];
    if(self.globalMonitor){[NSEvent removeMonitor:self.globalMonitor];self.globalMonitor=nil;}
    if(self.localMonitor){[NSEvent removeMonitor:self.localMonitor];self.localMonitor=nil;}
    // The window and its drawing surface are the app's largest allocation; free them while idle.
    // Deferred so a control that closed the panel from its own event handler finishes first.
    NSInteger generation=++self.generation;
    if(!self.retainPanel)dispatch_async(dispatch_get_main_queue(),^{if(generation==self.generation){self.panel=nil;self.view=nil;malloc_zone_pressure_relief(NULL,0);}});
}
- (void)openSettings:(id)sender { (void)sender;[self closePanel:nil];[[NSWorkspace sharedWorkspace]openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.Displays-Settings.extension"]]; }
- (void)quit:(id)sender { (void)sender;[self closePanel:nil];[NSApp terminate:nil]; }

#pragma mark - Verification (--verify changes the real setting and always restores it; --profile only reads)
- (void)sample { double current=Footprint(),value=fmax(current,KernelPeak);if(value>self.peak)self.peak=value; }
- (void)whenIdle:(dispatch_block_t)block { [self whenIdle:block remaining:100]; }
- (void)whenIdle:(dispatch_block_t)block remaining:(int)remaining {
    if(self.finished)return;
    if(!self.busy){[self sample];block();return;}
    if(remaining<=0){self.failed=YES;fputs("Timed out waiting for macOS.\n",stderr);[self finishVerification];return;}
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,50*NSEC_PER_MSEC),dispatch_get_main_queue(),^{[self whenIdle:block remaining:remaining-1];});
}
- (void)profileOpen {
    printf("Profile idle %.3f MB\n",Footprint());[self togglePanel:nil];
    [self whenIdle:^{printf("Panel open %.3f MB\n",Footprint());fflush(stdout);[self performSelector:@selector(profileCycle) withObject:nil afterDelay:1];}];
}
- (void)profileCycle {
    if(self.cycle++==5){[self finishVerification];return;}
    [self closePanel:nil];[self togglePanel:nil];
    [self whenIdle:^{[self performSelector:@selector(profileCycle) withObject:nil afterDelay:1];}];
}
- (BOOL)independentRead:(BOOL *)value {
    return ReadAuto(FindDisplay(),value,NULL)==nil;
}
- (void)beginVerification {
    printf("Idle: %.3f MB\n",Footprint());fflush(stdout);
    // The hover label is a real child process: it must start, stay up, and stop on request.
    [self showHover];sleep(1);BOOL up=self.hoverTask.isRunning;[self hideHover];
    printf("hover child: %s; footprint %.3f MB\n",up?"started":"FAILED to start",Footprint());if(!up)self.failed=YES;
    [self togglePanel:nil];
    [self whenIdle:^{
        BOOL value=NO;NSString *issue=ReadAuto(FindDisplay(),&value,NULL);
        if(issue){fprintf(stderr,"Verification unavailable: %s\n",issue.UTF8String);self.failed=YES;[self finishVerification];return;}
        self.originalCaptured=YES;self.original=value;self.expected=value;self.originalDisplay=FindDisplay();
        // Restore on any ordinary termination signal as well as on normal exit.
        NSMutableArray *sources=[NSMutableArray array];
        for(NSNumber *sig in @[@SIGINT,@SIGTERM,@SIGHUP]) {
            signal(sig.intValue,SIG_IGN);
            dispatch_source_t s=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,sig.intValue,0,dispatch_get_main_queue());
            dispatch_source_set_event_handler(s,^{self.failed=YES;[self finishVerification];});dispatch_resume(s);[sources addObject:s];
        }
        self.signalSources=sources;
        printf("Original: automatic brightness %s; panel=%s; window=%ld\n",value?"on":"off",NSStringFromRect(self.panel.frame).UTF8String,(long)self.panel.windowNumber);fflush(stdout);
        [self.panel makeKeyWindow];[self.panel makeFirstResponder:self.view.toggle];
        [self verificationStep];
    }];
}
- (void)pressSpace {
    NSEvent *space=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:self.panel.windowNumber context:nil characters:@" " charactersIgnoringModifiers:@" " isARepeat:NO keyCode:49];
    [self.panel sendEvent:space];
}
- (void)verificationStep {
    if(self.finished)return;
    if(self.cycle==8) { [self busyGuardCheck];return; }
    // Alternate keyboard events and accessibility presses in the panel, then direct menu bar clicks.
    BOOL direct=self.cycle>=6;
    if(direct){[self closePanel:nil];[self.item.button performClick:nil];}
    else if(self.cycle%2==0)[self pressSpace];else [self.view.toggle accessibilityPerformPress];
    self.expected=!self.expected;
    [self whenIdle:^{
        BOOL actual=NO;BOOL read=[self independentRead:&actual];
        BOOL shown=direct?self.iconState==(self.expected?AutoOn:AutoOff):self.view.toggle.on==self.expected&&!self.view.message;
        BOOL ok=read&&actual==self.expected&&shown;
        if(!ok)self.failed=YES;
        printf("%s %d (%s): %s; %.3f MB\n",direct?"menu bar click":self.cycle%2==0?"keyboard":"accessibility",self.cycle,self.expected?"on":"off",ok?"verified by independent read":"FAILED",Footprint());fflush(stdout);
        if(!ok)printf("  detail: read=%d actual=%d expected=%d shown=%d panel=%d view=%d message=%s\n",read,actual,self.expected,shown,self.panel!=nil,self.view!=nil,self.view.message.UTF8String?:"none");
        self.cycle++;
        if(self.cycle<=6){[self closePanel:nil];[self togglePanel:nil];}
        [self whenIdle:^{[self.panel makeKeyWindow];[self.panel makeFirstResponder:self.view.toggle];[self performSelector:@selector(verificationStep) withObject:nil afterDelay:.5];}];
    }];
}
// A second change requested while one is in flight must be ignored.
- (void)busyGuardCheck {
    if(self.finished)return;
    NSInteger before=self.writes;BOOL target=self.iconState!=AutoOn;
    [self change:NO to:target];[self change:NO to:!target];[self change:YES to:NO];[self.view.toggle accessibilityPerformPress];
    if(self.writes!=before+1){self.failed=YES;puts("FAILED: duplicate writes were accepted while busy.");}
    [self whenIdle:^{
        BOOL actual=NO;BOOL ok=[self independentRead:&actual]&&actual==target&&self.writes==before+1;
        if(!ok)self.failed=YES;
        printf("busy guard: %s\n",ok?"PASS":"FAILED");[self finishVerification];
    }];
}
- (void)restoreOriginal {
    if(!self.originalCaptured)return;
    __block NSString *issue=nil;
    dispatch_sync(self.queue,^{issue=WriteAuto(self.originalDisplay,self.original);}); // waits for any in-flight write
    BOOL actual=NO;BOOL ok=!issue&&[self independentRead:&actual]&&actual==self.original;
    self.originalCaptured=NO;
    if(ok)printf("PASS: original setting restored (%s) and read back independently.\n",self.original?"on":"off");
    else{self.failed=YES;fprintf(stderr,"RESTORE FAILED: %s\n",issue.UTF8String?:"readback differs");}
}
- (void)finishVerification {
    if(self.finished)return;
    self.finished=YES;[NSObject cancelPreviousPerformRequestsWithTarget:self];
    [self restoreOriginal];
    if(self.profiling&&getenv("AUTOBRIGHTNESS_HOLD")){ // leave a normal, idle instance running for CPU measurement
        [self closePanel:nil];printf("Holding pid %d\n",getpid());fflush(stdout);return;
    }[self closePanel:nil];[self sample];Footprint();
    printf("After use: %.3f MB; kernel lifetime peak: %.3f MB; 8.00 MB target: %s\n",Footprint(),KernelPeak,KernelPeak<8?"PASS":"FAIL");fflush(stdout);
    if(KernelPeak>=8)self.failed=YES;
    [NSApp stop:nil];
    [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0]atStart:NO];
}
@end

int main(int argc,const char **argv) {
    @autoreleasepool {
        if(argc==2 && strcmp(argv[1],"--diagnose")==0) {
            BOOL enabled=NO,unsupported=NO;NSString *issue=LoadSystemBackend()?:ReadAuto(FindDisplay(),&enabled,&unsupported);
            if(issue){fprintf(stderr,"%s: %s\n",unsupported?"Unsupported":"Error",issue.UTF8String);return 1;}
            printf("Automatic brightness: %s\n",enabled?"on":"off");return 0;
        }
        if(argc>=9 && strcmp(argv[1],"--hover")==0) { // label child: no lock, no status item
            NSMutableArray *arguments=[NSMutableArray array];
            for(int i=2;i<argc;i++)[arguments addObject:[NSString stringWithUTF8String:argv[i]]];
            NSApplication *app=NSApplication.sharedApplication;[app setActivationPolicy:NSApplicationActivationPolicyAccessory];
            AutoApp *delegate=[AutoApp new];delegate.hoverArguments=arguments;app.delegate=delegate;[app run];return 0;
        }
        BOOL verify=argc==2 && strcmp(argv[1],"--verify")==0;
        BOOL profile=argc==2 && strcmp(argv[1],"--profile")==0;
        if(argc!=1 && !verify && !profile){fprintf(stderr,"Usage: AutoBrightness [--diagnose | --profile | --verify (changes and restores the real setting)]\n");return 2;}
        NSString *lockPath=[NSTemporaryDirectory()stringByAppendingPathComponent:@"local.amogh.AutoBrightness.lock"];
        int lock=open(lockPath.fileSystemRepresentation,O_CREAT|O_RDWR|O_CLOEXEC|O_NOFOLLOW,0600);
        if(lock<0){perror("AutoBrightness lock");return 1;}
        if(flock(lock,LOCK_EX|LOCK_NB)!=0){int reason=errno;close(lock);if(reason==EWOULDBLOCK){if(verify||profile){fputs("Another AutoBrightness is running; quit it first.\n",stderr);return 1;}return 0;}errno=reason;perror("AutoBrightness lock");return 1;}
        NSApplication *app;AutoApp *delegate;
        @autoreleasepool { app=NSApplication.sharedApplication;[app setActivationPolicy:NSApplicationActivationPolicyAccessory];delegate=[AutoApp new];delegate.verifying=verify;delegate.profiling=profile;app.delegate=delegate; }
        [app run];return delegate.failed?1:0;
    }
}
