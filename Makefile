export TARGET := iphone:clang:latest:12.0
export ARCHS = arm64 arm64e

INSTALL_TARGET_PROCESSES = SpringBoard

SUBPROJECTS += tweak
SUBPROJECTS += prefs
SUBPROJECTS += widgets

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
