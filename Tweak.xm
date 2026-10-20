#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#import <stdio.h>
#import <unistd.h>
#import <notify.h>
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
    [button sendActionsForControlEvents:UIControlEventTouchUpInside];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(500 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{ pfRestoreInProgress = NO; });
    return YES;
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


static void PF29AppStatus(NSString *phase) {
    UIApplication *app=[UIApplication sharedApplication];
    NSUInteger sceneCount=0,windowCount=0,statusViews=0;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        sceneCount++;
        UIWindowScene *ws=(UIWindowScene *)scene;
        UIStatusBarManager *manager=ws.statusBarManager;
        PFWrite([NSString stringWithFormat:@"v0.29 HONGGUO %@ scene=%ld statusHidden=%d statusFrame=%@",
            phase,(long)scene.activationState,manager.statusBarHidden,NSStringFromCGRect(manager.statusBarFrame)]);
        for (UIWindow *w in ws.windows) {
            windowCount++;
            NSMutableArray *stack=[NSMutableArray arrayWithObject:w];
            NSUInteger budget=1200;
            while (stack.count && budget--) {
                UIView *v=stack.lastObject; [stack removeLastObject];
                NSString *name=NSStringFromClass([v class]);
                if ([name.lowercaseString containsString:@"statusbar"]) {
                    statusViews++;
                    if (statusViews<=12) PFWrite([NSString stringWithFormat:@"v0.29 HONGGUO VIEW %@ window=%@ windowHidden=%d viewHidden=%d",
                        name,NSStringFromClass([w class]),w.hidden,v.hidden]);
                }
                [stack addObjectsFromArray:v.subviews];
            }
        }
    }
    PFWrite([NSString stringWithFormat:@"v0.29 HONGGUO SUMMARY %@ scenes=%lu windows=%lu statusViews=%lu",
        phase,(unsigned long)sceneCount,(unsigned long)windowCount,(unsigned long)statusViews]);
}


static NSString *PF37ProbePath(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"pipfullscreen-v037-diagnostic.txt"];
}
static void PF37Log(NSString *line) {
    NSString *path = PF37ProbePath();
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!h) {
        [[NSData data] writeToFile:path atomically:YES];
        h = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    if (h) {
        @try {
            [h seekToEndOfFile];
            [h writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
            [h closeFile];
        } @catch (NSException *e) {}
    }
}
static BOOL pf37AppPiPActive = NO;
static const char *pf37Signal = "com.qqrush.pipfullscreen.pipstate";
static void PF37Publish(BOOL active) {
    uint64_t value = active ? 1 : 0;
    int token = 0;
    if (notify_register_check(pf37Signal, &token) == NOTIFY_STATUS_OK) {
        notify_set_state(token, value);
        notify_post(pf37Signal);
        notify_cancel(token);
    }
}
%group PF37AppDiagnostics
%hook UIApplicationSceneClientSettings
- (BOOL)statusBarHidden {
    BOOL original = %orig;
    static NSUInteger calls=0;
    if (++calls<=30 || pf37AppPiPActive)
        PF37Log([NSString stringWithFormat:@"app statusBarHidden call=%lu original=%d pip=%d", (unsigned long)calls,original,pf37AppPiPActive]);
    return original;
}
%end
%hook UIStatusBarStyleAttributes
- (double)foregroundAlpha {
    double original = %orig;
    static NSUInteger calls=0;
    if (++calls<=30 || pf37AppPiPActive)
        PF37Log([NSString stringWithFormat:@"app foregroundAlpha call=%lu original=%.3f pip=%d",(unsigned long)calls,original,pf37AppPiPActive]);
    return original;
}
%end
%end

// v0.33: arm scene status before PiP presentation and fullscreen sizing.
static __weak SBPIPContainerViewController *pf33PendingPiP = nil;
static BOOL PF33StatusArmed(void) {
    return pf33PendingPiP != nil || pfActivePiP != nil;
}

// v0.34: combine two confirmed HideBar methods under the same PiP gate.
%hook UIStatusBarStyleAttributes
- (double)foregroundAlpha {
    double original = %orig;
    BOOL armed = PF33StatusArmed();
    static NSUInteger calls = 0;
    if (calls++ < 100) PFWrite([NSString stringWithFormat:@"v0.34 foregroundAlpha call=%lu original=%.3f armed=%d", (unsigned long)calls, original, armed]);
    return armed ? 0.0 : original;
}
%end

%hook UIApplicationSceneClientSettings
- (BOOL)statusBarHidden {
    BOOL original = %orig;
    BOOL armed = PF33StatusArmed();
    static NSUInteger calls = 0;
    if (calls++ < 100) PFWrite([NSString stringWithFormat:@"v0.34 statusBarHidden call=%lu original=%d armed=%d", (unsigned long)calls, original, armed]);
    return armed ? YES : original;
}
%end

%hook SBPIPContainerViewController

- (void)viewWillAppear:(BOOL)animated {
    pf33PendingPiP = self;
    PFWrite(@"v0.34 armed before viewWillAppear");
    %orig;
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    __weak SBPIPContainerViewController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        SBPIPContainerViewController *controller = weakSelf;
        if (!controller || !controller.view.window) { if (pf33PendingPiP == controller) pf33PendingPiP = nil; return; }
        CGRect screen = [UIScreen mainScreen].bounds;
        PFWrite([NSString stringWithFormat:@"v0.7 forcing PiP frame %@", NSStringFromCGRect(screen)]);
        [controller forcePictureInPictureToFrame:screen];
        PFWrite([NSString stringWithFormat:@"v0.7 resulting view frame %@", NSStringFromCGRect(controller.view.frame)]);
        pfActivePiP = controller;
        PF37Publish(YES);
        PFWrite(@"v0.34 fullscreen active: scene settings + foreground alpha armed");
        PFInspectWindows();
        PFDumpMethods([controller class], @"PiPContainer");
        PFScanControls(controller.view, 0);
        PFWrite(@"v0.11 STATUS diagnostic only; no hiding");
        PFInspectPiPOverlay(controller.view, 0);
    });
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    if (pf33PendingPiP == self) pf33PendingPiP = nil;
    if (pfActivePiP == self) {
        pfActivePiP = nil;
        PF37Publish(NO);
        PFWrite(@"v0.34 fullscreen ended: hooks disarmed");
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
            PFWrite(@"v0.35 SPRINGBOARD ctor reached");
            PFHomeDiagnostics();
            PFDumpMethods(NSClassFromString(@"SBHomeHardwareButtonActions"), @"HomeActions");
            %init;
        } else if ([[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.phoenix.video"]) {
            PF37Log(@"v0.37 Hongguo constructor; diagnostics initializing");
            %init(PF37AppDiagnostics);
            static int pf37NotifyToken=0;
            int pf37Result=notify_register_dispatch(pf37Signal,&pf37NotifyToken,dispatch_get_main_queue(),^(int token) {
                uint64_t value=0;
                int result=notify_get_state(token,&value);
                pf37AppPiPActive=(result==NOTIFY_STATUS_OK && value==1);
                PF37Log([NSString stringWithFormat:@"Darwin signal received result=%d active=%d",result,pf37AppPiPActive]);
            });
            PF37Log([NSString stringWithFormat:@"Darwin listener result=%d token=%d",pf37Result,pf37NotifyToken]);
            NSString *probe = [NSTemporaryDirectory() stringByAppendingPathComponent:@"pipfullscreen-v036-loaded.txt"];
            NSString *payload = [NSString stringWithFormat:@"v0.36 Hongguo injected pid=%d bundle=%@\\n", getpid(), [NSBundle mainBundle].bundleIdentifier];
            BOOL wrote = [payload writeToFile:probe atomically:YES encoding:NSUTF8StringEncoding error:nil];
            NSLog(@"[PiPFullscreen v0.36] Hongguo injected; probe=%@ wrote=%d", probe, wrote);
            PFWrite([NSString stringWithFormat:@"v0.36 HONGGUO probe path=%@ wrote=%d", probe, wrote]);
            PFWrite(@"v0.35 HONGGUO ctor reached");
            NSLog(@"[PiPFullscreen v0.35] HONGGUO ctor reached pid=%d", getpid());
            PFWrite([NSString stringWithFormat:@"v0.35 HONGGUO classes sceneSettings=%d foregroundStyle=%d foregroundView=%d",
                NSClassFromString(@"UIApplicationSceneClientSettings") != Nil,
                NSClassFromString(@"UIStatusBarStyleAttributes") != Nil,
                NSClassFromString(@"_UIStatusBarForegroundView") != Nil]);
            PFWrite(@"v0.29 HONGGUO diagnostics loaded");
            NSNotificationCenter *nc=[NSNotificationCenter defaultCenter];
            [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
                PF29AppStatus(@"ACTIVE");
            }];
            [nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
                PF29AppStatus(@"BACKGROUND");
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ PF29AppStatus(@"BACKGROUND_2S"); });
            }];
        }
    }
}
