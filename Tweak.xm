#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#import <stdio.h>
#import <objc/runtime.h>
#import <objc/message.h>

@interface SBPIPContainerViewController : UIViewController
- (void)forcePictureInPictureToFrame:(CGRect)frame;
@end

static __weak SBPIPContainerViewController *pfActivePiP = nil;
static NSString * const kLogPath = @"/var/mobile/Library/Logs/PiPFullscreen.log";

static void PFWrite(NSString *message) {
    FILE *f = fopen(kLogPath.UTF8String, "a");
    if (!f) return;
    fprintf(f, "%s\n", message.UTF8String);
    fclose(f);
}

static BOOL PFStatusName(NSString *name) {
    NSString *lower = name.lowercaseString;
    return [lower containsString:@"status"] || [lower containsString:@"bar"] ||
           [lower containsString:@"foreground"] || [lower containsString:@"overlay"];
}

static void PFInspectView(UIView *view, NSUInteger depth, NSUInteger *budget) {
    if (!view || depth > 6 || *budget == 0) return;
    (*budget)--;
    NSString *name = NSStringFromClass([view class]);
    if (PFStatusName(name)) {
        PFWrite([NSString stringWithFormat:@"v0.7 VIEW depth=%lu class=%@ frame=%@ hidden=%d alpha=%.2f",
                 (unsigned long)depth, name, NSStringFromCGRect(view.frame),
                 view.hidden, view.alpha]);
    }
    for (UIView *child in view.subviews) {
        PFInspectView(child, depth + 1, budget);
        if (*budget == 0) break;
    }
}

static void PFDumpMethods(Class cls, NSString *label) {
    if (!cls) { PFWrite([NSString stringWithFormat:@"v0.8 %@ class unavailable", label]); return; }
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = NSStringFromSelector(method_getName(methods[i]));
        NSString *lower = name.lowercaseString;
        if ([lower containsString:@"return"] || [lower containsString:@"restore"] ||
            [lower containsString:@"stop"] || [lower containsString:@"home"] ||
            [lower containsString:@"single"] || [lower containsString:@"tap"] ||
            [lower containsString:@"button"] || [lower containsString:@"close"]) {
            PFWrite([NSString stringWithFormat:@"v0.8 METHOD %@ %@ %s", label, name,
                     method_getTypeEncoding(methods[i])]);
        }
    }
    free(methods);
}

static BOOL PFReturnToApp(void) {
    SBPIPContainerViewController *pip = pfActivePiP;
    if (!pip || !pip.view.window) return NO;
    CGRect bounds = [UIScreen mainScreen].bounds;
    if (!CGRectEqualToRect(pip.view.frame, bounds)) return NO;
    NSArray<NSString *> *names = @[@"returnToApplication", @"returnToApp",
        @"restoreUserInterface", @"returnToAppButtonPressed",
        @"returnToApplicationButtonPressed", @"handleReturnToAppButtonPressed"];
    for (NSString *name in names) {
        SEL sel = NSSelectorFromString(name);
        if (![pip respondsToSelector:sel]) continue;
        NSMethodSignature *sig = [pip methodSignatureForSelector:sel];
        if (!sig || sig.numberOfArguments != 2 || strcmp(sig.methodReturnType, "v") != 0) continue;
        PFWrite([NSString stringWithFormat:@"v0.8 Home -> %@", name]);
        ((void (*)(id, SEL))objc_msgSend)(pip, sel);
        return YES;
    }
    PFWrite(@"v0.8 Home: no verified zero-argument return-to-app selector; using normal Home");
    return NO;
}

static void PFInspectWindows(void) {
    UIApplication *app = [UIApplication sharedApplication];
    NSUInteger scenes = 0, windows = 0;
    PFWrite(@"=== v0.7 STATUS DIAGNOSTICS BEGIN ===");
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        scenes++;
        UIWindowScene *ws = (UIWindowScene *)scene;
        PFWrite([NSString stringWithFormat:@"v0.7 SCENE %@ activation=%ld",
                 NSStringFromClass([scene class]), (long)scene.activationState]);
        for (UIWindow *window in ws.windows) {
            windows++;
            PFWrite([NSString stringWithFormat:@"v0.7 WINDOW class=%@ level=%.1f frame=%@ hidden=%d alpha=%.2f root=%@",
                     NSStringFromClass([window class]), window.windowLevel,
                     NSStringFromCGRect(window.frame), window.hidden, window.alpha,
                     window.rootViewController ? NSStringFromClass([window.rootViewController class]) : @"nil"]);
            NSUInteger budget = 250;
            PFInspectView(window, 0, &budget);
        }
    }
    PFWrite([NSString stringWithFormat:@"=== v0.7 STATUS DIAGNOSTICS END scenes=%lu windows=%lu ===",
             (unsigned long)scenes, (unsigned long)windows]);
}

%hook SBPIPContainerViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    __weak SBPIPContainerViewController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        SBPIPContainerViewController *controller = weakSelf;
        if (!controller || !controller.view.window) return;
        CGRect screen = [UIScreen mainScreen].bounds;
        PFWrite([NSString stringWithFormat:@"v0.7 forcing PiP frame %@", NSStringFromCGRect(screen)]);
        [controller forcePictureInPictureToFrame:screen];
        PFWrite([NSString stringWithFormat:@"v0.7 resulting view frame %@", NSStringFromCGRect(controller.view.frame)]);
        pfActivePiP = controller;
        PFInspectWindows();
        PFDumpMethods([controller class], @"PiPContainer");
    });
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    if (pfActivePiP == self) pfActivePiP = nil;
}

%end

%hook SBHomeHardwareButtonActions

- (void)performSinglePressUp {
    if (PFReturnToApp()) return;
    %orig;
}

%end

%ctor {
    @autoreleasepool {
        if ([NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"]) {
            PFWrite(@"PiPFullscreen v0.8 Home-to-app experiment loaded");
            PFDumpMethods(NSClassFromString(@"SBHomeHardwareButtonActions"), @"HomeActions");
            %init;
        }
    }
}
