set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/domohome-tests.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
platform_path="$(xcrun --sdk macosx --show-sdk-platform-path)"
framework_path="$platform_path/Developer/Library/Frameworks"
library_path="$platform_path/Developer/usr/lib"
test_bundle="$test_directory/ConfigurationTests.xctest"
mkdir -p "$test_bundle/Contents/MacOS"
cat > "$test_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ConfigurationTests</string>
<key>CFBundleIdentifier</key><string>org.domohome.ConfigurationTests</string>
<key>CFBundlePackageType</key><string>BNDL</string>
</dict></plist>
PLIST
xcrun swiftc -emit-library -module-name ConfigurationTests -sdk "$sdk_path" \
    -module-cache-path "$test_directory/modules" -I "$library_path" \
    -F "$framework_path" -L "$library_path" -lXCTestSwiftSupport \
    -Xlinker -rpath -Xlinker "$framework_path" -Xlinker -rpath -Xlinker "$library_path" \
    "$project_root/DomoHome/App/Localization.swift" \
    "$project_root/DomoHome/Domain/DeviceConfiguration.swift" \
    "$project_root/DomoHome/Domain/ConfigurationDocument.swift" \
    "$project_root/DomoHome/Infrastructure/Configuration/CredentialStore.swift" \
    "$project_root/DomoHome/Infrastructure/Configuration/ConfigurationValidator.swift" \
    "$project_root/DomoHome/Infrastructure/Configuration/EnvironmentConfiguration.swift" \
    "$project_root/DomoHome/Infrastructure/Configuration/ConfigurationStore.swift" \
    "$project_root/Tests/ConfigurationStoreTests.swift" \
    -o "$test_bundle/Contents/MacOS/ConfigurationTests"
xcrun xctest "$test_bundle"
