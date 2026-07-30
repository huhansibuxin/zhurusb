#import <substrate.h>
#import <UIKit/UIKit.h>

#define PREFS_PATH @"/var/jb/var/mobile/Library/Preferences/com.block.procguard.prefs.plist"

static NSSet *appTargetSet = nil;
static NSArray *daemonTargets = nil;

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

// ── Darwin 通知 ──
static void PrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    LoadPrefs();
}

%ctor {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if ([bid isEqualToString:@"com.apple.springboard"]) return;

    LoadPrefs();

    // Daemon 自裁：注入了就是目标，直接退出
    if ([daemonTargets containsObject:bid]) {
        exit(0);
    }

    // App 切后台自裁
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
        object:nil queue:nil usingBlock:^(NSNotification *note) {
            NSString *myBID = [[NSBundle mainBundle] bundleIdentifier];
            if (myBID && [appTargetSet containsObject:myBID]) {
                exit(0);
            }
        }];

    CFNotificationCenterRef nc = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(nc, NULL, PrefsChanged,
        CFSTR("com.block.procguard-prefs-changed"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
}
