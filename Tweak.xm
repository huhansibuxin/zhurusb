#import <substrate.h>
#import <signal.h>
#import <time.h>

#define PREFS_PATH @"/var/jb/var/mobile/Library/Preferences/com.block.procguard.prefs.plist"
#define KILL_DELAY 60

static NSSet *appTargetSet = nil;
static NSMutableDictionary *backgroundTimes = nil; // bid → @(timestamp)

static void LoadPrefs(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:PREFS_PATH];
    NSArray *apps = prefs[@"appTargets"];
    if ([apps isKindOfClass:[NSArray class]] && apps.count > 0) {
        appTargetSet = [NSSet setWithArray:apps];
    } else {
        appTargetSet = [NSSet setWithObject:@"com.alipay.iphoneclient"];
    }
}

static void PrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    LoadPrefs();
}

// ── Hook: App 挂起时记录时间 ──
%hook SBApplication
- (void)_didSuspend {
    %orig;
    NSString *bid = [self bundleIdentifier];
    if (bid && backgroundTimes && [appTargetSet containsObject:bid]) {
        backgroundTimes[bid] = @(time(NULL));
    }
}

- (void)_willResume {
    %orig;
    NSString *bid = [self bundleIdentifier];
    if (bid && backgroundTimes) {
        [backgroundTimes removeObjectForKey:bid];
    }
}
%end

%ctor {
    LoadPrefs();
    backgroundTimes = [NSMutableDictionary dictionary];

    // 每 5 秒扫描超时目标，远程 kill
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{
        time_t now = time(NULL);
        for (NSString *abid in [backgroundTimes allKeys]) {
            time_t bgTime = [backgroundTimes[abid] intValue];
            if (now - bgTime >= KILL_DELAY) {
                SBApplication *app = [[%c(SBApplicationController) sharedInstance] applicationWithBundleIdentifier:abid];
                int pid = [app pid];
                if (pid > 0) kill(pid, SIGKILL);
                [backgroundTimes removeObjectForKey:abid];
            }
        }
    });
    dispatch_resume(timer);

    CFNotificationCenterRef nc = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(nc, NULL, PrefsChanged,
        CFSTR("com.block.procguard-prefs-changed"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
}
