TARGET := iphone:clang:latest:15.0
ARCHS = arm64
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk
TWEAK_NAME = PiPFullscreen
PiPFullscreen_FILES = Tweak.xm
PiPFullscreen_CFLAGS = -fobjc-arc
PiPFullscreen_FRAMEWORKS = UIKit
include $(THEOS_MAKE_PATH)/tweak.mk
