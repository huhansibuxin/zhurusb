#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <substrate.h>
#import <signal.h>
#import <time.h>

#define PREFS_PATH @"/var/jb/var/mobile/Library/Preferences/com.block.procguard.prefs.plist"
#define KILL_DELAY 60
#define SCAN_INTERVAL 5

static NSSet *appTargetSet = nil;
static NSMutableDictionary *backgroundTimes = nil;

static void LoadPrefs(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:PREFS_PATH];
    NSArray *apps = prefs[@"appTargets"];
    if ([apps isKindOfClass:[NSArray class]] && apps.count > 0) {
        appTargetSet = [NSSet setWithArray:apps];
    } else {
        appTargetSet = [NSSet setWithObject:@"com.alipay.iphoneclient"];
    }
}

static void PrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                          const void *object, CFDictionaryRef userInfo) {
    LoadPrefs();
}

%hook SBMainWorkspace
- (void)setApplicationProcessState:(id)state forApplication:(id)app {
    %orig;
    if (!backgroundTimes) return;

    NSString *bid = ((id(*)(id, SEL))objc_msgSend)(app, @selector(bundleIdentifier));
    if (!bid || ![appTargetSet containsObject:bid]) return;

    long long ts = ((long long(*)(id, SEL))objc_msgSend)(state, @selector(taskState));
    if (ts == 1 || ts == 2) {
        backgroundTimes[bid] = @((long)time(NULL));
    } else {
        [backgroundTimes removeObjectForKey:bid];
    }
}
%end

%ctor {
    LoadPrefs();
    backgroundTimes = [NSMutableDictionary dictionary];

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                      dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, SCAN_INTERVAL * NSEC_PER_SEC),
                              SCAN_INTERVAL * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{
        time_t now = time(NULL);
        NSArray *keys = [backgroundTimes allKeys];
        for (NSString *bid in keys) {
            long bgTime = (long)[backgroundTimes[bid] integerValue];
            if (now - bgTime < KILL_DELAY) continue;

            id ctrl = ((id(*)(id, SEL))objc_msgSend)(objc_getClass("SBApplicationController"),
                                                       @selector(sharedInstance));
            id app = ((id(*)(id, SEL, id))objc_msgSend)(ctrl,
                                                          @selector(applicationWithBundleIdentifier:), bid);
            int pid = app ? (int)((long(*)(id, SEL))objc_msgSend)(app, @selector(pid)) : 0;
            if (pid > 0) kill(pid, SIGKILL);
            [backgroundTimes removeObjectForKey:bid];
        }
    });
    dispatch_resume(timer);

    CFNotificationCenterRef nc = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(nc, NULL, PrefsChanged,
        CFSTR("com.block.procguard-prefs-changed"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
}
