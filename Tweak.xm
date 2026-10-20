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
static void PF18Snapshot(NSString *phase);


static void PF20StatusSample(NSString *phase, NSUInteger step) {
    UIApplication *app=[UIApplication sharedApplication];
    NSMutableString *line=[NSMutableString stringWithFormat:@"v0.20 STATUS %@ step=%lu ",phase,(unsigned long)step];
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws=(UIWindowScene *)scene;
        UIStatusBarManager *manager=ws.statusBarManager;
        [line appendFormat:@"scene=%p state=%ld manager=%@ hidden=%d frame=%@; ",
            scene,(long)scene.activationState,NSStringFromClass([manager class]),
            manager.statusBarHidden,NSStringFromCGRect(manager.statusBarFrame)];
    }
    PFWrite(line);
}
static void PF20Trace(NSString *phase) {
    for (NSUInteger i=0;i<=20;i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(i*50*NSEC_PER_MSEC)),
            dispatch_get_main_queue(),^{ PF20StatusSample(phase,i); });
    }
}

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
    PFWrite(@"v0.18 Home restore initiated");
    PF20Trace(@"HOME_RESTORE");
    PF18Snapshot(@"HOME_BEFORE_RESTORE");
    [button sendActionsForControlEvents:UIControlEventTouchUpInside];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(500 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{ pfRestoreInProgress = NO; });
    return YES;
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


static void PF18Snapshot(NSString *phase) {
    PFWrite([NSString stringWithFormat:@"v0.18 SNAPSHOT %@", phase]);
    NSUInteger matches = 0;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            PFWrite([NSString stringWithFormat:@"v0.18 WINDOW %@ level=%.1f hidden=%d alpha=%.2f root=%@",
                NSStringFromClass([window class]), window.windowLevel, window.hidden,
                window.alpha, window.rootViewController ? NSStringFromClass([window.rootViewController class]) : @"nil"]);
            NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
            NSUInteger budget = 3000;
            while (stack.count && budget--) {
                UIView *view = stack.lastObject;
                [stack removeLastObject];
                NSString *name = NSStringFromClass([view class]);
                if ([name containsString:@"StatusBar"] || [name containsString:@"Battery"] ||
                    [name containsString:@"Wifi"] || [name containsString:@"Cellular"]) {
                    matches++;
                    NSMutableArray<NSString *> *ancestors = [NSMutableArray array];
                    UIView *parent = view.superview;
                    for (NSUInteger i=0; parent && i<7; i++,parent=parent.superview) {
                        [ancestors addObject:[NSString stringWithFormat:@"%@{hidden=%d alpha=%.2f}",
                            NSStringFromClass([parent class]),parent.hidden,parent.alpha]];
                    }
                    PFWrite([NSString stringWithFormat:@"v0.18 VIEW %@ ptr=%p hidden=%d alpha=%.2f window=%@ ancestors=%@",
                        name,view,view.hidden,view.alpha,NSStringFromClass([view.window class]),
                        [ancestors componentsJoinedByString:@" <- "]]);
                }
                [stack addObjectsFromArray:view.subviews];
            }
        }
    }
    PFWrite([NSString stringWithFormat:@"v0.18 END %@ matches=%lu",phase,(unsigned long)matches]);
}
static void PF18ScheduleSnapshots(void) {
    PF18Snapshot(@"PIP_FULL_0");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        PF18Snapshot(@"PIP_FULL_100");
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        PF18Snapshot(@"PIP_FULL_500");
    });
}


static void PF19AppSnapshot(NSString *phase) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ PF19AppSnapshot(phase); });
        return;
    }
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/PiPFullscreen-App.log"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableString *log = [NSMutableString stringWithFormat:@"v0.19 APP %@ process=%@ state=%ld\n",phase,NSProcessInfo.processInfo.processName,(long)[UIApplication sharedApplication].applicationState];
    NSMutableArray *windows = [NSMutableArray array];
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
    }
    // iOS 15: inspect scene windows only; UIApplication.windows is deprecated.
    for (UIWindow *window in windows) {
        [log appendFormat:@"WINDOW %@ level=%.1f hidden=%d alpha=%.2f frame=%@\n",NSStringFromClass([window class]),window.windowLevel,window.hidden,window.alpha,NSStringFromCGRect(window.frame)];
        NSMutableArray *stack = [NSMutableArray arrayWithObject:window];
        NSUInteger budget=2000, matches=0;
        while (stack.count && budget--) {
            UIView *v=stack.lastObject;
            [stack removeLastObject];
            NSString *name=NSStringFromClass([v class]);
            NSString *lower=name.lowercaseString;
            if ([lower containsString:@"statusbar"] || [lower containsString:@"battery"] ||
                [lower containsString:@"wifi"] || [lower containsString:@"cellular"] ||
                [lower containsString:@"timeitem"]) {
                if (matches++ < 45) [log appendFormat:@"VIEW %@ rect=%@ hidden=%d alpha=%.2f parent=%@\n",name,NSStringFromCGRect([v convertRect:v.bounds toView:nil]),v.hidden,v.alpha,NSStringFromClass([v.superview class])];
            }
            [stack addObjectsFromArray:v.subviews];
        }
        [log appendFormat:@"MATCHES %lu\n",(unsigned long)matches];
    }
    FILE *f=fopen(path.UTF8String,"a");
    if (f) { fputs(log.UTF8String,f); fclose(f); }
}
static void PF19ScheduleAppSnapshot(NSString *phase) {
    PF19AppSnapshot(phase);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(500*NSEC_PER_MSEC)),dispatch_get_main_queue(),^{ PF19AppSnapshot([phase stringByAppendingString:@"_500ms"]); });
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
        PFWrite(@"v0.18 diagnostics only; status hiding disabled");
        PF18ScheduleSnapshots();
        PF20Trace(@"PIP_FULLSCREEN");
        PFStatusTrace(@"PIP_FULL");
        PFInspectPiPOverlay(controller.view, 0);
    });
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    if (pfActivePiP == self) {
        PFStatusTrace(@"PIP_WILL_DISAPPEAR");
        PF18Snapshot(@"PIP_WILL_DISAPPEAR");
        PF20Trace(@"PIP_DISAPPEAR");
        pfActivePiP = nil;
        pfRestoreInProgress = NO;
        PFWrite(@"v0.12 PiP disappearing");
    }
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
            PFWrite(@"PiPFullscreen v0.20 SpringBoard status transitions diagnostics loaded");
            PFHomeDiagnostics();
            PFDumpMethods(NSClassFromString(@"SBHomeHardwareButtonActions"), @"HomeActions");
            %init;
        } else if ([[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.phoenix.video"]) {
            PF19ScheduleAppSnapshot(@"APP_LAUNCH");
            NSNotificationCenter *nc=[NSNotificationCenter defaultCenter];
            [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note){ PF19ScheduleAppSnapshot(@"BECOME_ACTIVE"); }];
            [nc addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note){ PF19ScheduleAppSnapshot(@"WILL_RESIGN_ACTIVE"); }];
            [nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note){ PF19AppSnapshot(@"ENTER_BACKGROUND"); }];
        }
    }
}
