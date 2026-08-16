export THEOS_PACKAGE_SCHEME = rootless
export TARGET = iphone:clang:16.5:15.0
export ARCHS = arm64 arm64e

# System apps can carry a dedicated seatbelt profile (platform-application /
# no-container) whose grant sandboxd only makes after verifying the binary's
# *real* Apple signature — no re-signing tool can fake that, and the daemon's
# own CSHasDedicatedSandboxProfile guard already refuses to touch one. This
# System Apps are shown in the picker. The helper's dedicated sandbox and real
# signature guard still refuses unsafe on-disk patching, while runtime admission
# can consider an enabled system app without filtering it out of Settings.
export CARSURF_HIDE_SYSTEM_APPS ?= 0

INSTALL_TARGET_PROCESSES = SpringBoard CarPlay Preferences

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += sbtweak
SUBPROJECTS += apptweak
SUBPROJECTS += prefs
SUBPROJECTS += tools
SUBPROJECTS += helper

include $(THEOS_MAKE_PATH)/aggregate.mk
