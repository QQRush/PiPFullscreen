#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// Experimental, conservative first build: test SpringBoard injection without
// modifying private PiP state. Future builds will locate and validate the
// PiP window controller on iOS 15.8.4 before altering its layout.
__attribute__((constructor)) static void pipfullscreen_init(void) {
    NSLog(@"[PiPFullscreen] v0.1 injected into process %@", NSProcessInfo.processInfo.processName);
}
