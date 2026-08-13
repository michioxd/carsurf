#!/bin/bash

# Qualify an installed app for CarSurf through the SSH process, whose iOS
# storage entitlements permit app-bundle writes. Accepts either an exact display
# name (for example "YouTube") or a bundle identifier.

set -euo pipefail

usage() {
    echo "Usage: CS_PASSWORD=<root password> $0 <app name | bundle id>" >&2
    echo "Optional: CS_HOST (default 192.168.6.34), CS_USER (default root)" >&2
    echo "          CS_TEST_PHONE_LAUNCH=1 to launch-test and auto-restore on failure" >&2
    echo "          CS_RESIGN_FRAMEWORKS=1 experimental matching ad-hoc signatures" >&2
    echo "          CS_SIGNING_P12 and CS_SIGNING_PASSWORD for Team-ID-preserving signing" >&2
    exit 2
}

[[ $# -eq 1 ]] || usage

if [[ -n ${CS_SIGNING_P12:-} && ! -f $CS_SIGNING_P12 ]]; then
    echo "Signing certificate not found: $CS_SIGNING_P12" >&2
    exit 2
fi
if [[ -n ${CS_SIGNING_P12:-} && -z ${CS_SIGNING_PASSWORD:-} ]]; then
    echo "CS_SIGNING_PASSWORD is required with CS_SIGNING_P12." >&2
    exit 2
fi

target=$1
device_host=${CS_HOST:-192.168.6.34}
device_user=${CS_USER:-root}
remote=${device_user}@${device_host}

if [[ -n ${CS_PASSWORD:-} ]]; then
    command -v sshpass >/dev/null || {
        echo "sshpass is required when CS_PASSWORD is set" >&2
        exit 1
    }
    export SSHPASS=$CS_PASSWORD
    auth=(sshpass -e)
fi

ssh_options=(
    -o PreferredAuthentications=password,publickey
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
)
if [[ -n ${CS_PASSWORD:-} ]]; then
    # Avoid exhausting the device's authentication attempts on the Mac's
    # loaded SSH keys before sshpass can submit the requested password.
    ssh_options+=( -o PubkeyAuthentication=no )
    ssh_cmd=(sshpass -e ssh "${ssh_options[@]}" "$remote")
    scp_cmd=(sshpass -e scp "${ssh_options[@]}")
else
    ssh_cmd=(ssh "${ssh_options[@]}" "$remote")
    scp_cmd=(scp "${ssh_options[@]}")
fi

remote_exec() {
    "${ssh_cmd[@]}" "$1"
}

shell_quote() {
    printf '%q' "$1"
}

lowercase() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

listing=$(remote_exec 'uicache -l 2>/dev/null')
bundle_id=
bundle_path=

# Prefer an exact bundle-ID match.
while IFS= read -r line; do
    [[ $line == *" : "* ]] || continue
    candidate_id=${line%% : *}
    candidate_path=${line#* : }
    if [[ $candidate_id == "$target" ]]; then
        bundle_id=$candidate_id
        bundle_path=$candidate_path
        break
    fi
done <<< "$listing"

# Otherwise match the .app directory name case-insensitively.
if [[ -z $bundle_path ]]; then
    target_lower=$(lowercase "$target")
    match_count=0
    while IFS= read -r line; do
        [[ $line == *" : "* ]] || continue
        candidate_id=${line%% : *}
        candidate_path=${line#* : }
        app_name=$(basename "$candidate_path" .app)
        if [[ $(lowercase "$app_name") == "$target_lower" ]]; then
            bundle_id=$candidate_id
            bundle_path=$candidate_path
            match_count=$((match_count + 1))
        fi
    done <<< "$listing"
    if (( match_count > 1 )); then
        echo "More than one installed app matches '$target'; use a bundle ID." >&2
        exit 1
    fi
fi

[[ -n $bundle_path ]] || {
    echo "No installed app matches '$target'." >&2
    exit 1
}

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/carsurf-patch.XXXXXX")
remote_tmp="/tmp/carsurf-patch.$$.${RANDOM}"
timestamp=$(date +%Y%m%d-%H%M%S)
backup_root="/var/mobile/carsurf-backup/${bundle_id}/${timestamp}"
mutation_started=0
completed=0
changed_files=()

cleanup() {
    status=$?
    set +e
    if (( status != 0 && mutation_started == 1 && completed == 0 )); then
        echo "Patch failed; restoring changed files from $backup_root" >&2
        for relative in "${changed_files[@]}"; do
            remote_exec "cp -a $(shell_quote "$backup_root/$relative") $(shell_quote "$bundle_path/$relative")" >/dev/null 2>&1
        done
        remote_exec "uicache -p $(shell_quote "$bundle_path")" >/dev/null 2>&1
    fi
    remote_exec "rm -rf $(shell_quote "$remote_tmp")" >/dev/null 2>&1
    rm -rf "$work_dir"
    return $status
}
trap cleanup EXIT

remote_exec "mkdir -p $(shell_quote "$remote_tmp")"

info_plist=$work_dir/Info.plist
remote_exec "base64 $(shell_quote "$bundle_path/Info.plist")" | base64 -D > "$info_plist"
executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist")
plist_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")
[[ $plist_bundle_id == "$bundle_id" ]] || {
    echo "Bundle-ID mismatch: uicache=$bundle_id Info.plist=$plist_bundle_id" >&2
    exit 1
}

main_binary=$bundle_path/$executable
jbctl=/var/jb/usr/bin/jbctl
main_signature=$(remote_exec "/var/jb/usr/bin/ldid -h $(shell_quote "$main_binary") 2>/dev/null")
main_identifier=$(sed -n 's/^Identifier=//p' <<< "$main_signature" | head -n 1)
main_team_id=$(sed -n 's/^TeamIdentifier=//p' <<< "$main_signature" | head -n 1)
[[ -n $main_identifier ]] || {
    echo "Could not read the main executable's signing identifier." >&2
    exit 1
}

main_entitlements=$work_dir/main-entitlements.plist
remote_exec "/var/jb/usr/bin/ldid -e $(shell_quote "$main_binary") 2>/dev/null" > "$main_entitlements"
plutil -lint "$main_entitlements" >/dev/null

# Apps that already carry a native CarPlay capability are admitted by CarKit
# without changing their executable. Re-signing one of these App Store binaries
# would replace its Apple CMS signature with an ad-hoc signature, potentially
# breaking team-bound services or the app's own integrity checks.
main_entitlement_listing=$(plutil -p "$main_entitlements")
if grep -Eq '"(CARCapableApp|SBStarkCapable)" => true|"com\.apple\.developer\.carplay-[^"]+" =>|"com\.apple\.developer\.playable-content" => true' <<< "$main_entitlement_listing"; then
    echo "App:        $bundle_id"
    echo "Path:       $bundle_path"
    echo "Executable: $executable"
    echo "Native CarPlay capability detected; original Apple signature preserved."
    echo "No qualification patch is required. Enable the app in CarSurf settings."
    completed=1
    exit 0
fi

# com.apple.private.security.system-application alone is not the risk signal —
# Tips has it and re-signs fine. What actually breaks is an app that opts OUT
# of the normal sandboxed container (no-container) to run under its own
# dedicated seatbelt profile instead: sandboxd only grants that profile after
# cross-checking the binary's real Apple signature, which an ad-hoc ldid
# re-sign cannot back up, and the process gets a SANDBOX-namespace SIGKILL
# within milliseconds of every launch, phone or CarPlay. Confirmed by
# comparing Tips (container-required, works fine, re-signed for months) against
# Photos (no-container + its own "MobileSlideShow" seatbelt-profiles entry,
# crashes instantly). platform-application is checked too since every no-container
# system app observed so far also carries it. Never re-sign either signal.
if grep -Eq '"platform-application" => true|"com\.apple\.private\.security\.no-container" => true|"seatbelt-profiles" =>' <<< "$main_entitlement_listing"; then
    echo "App:        $bundle_id"
    echo "Path:       $bundle_path"
    echo "Executable: $executable"
    echo "This app runs under its own dedicated sandbox profile (no-container /" >&2
    echo "platform-application) — re-signing it strips the real signature that" >&2
    echo "profile depends on and crashes it on every launch. Refusing to patch." >&2
    exit 1
fi

/usr/libexec/PlistBuddy -c 'Set :SBStarkCapable true' "$main_entitlements" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c 'Add :SBStarkCapable bool true' "$main_entitlements"
/usr/libexec/PlistBuddy -c 'Delete :SBStarkLaunchModes' "$info_plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :SBStarkLaunchModes array' "$info_plist"
/usr/libexec/PlistBuddy -c 'Add :SBStarkLaunchModes:0 string Default' "$info_plist"
plutil -lint "$info_plist" "$main_entitlements" >/dev/null

# A trustcache entry makes the re-signed main executable a platform process.
# dyld then requires every image it maps to be platform-trusted as well. Record
# embedded framework hashes so they can be trusted without re-signing or changing
# their Apple/DRM signatures.
framework_listing=$(remote_exec "if [ -d $(shell_quote "$bundle_path/Frameworks") ]; then
    framework_root=$(shell_quote "$bundle_path/Frameworks")

    # A framework's signed Mach-O image conventionally matches its bundle name.
    # Inspect that image directly instead of running ldid against every resource
    # in the bundle (Flutter apps can contain thousands of assets here).
    find \"\$framework_root\" -type d -name '*.framework' -print | while IFS= read -r framework; do
        name=\${framework##*/}
        binary=\"\$framework/\${name%.framework}\"
        hash=\$(/var/jb/usr/bin/ldid -h \"\$binary\" 2>/dev/null | grep '^CDHash=' | cut -d= -f2 | head -n 1)
        printf '%s\\t%s\\n' \"\$binary\" \"\$hash\"
    done

    # Swift packages and other dependencies can also ship standalone dylibs.
    find \"\$framework_root\" -type f -name '*.dylib' -print | while IFS= read -r binary; do
        hash=\$(/var/jb/usr/bin/ldid -h \"\$binary\" 2>/dev/null | grep '^CDHash=' | cut -d= -f2 | head -n 1)
        printf '%s\\t%s\\n' \"\$binary\" \"\$hash\"
    done
fi")

framework_paths=()
framework_hashes=()
index=0
while IFS=$'\t' read -r framework_path framework_hash; do
    [[ -n ${framework_path:-} ]] || continue
    [[ $framework_hash =~ ^[0-9a-fA-F]{40,64}$ ]] || {
        echo "Invalid existing framework cdhash for $framework_path: $framework_hash" >&2
        exit 1
    }
    framework_paths[$index]=$framework_path
    framework_hashes[$index]=$framework_hash
    index=$((index + 1))
done <<< "$framework_listing"

# RootHide's jbctl resolves and hashes a Mach-O path itself. Older Dopamine
# builds instead expect a literal CDHash. Detect the interface from jbctl's own
# usage text so the same script remains usable on both jailbreak families.
trustcache_accepts_path=0
jbctl_usage=$(remote_exec "$jbctl 2>&1 || true")
if grep -q 'trustcache add /path/to/macho' <<< "$jbctl_usage"; then
    trustcache_accepts_path=1
fi
ldid_supports_team_id=0
ldid_usage=$(remote_exec "/var/jb/usr/bin/ldid 2>&1 || true")
if grep -q '\[-tTeamID\]' <<< "$ldid_usage"; then
    ldid_supports_team_id=1
fi

echo "App:        $bundle_id"
echo "Path:       $bundle_path"
echo "Executable: $executable"
echo "Identifier: $main_identifier"
echo "Team ID:    ${main_team_id:-none}"
if [[ ${CS_RESIGN_FRAMEWORKS:-0} == 1 ]]; then
    echo "Frameworks: ${#framework_paths[@]} will be re-signed for this experiment"
    echo "Experiment: embedded images will be ad-hoc signed and restored on failure"
else
    echo "Frameworks: ${#framework_paths[@]} trusted, none modified"
fi
if (( trustcache_accepts_path == 1 )); then
    echo "Trust mode: Mach-O path (RootHide)"
else
    echo "Trust mode: CDHash"
fi
echo "Backup:     $backup_root"

# Back up only files this patch changes, retaining a quick and complete rollback.
for relative in Info.plist "$executable"; do
    remote_exec "mkdir -p $(shell_quote "$backup_root/$(dirname "$relative")"); cp -a $(shell_quote "$bundle_path/$relative") $(shell_quote "$backup_root/$relative")"
    changed_files[${#changed_files[@]}]=$relative
done
if [[ ${CS_RESIGN_FRAMEWORKS:-0} == 1 ]]; then
    for ((index=0; index<${#framework_paths[@]}; index++)); do
        relative=${framework_paths[$index]#"$bundle_path/"}
        remote_exec "mkdir -p $(shell_quote "$backup_root/$(dirname "$relative")"); cp -a $(shell_quote "${framework_paths[$index]}") $(shell_quote "$backup_root/$relative")"
        changed_files[${#changed_files[@]}]=$relative
    done
fi

"${scp_cmd[@]}" "$info_plist" "$remote:$remote_tmp/Info.plist"
"${scp_cmd[@]}" "$main_entitlements" "$remote:$remote_tmp/main-entitlements.plist"
if [[ -n ${CS_SIGNING_P12:-} ]]; then
    "${scp_cmd[@]}" "$CS_SIGNING_P12" "$remote:$remote_tmp/signing.p12"
fi

mutation_started=1
remote_exec "killall $(shell_quote "$executable") >/dev/null 2>&1 || true"
remote_exec "cp $(shell_quote "$remote_tmp/Info.plist") $(shell_quote "$bundle_path/Info.plist")"
sign_command="/var/jb/usr/bin/ldid -S$remote_tmp/main-entitlements.plist -I$(shell_quote "$main_identifier")"
if [[ -n ${CS_SIGNING_P12:-} ]]; then
    sign_command+=" -K$(shell_quote "$remote_tmp/signing.p12") -U$(shell_quote "$CS_SIGNING_PASSWORD")"
elif [[ -n $main_team_id && $ldid_supports_team_id == 1 ]]; then
    sign_command+=" -t$(shell_quote "$main_team_id")"
fi
sign_command+=" $(shell_quote "$main_binary")"
remote_exec "$sign_command"

if [[ ${CS_RESIGN_FRAMEWORKS:-0} == 1 ]]; then
    for ((index=0; index<${#framework_paths[@]}; index++)); do
        framework_entitlements="$remote_tmp/framework-$index-entitlements.plist"
        framework_identifier=$(remote_exec "/var/jb/usr/bin/ldid -h $(shell_quote "${framework_paths[$index]}") 2>/dev/null | grep '^Identifier=' | cut -d= -f2- | head -n 1")
        [[ -n $framework_identifier ]] || {
            echo "Could not read signing identifier for ${framework_paths[$index]}" >&2
            exit 1
        }
        remote_exec "/var/jb/usr/bin/ldid -e $(shell_quote "${framework_paths[$index]}") 2>/dev/null > $(shell_quote "$framework_entitlements")
if [ -s $(shell_quote "$framework_entitlements") ]; then
    /var/jb/usr/bin/ldid -S$(shell_quote "$framework_entitlements") -I$(shell_quote "$framework_identifier") $(shell_quote "${framework_paths[$index]}")
else
    /var/jb/usr/bin/ldid -S -I$(shell_quote "$framework_identifier") $(shell_quote "${framework_paths[$index]}")
fi"
        framework_hashes[$index]=$(remote_exec "/var/jb/usr/bin/ldid -h $(shell_quote "${framework_paths[$index]}") 2>/dev/null | grep '^CDHash=' | cut -d= -f2 | head -n 1")
    done
fi

main_hash=$(remote_exec "/var/jb/usr/bin/ldid -h $(shell_quote "$main_binary") 2>/dev/null | grep '^CDHash=' | cut -d= -f2 | head -n 1")
[[ $main_hash =~ ^[0-9a-fA-F]{40,64}$ ]] || {
    echo "Invalid main executable cdhash: $main_hash" >&2
    exit 1
}
if (( trustcache_accepts_path == 1 )); then
    remote_exec "$jbctl trustcache add $(shell_quote "$main_binary")"
else
    remote_exec "$jbctl trustcache add $(shell_quote "$main_hash")"
fi

# Batch framework trust operations into one SSH session. Apps with many embedded
# images can otherwise trigger the device SSH daemon's authentication throttling.
framework_actions='set -e'
for ((index=0; index<${#framework_paths[@]}; index++)); do
    # Trust the existing Apple-signed image. Do not pass it through ldid -S:
    # that would remove its certificate/team signature and can break DRM.
    framework_actions+=$'\n'
    if (( trustcache_accepts_path == 1 )); then
        framework_actions+="$jbctl trustcache add $(shell_quote "${framework_paths[$index]}")"
    else
        framework_actions+="$jbctl trustcache add $(shell_quote "${framework_hashes[$index]}")"
    fi
done
remote_exec "$framework_actions"

remote_exec "uicache -p $(shell_quote "$bundle_path")"

verified_main_identifier=$(remote_exec "/var/jb/usr/bin/ldid -h $(shell_quote "$main_binary") 2>/dev/null | grep '^Identifier=' | cut -d= -f2- | head -n 1")
[[ $verified_main_identifier == "$main_identifier" ]] || {
    echo "Main signing identifier changed unexpectedly: $verified_main_identifier" >&2
    exit 1
}
if [[ -n $main_team_id && ( -n ${CS_SIGNING_P12:-} || $ldid_supports_team_id == 1 ) ]]; then
    verified_main_team_id=$(remote_exec "/var/jb/usr/bin/ldid -h $(shell_quote "$main_binary") 2>/dev/null | grep '^TeamIdentifier=' | cut -d= -f2- | head -n 1")
    [[ $verified_main_team_id == "$main_team_id" ]] || {
        echo "Main Team ID changed unexpectedly: $verified_main_team_id" >&2
        exit 1
    }
fi

# Verify every embedded image in one more SSH session, preserving array order so
# each observed hash can be checked against the exact pre-mutation hash.
framework_verification='set -e'
for ((index=0; index<${#framework_paths[@]}; index++)); do
    framework_verification+=$'\n'
    framework_verification+="hash=\$(/var/jb/usr/bin/ldid -h $(shell_quote "${framework_paths[$index]}") 2>/dev/null | grep '^CDHash=' | cut -d= -f2 | head -n 1)"
    framework_verification+=$'\n'
    framework_verification+="printf '%s\\t%s\\n' $(shell_quote "${framework_paths[$index]}") \"\$hash\""
done
verified_framework_listing=$(remote_exec "$framework_verification")

verified_index=0
while IFS=$'\t' read -r verified_framework_path verified_framework_hash; do
    (( verified_index < ${#framework_paths[@]} )) || {
        echo "Verification returned an unexpected framework: $verified_framework_path" >&2
        exit 1
    }
    [[ $verified_framework_path == "${framework_paths[$verified_index]}" ]] || {
        echo "Framework verification order changed unexpectedly: $verified_framework_path" >&2
        exit 1
    }
    [[ $verified_framework_hash == "${framework_hashes[$verified_index]}" ]] || {
        echo "Framework changed unexpectedly: $verified_framework_path" >&2
        exit 1
    }
    verified_index=$((verified_index + 1))
done <<< "$verified_framework_listing"
(( verified_index == ${#framework_paths[@]} )) || {
    echo "Framework verification was incomplete: $verified_index of ${#framework_paths[@]} checked" >&2
    exit 1
}

if [[ ${CS_TEST_PHONE_LAUNCH:-0} == 1 ]]; then
    echo "Testing a normal phone launch before keeping the patch..."
    # Rootless installs put uiopen under /var/jb; /usr/bin/uiopen does not exist
    # there, and a failure to launch it reads as "the patch broke the app" and
    # rolls back a patch that was fine.
    remote_exec "uiopen=\$(command -v uiopen 2>/dev/null || echo /var/jb/usr/bin/uiopen)
\"\$uiopen\" --bundleid $(shell_quote "$bundle_id")
sleep 5
if ! launchctl print user/501 2>/dev/null | grep -F $(shell_quote "UIKitApplication:$bundle_id[") | grep -Eq '^[[:space:]]*[1-9][0-9]*[[:space:]]'; then
    echo 'The patched app did not remain running after launch.' >&2
    exit 1
fi"
    echo "Phone launch stayed alive for 5 seconds."
fi

completed=1
echo "Patched successfully. The main identifier was preserved; embedded framework signatures were trusted without re-signing."
echo "Open the app normally once, then launch it from the CarPlay dashboard."
