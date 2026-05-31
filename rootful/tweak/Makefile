TARGET = iphone:clang:9.3:6.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = GroupChatNameFix

GroupChatNameFix_FILES = Tweak.x
GroupChatNameFix_FRAMEWORKS = Foundation
GroupChatNameFix_LIBRARIES = substrate
GroupChatNameFix_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk
