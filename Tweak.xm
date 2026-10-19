#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <string.h>

// v0.2 diagnostic: discover actual PiP classes present in SpringBoard.
// No frame manipulation until the iOS 15.8.4 controller is identified.
__attribute__((constructor)) static void pipfullscreen_init(void) {
    @autoreleasepool {
        NSString *process = NSProcessInfo.processInfo.processName;
        if (![process isEqualToString:@"SpringBoard"]) return;
        NSLog(@"[PiPFullscreen] v0.2 diagnostic loaded");
        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        unsigned int found = 0;
        for (unsigned int i = 0; i < count; i++) {
            const char *name = class_getName(classes[i]);
            if (!name) continue;
            if (strstr(name, "PIP") || strstr(name, "PiP") ||
                strstr(name, "PictureInPicture")) {
                NSLog(@"[PiPFullscreen] CLASS %s", name);
                found++;
            }
        }
        free(classes);
        NSLog(@"[PiPFullscreen] scan complete: %u candidates", found);
    }
}
