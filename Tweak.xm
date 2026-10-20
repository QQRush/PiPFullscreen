#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#import <stdio.h>
#import <objc/runtime.h>
#import <objc/message.h>

@interface SBPIPContainerViewController : UIViewController
- (void)forcePictureInPictureToFrame:(CGRect)frame;
@end

static __weak SBPIPContainerViewController *pfActivePiP = nil;
static BOOL pfRestoreInProgress = NO;
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

static void PFScanControls(UIView *view, NSUInteger depth) {
    if (!view || depth > 12) return;
    if ([view isKindOfClass:[UIControl class]]) {
        UIControl *control = (UIControl *)view;
        NSMutableArray *actions = [NSMutableArray array];
        for (id target in control.allTargets) {
            for (NSString *action in [control actionsForTarget:target forControlEvent:UIControlEventTouchUpInside] ?: @[]) {
                [actions addObject:[NSString stringWithFormat:@"%@:%@", NSStringFromClass([target class]), action]];
            }
        }
        PFWrite([NSString stringWithFormat:@"v0.9 CONTROL %@ frame=%@ label=%@ actions=%@",
                 NSStringFromClass([control class]),
                 NSStringFromCGRect([control convertRect:control.bounds toView:nil]),
                 control.accessibilityLabel ?: @"", actions]);
    }
    for (UIView *child in view.subviews) PFScanControls(child, depth + 1);
}

static UIControl *PFRestoreButton(UIView *view, NSUInteger depth) {
    if (!view || depth > 12) return nil;
    if ([view isKindOfClass:[UIControl class]]) {
        UIControl *button = (UIControl *)view;
        CGRect rect = [button convertRect:button.bounds toView:nil];
        CGFloat width = [UIScreen mainScreen].bounds.size.width;
        if (rect.origin.x > width - 55 && rect.origin.y >= 0 &&
            rect.origin.y < 45 && rect.size.width > 15 && rect.size.width < 55) {
            return button;
        }
    }
    for (UIView *child in view.subviews) {
        UIControl *found = PFRestoreButton(child, depth + 1);
        if (found) return found;
    }
    return nil;
}

static void PFStatusTrace(NSString *phase);
static void PFRecordFade(void);

static BOOL PFReturnToApp(void) {
    SBPIPContainerViewController *pip = pfActivePiP;
    if (!pip || !pip.view.window ||
        !CGRectEqualToRect(pip.view.frame, [UIScreen mainScreen].bounds)) {
        PFWrite(@"v0.12 Home: no fullscreen PiP");
        return NO;
    }
    UIControl *button = PFRestoreButton(pip.view, 0);
    if (!button) {
        PFWrite(@"v0.10 Home: top-right restore button not found");
        return NO;
    }
    PFWrite([NSString stringWithFormat:@"v0.10 Home: sending native TouchUpInside to %@",
             NSStringFromClass([button class])]);
    if (pfRestoreInProgress) return YES;
    pfRestoreInProgress = YES;
    PFWrite(@"v0.17 Home restore initiated");
    [button sendActionsForControlEvents:UIControlEventTouchUpInside];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(500 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{ pfRestoreInProgress = NO; });
    return YES;
}



static void PFFadeInspect(UIView *v, NSUInteger depth, NSUInteger *budget, NSUInteger ms) {
    if (!v || depth > 20 || !*budget) return;
    --(*budget);
    NSString *name = NSStringFromClass([v class]);
    BOOL relevant = [name containsString:@"StatusBar"] || [name containsString:@"Battery"] ||
                    [name containsString:@"Wifi"] || [name containsString:@"StatusBarString"] ||
                    [name isEqualToString:@"SBPIPWindow"];
    if (relevant) {
        CALayer *p = v.layer.presentationLayer;
        NSArray *keys = [v.layer animationKeys];
        PFWrite([NSString stringWithFormat:@"v0.16 FADE t=%lums view=%@ win=%@ alpha=%.3f presentation=%.3f hidden=%d layerOpacity=%.3f animations=%@",
                 (unsigned long)ms, name, NSStringFromClass([v.window class]), v.alpha,
                 p ? p.opacity : -1.0, v.hidden, v.layer.opacity, keys ?: @[]]);
    }
    for (UIView *child in v.subviews) PFFadeInspect(child, depth+1, budget, ms);
}
static void PFRecordFade(void) {
    PFWrite(@"v0.16 FADE START home restore");
    for (NSUInteger i=0; i<=24; i++) {
        NSUInteger ms=i*25;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)ms*NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            PFWrite([NSString stringWithFormat:@"v0.16 SAMPLE %lums", (unsigned long)ms]);
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (w.windowLevel > 0 || [NSStringFromClass([w class]) containsString:@"MainDisplay"] ||
                        [NSStringFromClass([w class]) isEqualToString:@"UIWindow"]) {
                        CALayer *p=w.layer.presentationLayer;
                        PFWrite([NSString stringWithFormat:@"v0.16 WINDOW t=%lums %@ hidden=%d alpha=%.3f presentation=%.3f level=%.1f",
                                 (unsigned long)ms, NSStringFromClass([w class]), w.hidden, w.alpha,
                                 p ? p.opacity : -1.0, w.windowLevel]);
                        NSUInteger budget=1800;
                        PFFadeInspect(w, 0, &budget, ms);
                    }
                }
            }
        });
    }
}

static void PFStatusTraceView(UIView *view, NSUInteger depth, NSUInteger *remaining) {
    if (!view || depth > 18 || *remaining == 0) return;
    (*remaining)--;
    NSString *name = NSStringFromClass([view class]);
    if (PFStatusName(name) || [name containsString:@"StatusBar"] ||
        [name containsString:@"Battery"] || [name containsString:@"Cellular"] ||
        [name containsString:@"Wifi"] || [name containsString:@"TimeItem"]) {
        CGRect rect = [view convertRect:view.bounds toView:nil];
        PFWrite([NSString stringWithFormat:@"v0.14 STATUSVIEW %@ rect=%@ hidden=%d alpha=%.3f super=%@ window=%@",
                 name, NSStringFromCGRect(rect), view.hidden, view.alpha,
                 view.superview ? NSStringFromClass([view.superview class]) : @"nil",
                 view.window ? NSStringFromClass([view.window class]) : @"nil"]);
    }
    for (UIView *child in view.subviews) PFStatusTraceView(child, depth + 1, remaining);
}
static void PFStatusTrace(NSString *phase) {
    PFWrite([NSString stringWithFormat:@"v0.14 TRACE %@", phase]);
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            NSUInteger remaining = 1200;
            PFStatusTraceView(window, 0, &remaining);
        }
    }
}

static void PFInspectPiPOverlay(UIView *view, NSUInteger depth) {
    if (!view || depth > 8) return;
    CGRect rect = [view convertRect:view.bounds toView:nil];
    NSString *name = NSStringFromClass([view class]);
    if (rect.origin.y < 65 && rect.size.height > 0 && rect.size.width > 0 &&
        (depth < 4 || PFStatusName(name) || [name containsString:@"Label"])) {
        PFWrite([NSString stringWithFormat:@"v0.11 OVERLAY depth=%lu class=%@ frame=%@ hidden=%d alpha=%.2f",
                 (unsigned long)depth, name, NSStringFromCGRect(rect), view.hidden, view.alpha]);
    }
    for (UIView *child in view.subviews) PFInspectPiPOverlay(child, depth + 1);
}

static void PFHomeDiagnostics(void) {
    NSArray<NSString *> *classes = @[@"SBHomeHardwareButtonActions", @"SBHomeHardwareButton",
      @"SBHomeButtonController", @"SBHardwareButtonService", @"SBHomeButtonPress", @"SBPressGestureRecognizer",
      @"SBHomeHardwareButtonGestureRecognizer", @"SBHardwareButtonGestureRecognizer"];
    for (NSString *name in classes) {
        Class cls = NSClassFromString(name);
        PFWrite([NSString stringWithFormat:@"v0.11 HOME CLASS %@ exists=%d", name, cls != Nil]);
        if (!cls) continue;
        for (Class cursor = cls; cursor && cursor != [NSObject class]; cursor = class_getSuperclass(cursor)) {
            unsigned int count = 0;
            Method *methods = class_copyMethodList(cursor, &count);
            for (unsigned int i = 0; i < count; i++) {
                NSString *selector = NSStringFromSelector(method_getName(methods[i]));
                NSString *lower = selector.lowercaseString;
                if ([lower containsString:@"press"] || [lower containsString:@"home"] ||
                    [lower containsString:@"click"] || [lower containsString:@"tap"]) {
                    PFWrite([NSString stringWithFormat:@"v0.11 HOME METHOD %@ %@ %s",
                             NSStringFromClass(cursor), selector, method_getTypeEncoding(methods[i])]);
                }
            }
            free(methods);
        }
    }
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
        PFScanControls(controller.view, 0);
        PFWrite(@"v0.17 status bar frame hook active");
        PFStatusTrace(@"PIP_FULL");
        PFInspectPiPOverlay(controller.view, 0);
    });
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    if (pfActivePiP == self) {
        PFStatusTrace(@"PIP_WILL_DISAPPEAR");
        // Restore status bar views before the PiP session ends.
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
                while (stack.count) {
                    UIView *view = stack.lastObject;
                    [stack removeLastObject];
                    if ([NSStringFromClass([view class]) isEqualToString:@"_UIStatusBar"] && view.hidden) view.hidden = NO;
                    [stack addObjectsFromArray:view.subviews];
                }
            }
        }
        pfActivePiP = nil;
        pfRestoreInProgress = NO;
        PFWrite(@"v0.12 PiP disappearing");
    }
}

%end


// Springlicious-inspired status bar layout hook, scoped to fullscreen PiP.
%hook _UIStatusBar
- (CGRect)frame {
    CGRect original = %orig;
    SBPIPContainerViewController *pip = pfActivePiP;
    if (pip && pip.view.window &&
        CGRectEqualToRect(pip.view.frame, [UIScreen mainScreen].bounds)) {
        if (!self.hidden) {
            PFWrite(@"v0.17 _UIStatusBar frame hook: hiding during fullscreen PiP");
            self.hidden = YES;
        }
    }
    return original;
}
%end

%hook SBHomeHardwareButtonActions

- (void)performSinglePressUpActions {
    PFWrite(@"v0.12 HOME EVENT performSinglePressUpActions");
    if (PFReturnToApp()) return;
    %orig;
}

- (void)performSinglePressUpActionsWithSourceType:(NSUInteger)sourceType {
    PFWrite([NSString stringWithFormat:@"v0.12 HOME EVENT performSinglePressUpActionsWithSourceType:%lu", (unsigned long)sourceType]);
    if (PFReturnToApp()) return;
    %orig;
}

%end

%ctor {
    @autoreleasepool {
        if ([NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"]) {
            PFWrite(@"PiPFullscreen v0.17 status frame hook loaded");
            PFHomeDiagnostics();
            PFDumpMethods(NSClassFromString(@"SBHomeHardwareButtonActions"), @"HomeActions");
            %init;
        }
    }
}
