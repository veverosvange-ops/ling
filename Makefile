TARGET = iphone:clang:16.5:14.0
ARCHS  = arm64 arm64e

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME            = LingAutoSword
LingAutoSword_FILES     = Tweak.xm
LingAutoSword_CFLAGS    = -fobjc-arc -O2 -DTHEOS_LEAN_AND_MEAN
LingAutoSword_FRAMEWORKS = UIKit CoreGraphics QuartzCore
LingAutoSword_LIBRARIES  =
LingAutoSword_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk
