#import <Preferences/Preferences.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define PREFS_PATH @"/var/mobile/Library/Preferences/com.block.procguard.prefs.plist"

@interface ProcGuardAppsController : PSListController
@end

@implementation ProcGuardAppsController {
    NSArray *_allApps;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        [self loadApps];
    }
    return _specifiers;
}

- (void)loadApps {
    NSMutableArray *specs = [NSMutableArray array];

    Class LSApplicationWorkspace = objc_getClass("LSApplicationWorkspace");
    id workspace = [LSApplicationWorkspace performSelector:@selector(defaultWorkspace)];
    _allApps = [workspace performSelector:@selector(allInstalledApplications)];

    // 获取当前已选
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:PREFS_PATH];
    NSArray *selected = prefs[@"appTargets"];
    NSSet *selectedSet = selected ? [NSSet setWithArray:selected] : [NSSet set];

    // 按名称排序
    _allApps = [_allApps sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        NSString *na = [a performSelector:@selector(localizedName)] ?: [a performSelector:@selector(bundleIdentifier)];
        NSString *nb = [b performSelector:@selector(localizedName)] ?: [b performSelector:@selector(bundleIdentifier)];
        return [na compare:nb options:NSCaseInsensitiveSearch];
    }];

    for (id app in _allApps) {
        NSString *bid = [app performSelector:@selector(bundleIdentifier)];
        NSString *name = [app performSelector:@selector(localizedName)];
        if (!bid || bid.length == 0) continue;
        if (!name) name = bid;

        // 过滤系统应用
        if ([bid hasPrefix:@"com.apple."]) continue;

        BOOL isOn = [selectedSet containsObject:bid];

        PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:name
            target:self
            set:@selector(toggleApp:specifier:)
            get:@selector(isAppSelected:)
            detail:nil
            cell:PSSwitchCell
            edit:nil];
        [spec setProperty:bid forKey:@"bundleID"];
        [spec setProperty:@(isOn) forKey:@"default"];
        [specs addObject:spec];
    }

    _specifiers = specs;
}

- (id)isAppSelected:(PSSpecifier *)specifier {
    NSString *bid = specifier.properties[@"bundleID"];
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:PREFS_PATH];
    NSArray *selected = prefs[@"appTargets"];
    return @([selected containsObject:bid]);
}

- (void)toggleApp:(id)value specifier:(PSSpecifier *)specifier {
    NSString *bid = specifier.properties[@"bundleID"];
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:PREFS_PATH] ?: [NSMutableDictionary dictionary];
    NSMutableArray *selected = [prefs[@"appTargets"] mutableCopy] ?: [NSMutableArray array];

    if ([value boolValue]) {
        if (![selected containsObject:bid]) [selected addObject:bid];
    } else {
        [selected removeObject:bid];
    }

    prefs[@"appTargets"] = selected;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [PREFS_PATH stringByDeletingLastPathComponent];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [prefs writeToFile:PREFS_PATH atomically:YES];

    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.block.procguard-prefs-changed"), NULL, NULL, YES);
}

@end
