ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:16.0
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ProcGuard
ProcGuard_FILES = Tweak.xm
ProcGuard_CFLAGS = -fno-objc-arc
ProcGuard_LIBRARIES = substrate
ProcGuard_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += ProcGuardPrefs
include $(THEOS_MAKE_PATH)/aggregate.mk
