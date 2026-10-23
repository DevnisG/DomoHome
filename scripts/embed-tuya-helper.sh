set -euo pipefail
if [[ "${DOMOHOME_INCLUDE_TUYA_HELPER:-YES}" == "NO" ]]; then exit 0; fi
case "${CURRENT_ARCH:-${NATIVE_ARCH_ACTUAL:-arm64}}" in
    arm64|undefined_arch) runtime=osx-arm64 ;;
    x86_64) runtime=osx-x64 ;;
    *) echo "error: Unsupported Tuya helper architecture"; exit 1 ;;
esac
helper_root="${DOMOHOME_HELPER_OUTPUT_ROOT:-$SRCROOT/build/TuyaMessageService}"
helper_source="$helper_root/$runtime"
if [[ ! -x "$helper_source/TuyaMessageService" ]]; then
    if [[ "$CONFIGURATION" == "Release" ]]; then
        echo "error: Build the Tuya helper using bash scripts/build-tuya-helper.sh $runtime"
        exit 1
    fi
    echo "warning: Tuya helper absent. Streaming will fail closed. Run bash scripts/build-tuya-helper.sh $runtime"
    exit 0
fi
helper_destination="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
rm -rf "$helper_destination"
mkdir -p "$helper_destination"
/usr/bin/ditto "$helper_source" "$helper_destination"
/usr/bin/find "$helper_destination" -name '*.pdb' -delete

license_destination="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Resources/TuyaMessageServiceLicenses"
mkdir -p "$license_destination"
/usr/bin/ditto "$SRCROOT/Helpers/TuyaMessageService/Licenses" "$license_destination"
/usr/bin/find "$helper_destination" -type f -exec chmod go-w {} +
if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" ]]; then
    identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
    if [[ -z "$identity" ]]; then identity=-; fi
    timestamp_option=--timestamp
    if [[ "$identity" == "-" ]]; then timestamp_option=--timestamp=none; fi
    while IFS= read -r -d '' library; do
        /usr/bin/codesign --force --options runtime "$timestamp_option" --sign "$identity" "$library"
    done < <(/usr/bin/find "$helper_destination" -name '*.dylib' -print0)
    /usr/bin/codesign --force --options runtime "$timestamp_option" --sign "$identity" \
        --entitlements "$SRCROOT/Helpers/TuyaMessageService/Helper.entitlements" \
        "$helper_destination/TuyaMessageService"
fi
