ARCHS = arm64
TARGET = iphone:clang:16.5:16.0
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = runningboardd

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ProcGuard
ProcGuard_FILES = Tweak.xm
ProcGuard_CFLAGS = -fno-objc-arc
ProcGuard_LDFLAGS = -Wl,-undefined,dynamic_lookup
ProcGuard_LIBRARIES += substrate
ProcGuard_LOGOSFLAGS = -c generator=MobileSubstrate

include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += ProcGuardPrefs
include $(THEOS_MAKE_PATH)/aggregate.mk
