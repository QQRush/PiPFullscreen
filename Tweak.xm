#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <stdio.h>
#import <string.h>

// Diagnostic only: no PiP window manipulation.
static NSString * const kLogPath = @"/var/mobile/Library/Logs/PiPFullscreen.log";

static void PFWrite(NSString *line) {
    @synchronized([NSProcessInfo processInfo]) {
        FILE *file = fopen(kLogPath.UTF8String, "a");
        if (!file) return;
        fprintf(file, "%s\n", line.UTF8String);
        fclose(file);
    }
}

static void PFScan(NSString *phase) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) { PFWrite(@"class list unavailable"); return; }
    unsigned int found = 0;
    PFWrite([NSString stringWithFormat:@"--- %@ | %@ | total %u ---", phase, [NSDate date], count]);
    for (unsigned int i = 0; i < count; i++) {
        const char *name = class_getName(classes[i]);
        if (name && (strstr(name, "PIP") || strstr(name, "PiP") || strstr(name, "PictureInPicture"))) {
            PFWrite([NSString stringWithFormat:@"CLASS %s", name]);
            found++;
        }
    }
    free(classes);
    PFWrite([NSString stringWithFormat:@"SCAN COMPLETE %u candidates", found]);
}

__attribute__((constructor)) static void pipfullscreen_init(void) {
    @autoreleasepool {
        if (![NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"]) return;
        // The constructor may execute before SpringBoard's PiP classes are loaded.
        dispatch_async(dispatch_get_main_queue(), ^{
            PFWrite(@"PiPFullscreen v0.3 loaded in SpringBoard");
            PFScan(@"startup");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ PFScan(@"30 seconds"); });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(90 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ PFScan(@"90 seconds"); });
        });
    }
}
