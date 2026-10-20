#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>

@interface SBPIPContainerViewController : UIViewController
- (void)forcePictureInPictureToFrame:(CGRect)frame;
@end

// v0.46 experiment: v0.42 fullscreen/Home, foreground-only status control.
static __weak SBPIPContainerViewController *pfActivePiP = nil;
static __weak SBPIPContainerViewController *pfPendingPiP = nil;
static BOOL pfRestoreInProgress = NO;
static NSMapTable<UIView *, NSNumber *> *pfOriginalHidden;

static BOOL PFStatusArmed(void) {
    return pfPendingPiP != nil || pfActivePiP != nil;
}

static void PFSetForegroundHidden(UIView *view, BOOL active) {
    if (!view) return;
    if (!pfOriginalHidden)
        pfOriginalHidden = [NSMapTable weakToStrongObjectsMapTable];
    NSNumber *saved = [pfOriginalHidden objectForKey:view];
    if (active) {
        if (!saved) [pfOriginalHidden setObject:@(view.hidden) forKey:view];
        view.hidden = YES;
    } else if (saved) {
        view.hidden = saved.boolValue;
        [pfOriginalHidden removeObjectForKey:view];
    }
}

static void PFRestoreForeground(void) {
    for (UIView *view in pfOriginalHidden.keyEnumerator.allObjects)
        PFSetForegroundHidden(view, NO);
}

// Refresh the foreground views on both PiP transitions, without waiting
// for a clock-triggered layout pass. Never touch other status-bar internals.
static void PFRefreshStatusForeground(BOOL hide) {
    Class foregroundClass = NSClassFromString(@"_UIStatusBarForegroundView");
    if (!foregroundClass) return;
    UIApplication *app = [UIApplication sharedApplication];
    NSMutableArray<UIWindow *> *windows = [NSMutableArray arrayWithArray:app.windows];
    for (UIScene *scene in app.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]])
            [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
    }
    for (UIWindow *window in windows) {
        NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
        NSUInteger budget = 10000;
        while (stack.count && budget--) {
            UIView *view = stack.lastObject;
            [stack removeLastObject];
            if ([view isKindOfClass:foregroundClass])
                PFSetForegroundHidden(view, hide);
            [stack addObjectsFromArray:view.subviews];
        }
    }
}

static UIControl *PFRestoreButton(UIView *view, NSUInteger depth) {
    if (!view || depth > 12) return nil;
    if ([view isKindOfClass:[UIControl class]]) {
        UIControl *button = (UIControl *)view;
        CGRect rect = [button convertRect:button.bounds toView:nil];
        CGFloat width = [UIScreen mainScreen].bounds.size.width;
        if (rect.origin.x > width - 55 && rect.origin.y >= 0 &&
            rect.origin.y < 45 && rect.size.width > 15 && rect.size.width < 55)
            return button;
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
        !CGRectEqualToRect(pip.view.frame, [UIScreen mainScreen].bounds))
        return NO;
    UIControl *button = PFRestoreButton(pip.view, 0);
    if (!button) return NO;
    if (pfRestoreInProgress) return YES;
    pfRestoreInProgress = YES;
    [button sendActionsForControlEvents:UIControlEventTouchUpInside];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(500 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{ pfRestoreInProgress = NO; });
    return YES;
}

// Proven HideBar-style foreground hook, active only while PiP is presented.
%hook _UIStatusBarForegroundView
- (void)layoutSubviews {
    %orig;
    PFSetForegroundHidden((UIView *)self, PFStatusArmed());
}
%end

%hook SBPIPContainerViewController
- (void)viewWillAppear:(BOOL)animated {
    pfPendingPiP = self;
    %orig;
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    __weak SBPIPContainerViewController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        SBPIPContainerViewController *controller = weakSelf;
        if (!controller || !controller.view.window) {
            if (pfPendingPiP == controller) pfPendingPiP = nil;
            return;
        }
        [controller forcePictureInPictureToFrame:[UIScreen mainScreen].bounds];
        pfActivePiP = controller;
        PFRefreshStatusForeground(YES);
    });
}
- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    if (pfPendingPiP == self) pfPendingPiP = nil;
    if (pfActivePiP == self) {
        pfActivePiP = nil;
        PFRefreshStatusForeground(NO);
        PFRestoreForeground();
        pfRestoreInProgress = NO;
    }
}
%end

%hook SBHomeHardwareButtonActions
- (void)performSinglePressUpActions {
    if (PFReturnToApp()) return;
    %orig;
}
- (void)performSinglePressUpActionsWithSourceType:(NSUInteger)sourceType {
    if (PFReturnToApp()) return;
    %orig;
}
%end

%ctor {
    @autoreleasepool {
        if ([NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"])
            %init;
    }
}
