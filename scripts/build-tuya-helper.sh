set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runtime="${1:-osx-arm64}"
case "$runtime" in osx-arm64|osx-x64) ;; *) exit 2 ;; esac
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_EnableDiagnostics=0
helper_root="${DOMOHOME_HELPER_OUTPUT_ROOT:-$project_root/build/TuyaMessageService}"
mkdir -p "$helper_root"
publish_directory="$(mktemp -d "$helper_root/.publish.XXXXXX")"
trap 'rm -rf "$publish_directory"' EXIT
cd "$project_root/Helpers/TuyaMessageService"
dotnet publish "$project_root/Helpers/TuyaMessageService/TuyaMessageService.csproj" \
    -c Release -r "$runtime" --self-contained true --disable-build-servers \
    -p:UseSharedCompilation=false -p:RestoreLockedMode=true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=false -p:PublishTrimmed=false \
    -o "$publish_directory"
rm -rf "$helper_root/$runtime"
mv "$publish_directory" "$helper_root/$runtime"
