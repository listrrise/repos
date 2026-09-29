BUNDLE_NAME = DinaPenisPrefs

DinaPenisPrefs_FILES = DinaPenisPrefs.mm
DinaPenisPrefs_CFLAGS = -fobjc-arc
DinaPenisPrefs_FRAMEWORKS = UIKit
# Preferences — приватный фреймворк, его нет в SDK раннера:
# линкуем с dynamic_lookup, символы резолвятся на девайсе в рантайме
DinaPenisPrefs_LDFLAGS = -undefined dynamic_lookup
DinaPenisPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/bundle.mk
