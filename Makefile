export THEOS_PACKAGE_SCHEME = rootless
export TARGET = iphone:clang:16.5:15.0
export ARCHS = arm64 arm64e

# System apps can carry a dedicated seatbelt profile (platform-application /
# no-container) whose grant sandboxd only makes after verifying the binary's
# *real* Apple signature — no re-signing tool can fake that, and the daemon's
# own CSHasDedicatedSandboxProfile guard already refuses to touch one. This
# flag additionally hides the whole System Apps section from the picker at
# build time, so a user can't even try one and land on the daemon's refusal
# message. Confirmed necessary the hard way on Photos: re-signing it (from a
# build before that guard existed) destroyed its real signature permanently —
# entitlements can be reverted, the signature never can — and there was no
# fix short of restoring the bundle from the jailbreak's own system-app
# tooling. Override with CARSURF_HIDE_SYSTEM_APPS=0 to bring the section back.
export CARSURF_HIDE_SYSTEM_APPS ?= 1

INSTALL_TARGET_PROCESSES = SpringBoard CarPlay Preferences

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += sbtweak
SUBPROJECTS += apptweak
SUBPROJECTS += prefs
SUBPROJECTS += tools
SUBPROJECTS += helper

include $(THEOS_MAKE_PATH)/aggregate.mk
