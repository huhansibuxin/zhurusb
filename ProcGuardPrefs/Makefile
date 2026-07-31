TARGET := iphone:clang:16.5:16.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = ProcGuardPrefs

ProcGuardPrefs_FILES = Sources/ProcGuardRootListController.m Sources/ProcGuardAppsController.m
ProcGuardPrefs_INSTALL_PATH = /Library/PreferenceBundles
ProcGuardPrefs_CFLAGS = -fobjc-arc
ProcGuardPrefs_FRAMEWORKS = UIKit
ProcGuardPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk
