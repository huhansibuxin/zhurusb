#import <Foundation/Foundation.h>
#import <substrate.h>
#import <UIKit/UIKit.h>

#define PREFS_PATH @"/var/jb/var/mobile/Library/Preferences/com.block.procguard.prefs.plist"
#define KILL_DELAY 60

static NSSet *appTargetSet = nil;
static volatile BOOL shouldKill = NO;

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

%ctor {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if ([bid isEqualToString:@"com.apple.springboard"]) return;

    LoadPrefs();
    if (![appTargetSet containsObject:bid]) return;

    // 静默推送/后台拉起：App 出生就在后台，直接开始倒计时
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        shouldKill = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, KILL_DELAY * NSEC_PER_SEC),
            dispatch_get_main_queue(), ^{
                if (shouldKill) exit(0);
            });
    }

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
        object:nil queue:nil usingBlock:^(NSNotification *note) {
            shouldKill = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, KILL_DELAY * NSEC_PER_SEC),
                dispatch_get_main_queue(), ^{
                    if (shouldKill) exit(0);
                });
        }];

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification
        object:nil queue:nil usingBlock:^(NSNotification *note) {
            shouldKill = NO;
        }];

    CFNotificationCenterRef nc = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(nc, NULL, PrefsChanged,
        CFSTR("com.block.procguard-prefs-changed"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
}
