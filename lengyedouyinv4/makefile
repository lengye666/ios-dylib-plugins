#
# 冷夜抖音助手 - Theos 项目
#
TARGET = iphone:clang:latest:14.0
ARCHS = arm64 arm64e

export DEBUG = 0
export FINALPACKAGE = 1
export THEOS_STRICT_LOGOS = 0
export LOGOS_DEFAULT_GENERATOR = internal
INSTALL_TARGET_PROCESSES = Aweme

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LengyeDouyin

LengyeDouyin_FILES = Tweak.xm VoiceControl.xm
LengyeDouyin_CFLAGS = -fobjc-arc -w
LengyeDouyin_FRAMEWORKS = UIKit Foundation AVFoundation Speech
LengyeDouyin_LOGOS_DEFAULT_GENERATOR = internal

include $(THEOS_MAKE_PATH)/tweak.mk
