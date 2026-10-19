#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <stdio.h>
#import <string.h>

static NSString * const kLogPath = @"/var/mobile/Library/Logs/PiPFullscreen.log";
static void PFWrite(NSString *line) {
    @synchronized([NSProcessInfo processInfo]) {
        FILE *f = fopen(kLogPath.UTF8String, "a");
        if (!f) return;
        fprintf(f, "%s\n", line.UTF8String);
        fclose(f);
    }
}
static void PFDumpMethods(const char *className) {
    Class cls = objc_getClass(className);
    if (!cls) { PFWrite([NSString stringWithFormat:@"MISSING %s", className]); return; }
    PFWrite([NSString stringWithFormat:@"=== METHODS %s ===", className]);
    for (int meta = 0; meta < 2; meta++) {
        Class target = meta ? object_getClass(cls) : cls;
        unsigned int n = 0;
        Method *methods = class_copyMethodList(target, &n);
        for (unsigned int i = 0; i < n; i++) {
            const char *sel = sel_getName(method_getName(methods[i]));
            const char *encoding = method_getTypeEncoding(methods[i]);
            PFWrite([NSString stringWithFormat:@"%@ %s | %s", meta ? @"+" : @"-", sel ?: "?", encoding ?: "?"]);
        }
        free(methods);
    }
}
static void PFScan(void) {
    PFWrite([NSString stringWithFormat:@"PiPFullscreen v0.4 method diagnostic | %@", [NSDate date]]);
    const char *targets[] = {
        "SBPIPWindow", "SBPIPSizingSettings", "SBPIPContentViewLayoutMetricsSizePolicy",
        "SBPIPContentViewLayoutSizePreferences", "SBPIPContentViewLayoutMetrics",
        "SBPIPContainerViewController", "SBPIPController", "SBPIPWindowRootViewController",
        "SBPIPInteractionController", "SBPIPSettings", "PGMobilePIPSettings"
    };
    for (unsigned int i = 0; i < sizeof(targets)/sizeof(targets[0]); i++) PFDumpMethods(targets[i]);
    PFWrite(@"=== END METHODS ===");
}
__attribute__((constructor)) static void PFInit(void) {
    @autoreleasepool {
        if (![NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ PFScan(); });
        });
    }
}
