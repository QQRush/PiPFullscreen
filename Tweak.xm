#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>

@interface SBPIPContainerViewController : UIViewController
- (void)forcePictureInPictureToFrame:(CGRect)frame;
@end

// v0.43 experimental landscape rotation; v0.42 remains the SAFE baseline.
static __weak SBPIPContainerViewController *pfActivePiP = nil;
static __weak SBPIPContainerViewController *pfPendingPiP = nil;
static BOOL pfRestoreInProgress = NO;
static NSMapTable<UIView *, NSNumber *> *pfOriginalHidden;
static __weak UIControl *pfLandscapeRestoreButton = nil;
static BOOL pfLandscapeRotated = NO;

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
    UIControl *button = pfLandscapeRotated ? pfLandscapeRestoreButton : PFRestoreButton(pip.view, 0);
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

// Keep both legacy v0.34 conditional hooks: their removal has not been tested.
%hook UIStatusBarStyleAttributes
- (double)foregroundAlpha {
    double original = %orig;
    return PFStatusArmed() ? 0.0 : original;
}
%end

%hook UIApplicationSceneClientSettings
- (BOOL)statusBarHidden {
    BOOL original = %orig;
    return PFStatusArmed() ? YES : original;
}
%end

%hook SBPIPContainerViewController
- (void)viewWillAppear:(BOOL)animated {
    pfPendingPiP = self;
    %orig;
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    // Capture the original PiP aspect ratio before the fullscreen resize.
    CGSize originalSize = self.view.bounds.size;
    BOOL landscape = originalSize.width > originalSize.height && originalSize.height > 0;
    __weak SBPIPContainerViewController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        SBPIPContainerViewController *controller = weakSelf;
        if (!controller || !controller.view.window) {
            if (pfPendingPiP == controller) pfPendingPiP = nil;
            return;
        }
        CGRect screen = [UIScreen mainScreen].bounds;
        [controller forcePictureInPictureToFrame:screen];
        pfActivePiP = controller;
        pfLandscapeRotated = NO;
        pfLandscapeRestoreButton = nil;
        if (landscape) {
            // Keep a reference before rotating: transformed screen coordinates
            // no longer match the portrait restore-button position.
            pfLandscapeRestoreButton = PFRestoreButton(controller.view, 0);
            controller.view.transform = CGAffineTransformIdentity;
            controller.view.bounds = CGRectMake(0, 0, screen.size.height, screen.size.width);
            controller.view.center = CGPointMake(CGRectGetMidX(screen), CGRectGetMidY(screen));
            controller.view.transform = CGAffineTransformMakeRotation((CGFloat)-M_PI_2);
            pfLandscapeRotated = YES;
        }
    });
}
- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    if (pfPendingPiP == self) pfPendingPiP = nil;
    if (pfActivePiP == self) {
        if (pfLandscapeRotated) {
            self.view.transform = CGAffineTransformIdentity;
            self.view.bounds = [UIScreen mainScreen].bounds;
            self.view.center = CGPointMake(CGRectGetMidX([UIScreen mainScreen].bounds), CGRectGetMidY([UIScreen mainScreen].bounds));
        }
        pfLandscapeRotated = NO;
        pfLandscapeRestoreButton = nil;
        pfActivePiP = nil;
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
