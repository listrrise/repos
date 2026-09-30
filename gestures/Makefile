export TARGET := iphone:clang:latest:12.0
export ARCHS = arm64 arm64e

TWEAK_NAME = DinaGestures

DinaGestures_FILES = Gestures.xm
DinaGestures_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
DinaGestures_FRAMEWORKS = UIKit QuartzCore CoreGraphics

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
