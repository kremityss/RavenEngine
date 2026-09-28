TARGET = iphone:clang:latest:14.0
# iPhone 12 and newer use arm64-family hardware. Build both slices so the
# signed IPA can select the compatible slice on arm64 and arm64e devices.
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Raven
	Raven_FILES = Raven.mm Src/IL2CPP.mm Src/ESP.mm Src/Aimbot.mm Src/Menu.mm Src/Updater.mm Src/Settings.mm Src/LicenseClient.mm
Raven_CFLAGS = -fobjc-arc -I./Src -std=c++17 -Wno-unused-function -Wno-deprecated-declarations
Raven_CCFLAGS = -fobjc-arc -I./Src -std=c++17
Raven_FRAMEWORKS = UIKit Foundation QuartzCore CoreGraphics

include $(THEOS_MAKE_PATH)/tweak.mk
