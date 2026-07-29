ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:16.0
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BlockAlipaySB
BlockAlipaySB_FILES = Tweak.xm
BlockAlipaySB_CFLAGS = -fobjc-arc
BlockAlipaySB_LIBRARIES = substrate
BlockAlipaySB_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
