set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_directory="${1:?Provide an absolute output directory outside the repository}"
identity="${DOMOHOME_SIGNING_IDENTITY:?Set a Developer ID Application signing identity}"
case "$output_directory" in /*) ;; *) echo "Output directory must be absolute" >&2; exit 2 ;; esac
case "$output_directory/" in "$project_root/"*) echo "Release output must be outside the repository" >&2; exit 2 ;; esac
case "$identity" in "Developer ID Application:"*) ;; *) echo "Distribution requires a Developer ID Application identity" >&2; exit 2 ;; esac
if [[ -e "$output_directory" ]]; then echo "Choose a new output directory" >&2; exit 2; fi
runtime="${DOMOHOME_RELEASE_RUNTIME:-osx-arm64}"
case "$runtime" in osx-arm64) architecture=arm64 ;; osx-x64) architecture=x86_64 ;; *) exit 2 ;; esac
mkdir -p "$output_directory"
export DOMOHOME_HELPER_OUTPUT_ROOT="$output_directory/helper"
bash "$project_root/scripts/build-tuya-helper.sh" "$runtime"
xcodebuild -project "$project_root/DomoHome.xcodeproj" -scheme DomoHome \
    -configuration Release -derivedDataPath "$output_directory/DerivedData" \
    ARCHS="$architecture" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" \
    TUYA_MESSAGE_ENVIRONMENT=PROD ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS=--timestamp build
app="$output_directory/DomoHome.app"
ditto "$output_directory/DerivedData/Build/Products/Release/DomoHome.app" "$app"
codesign --verify --deep --strict "$app"
"$app/Contents/Helpers/TuyaMessageService" --self-test
ditto -c -k --keepParent "$app" "$output_directory/DomoHome.zip"
if [[ -n "${DOMOHOME_NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$output_directory/DomoHome.zip" --keychain-profile "$DOMOHOME_NOTARY_PROFILE" --wait
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl --assess --type execute "$app"
    rm "$output_directory/DomoHome.zip"
    ditto -c -k --keepParent "$app" "$output_directory/DomoHome.zip"
fi
