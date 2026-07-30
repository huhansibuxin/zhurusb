#import <Preferences/Preferences.h>
#import <UIKit/UIKit.h>

#define PREFS_PATH @"/var/mobile/Library/Preferences/com.block.procguard.prefs.plist"

@interface ProcGuardRootListController : PSListController
@end

@implementation ProcGuardRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:PREFS_PATH];
    NSString *key = specifier.properties[@"key"];
    id value = prefs[key];
    if (!value) {
        value = specifier.properties[@"default"];
    }
    // targetsText 是从 targets 数组重建的多行文本
    if ([key isEqualToString:@"targetsText"]) {
        NSArray *targets = prefs[@"targets"];
        if ([targets isKindOfClass:[NSArray class]]) {
            return [targets componentsJoinedByString:@"\n"];
        }
        return value;
    }
    return value ?: specifier.properties[@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:PREFS_PATH] ?: [NSMutableDictionary dictionary];
    NSString *key = specifier.properties[@"key"];

    if ([key isEqualToString:@"targetsText"]) {
        NSString *text = value;
        NSArray *lines = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
        NSMutableArray *targets = [NSMutableArray array];
        for (NSString *line in lines) {
            NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (trimmed.length > 0) {
                [targets addObject:trimmed];
            }
        }
        prefs[@"targets"] = targets;
    } else {
        prefs[key] = value;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [PREFS_PATH stringByDeletingLastPathComponent];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [prefs writeToFile:PREFS_PATH atomically:YES];

    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.block.procguard-prefs-changed"), NULL, NULL, YES);
}

@end
