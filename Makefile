ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:14.0
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = runningboardd

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ProcGuard
ProcGuard_FILES = Tweak.xm
ProcGuard_CFLAGS = -fno-objc-arc
ProcGuard_LDFLAGS = -Wl,-undefined,dynamic_lookup -Wl,-fixup_chains -Wl,-platform_version,ios,14.0,17.0
ProcGuard_LOGOSFLAGS = -c generator=internal

include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += ProcGuardPrefs
include $(THEOS_MAKE_PATH)/aggregate.mk
