#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#import <stdio.h>

@interface SBPIPContainerViewController : UIViewController
- (void)forcePictureInPictureToFrame:(CGRect)frame;
@end

static NSString * const kLogPath = @"/var/mobile/Library/Logs/PiPFullscreen.log";
static NSMapTable<UIWindow *, NSNumber *> *savedStatusWindows;
static NSUInteger activePiPCount = 0;

static void PFWrite(NSString *message) {
    FILE *f = fopen(kLogPath.UTF8String, "a");
    if (!f) return;
    fprintf(f, "%s\n", message.UTF8String);
    fclose(f);
}

// Only touch SpringBoard's own status-bar windows; remember their original state.
static void PFSetStatusBarHidden(BOOL hide) {
    if (!savedStatusWindows) savedStatusWindows = [NSMapTable weakToStrongObjectsMapTable];
    Class statusClass = NSClassFromString(@"UIStatusBarWindow");
    if (hide) {
        NSUInteger count = 0;
        for (UIWindow *window in [UIApplication sharedApplication].windows) {
            if (!statusClass || ![window isKindOfClass:statusClass]) continue;
            if (![savedStatusWindows objectForKey:window]) {
                [savedStatusWindows setObject:@(window.hidden) forKey:window];
            }
            window.hidden = YES;
            count++;
        }
        PFWrite([NSString stringWithFormat:@"v0.6 hide status-bar windows: %lu", (unsigned long)count]);
    } else {
        for (UIWindow *window in savedStatusWindows) {
            NSNumber *previous = [savedStatusWindows objectForKey:window];
            if (previous) window.hidden = previous.boolValue;
        }
        [savedStatusWindows removeAllObjects];
        PFWrite(@"v0.6 restored status-bar windows");
    }
}

%hook SBPIPContainerViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    activePiPCount++;
    __weak SBPIPContainerViewController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        SBPIPContainerViewController *controller = weakSelf;
        if (!controller || !controller.view.window || activePiPCount == 0) return;
        CGRect screen = [UIScreen mainScreen].bounds;
        PFWrite([NSString stringWithFormat:@"v0.6 forcing PiP frame %@", NSStringFromCGRect(screen)]);
        [controller forcePictureInPictureToFrame:screen];
        PFWrite([NSString stringWithFormat:@"v0.6 resulting view frame %@", NSStringFromCGRect(controller.view.frame)]);
        PFSetStatusBarHidden(YES);
    });
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    if (activePiPCount > 0) activePiPCount--;
    if (activePiPCount == 0) PFSetStatusBarHidden(NO);
}

%end

%ctor {
    @autoreleasepool {
        if ([NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"]) {
            PFWrite(@"PiPFullscreen v0.6 status bar experiment loaded");
            %init;
        }
    }
}
