#import <substrate.h>
#import <UIKit/UIKit.h>

#define PREFS_PATH @"/var/jb/var/mobile/Library/Preferences/com.block.procguard.prefs.plist"
#define KILL_DELAY 60

static NSSet *appTargetSet = nil;
static dispatch_block_t pendingKill = nil;

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

%ctor {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if ([bid isEqualToString:@"com.apple.springboard"]) return;

    LoadPrefs();

    if (![appTargetSet containsObject:bid]) return;

    // 切后台：延迟 60 秒后杀
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
        object:nil queue:nil usingBlock:^(NSNotification *note) {
            if (pendingKill) dispatch_block_cancel(pendingKill);
            pendingKill = dispatch_block_create(0, ^{ exit(0); });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, KILL_DELAY * NSEC_PER_SEC),
                dispatch_get_main_queue(), pendingKill);
        }];

    // 回前台：取消延迟杀
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification
        object:nil queue:nil usingBlock:^(NSNotification *note) {
            if (pendingKill) {
                dispatch_block_cancel(pendingKill);
                pendingKill = nil;
            }
        }];

    CFNotificationCenterRef nc = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(nc, NULL, PrefsChanged,
        CFSTR("com.block.procguard-prefs-changed"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
}
