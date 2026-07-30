#import <substrate.h>
#import <UIKit/UIKit.h>
#import <time.h>
#import <spawn.h>

extern char **environ;

#define PREFS_PATH @"/var/jb/var/mobile/Library/Preferences/com.block.procguard.prefs.plist"
#define FLOOD_INTERVAL 3
#define FLOOD_MAX_COUNT 2
#define BLOCK_DURATION 120

static NSSet *appTargetSet = nil;
static NSArray *daemonTargets = nil;
static NSMutableDictionary *floodState = nil;

// ── 读取预置 ──
static void LoadPrefs(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:PREFS_PATH];

    NSArray *apps = prefs[@"appTargets"];
    if ([apps isKindOfClass:[NSArray class]] && apps.count > 0) {
        appTargetSet = [NSSet setWithArray:apps];
    } else {
        appTargetSet = [NSSet setWithObject:@"com.alipay.iphoneclient"];
    }

    NSArray *daemons = prefs[@"daemonTargets"];
    if ([daemons isKindOfClass:[NSArray class]]) {
        daemonTargets = daemons;
    } else {
        daemonTargets = @[];
    }
}

// ── 洪水限流 ──
static BOOL IsFloodBlocked(NSString *key) {
    NSDictionary *s = floodState[key];
    if (!s) return NO;
    return time(NULL) < [s[@"blockUntil"] intValue];
}

static void FloodTick(NSString *key) {
    NSMutableDictionary *s = floodState[key];
    if (!s) {
        s = [NSMutableDictionary dictionaryWithObjectsAndKeys:@(0), @"lastTime", @(0), @"count", @(0), @"blockUntil", nil];
        floodState[key] = s;
    }
    time_t now = time(NULL);
    time_t last = [s[@"lastTime"] intValue];
    if (now - last > FLOOD_INTERVAL) {
        s[@"count"] = @(0);
    }
    s[@"lastTime"] = @(now);
    int count = [s[@"count"] intValue] + 1;
    s[@"count"] = @(count);
    if (count >= FLOOD_MAX_COUNT) {
        s[@"blockUntil"] = @(now + BLOCK_DURATION);
    }
}

// ── 杀守护进程 ──
static void KillDaemon(NSString *name) {
    if (IsFloodBlocked(name)) return;
    FloodTick(name);

    pid_t pid;
    const char *args[] = {
        "/var/jb/usr/bin/killall",
        "-9",
        [name UTF8String],
        NULL
    };
    posix_spawn(&pid, "/var/jb/usr/bin/killall", NULL, NULL, (char *const *)args, environ);
}

// ── 切后台回调 ──
static void OnAppBackground(void) {
    NSString *myBID = [[NSBundle mainBundle] bundleIdentifier];
    if (!myBID) return;

    if ([appTargetSet containsObject:myBID]) {
        for (NSString *dn in daemonTargets) {
            KillDaemon(dn);
        }
        exit(0);
    }
}

// ── Darwin 通知 ──
static void PrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    LoadPrefs();
}

%ctor {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if ([bid isEqualToString:@"com.apple.springboard"]) return;

    floodState = [NSMutableDictionary dictionary];
    LoadPrefs();

    CFNotificationCenterRef nc = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(nc, NULL, PrefsChanged,
        CFSTR("com.block.procguard-prefs-changed"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
        object:nil queue:nil usingBlock:^(NSNotification *note) {
            OnAppBackground();
        }];
}
