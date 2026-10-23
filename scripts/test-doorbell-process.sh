set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/domohome-process-tests.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
app="$test_directory/ProcessTests.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ProcessTests</string>
<key>CFBundleIdentifier</key><string>org.domohome.ProcessTests</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
cat > "$test_directory/MockHelper.swift" <<'SWIFT'
import Darwin
import Foundation
let input = readLine() ?? "{}"
let object = (try? JSONSerialization.jsonObject(with: Data(input.utf8))) as? [String: Any] ?? [:]
let device = object["deviceId"] as? String
let marker = NSTemporaryDirectory() + "domohome-crash-test-" + (object["accessId"] as? String ?? "")
if device == "crash-once", !FileManager.default.fileExists(atPath: marker) {
    FileManager.default.createFile(atPath: marker, contents: Data())
    exit(1)
}
if device == "ignore-termination" { signal(SIGTERM, SIG_IGN) }
if device == "malformed" {
    print("invalid-json")
} else {
    print("{\"schemaVersion\":1,\"type\":\"connection\",\"state\":\"connected\",\"environment\":\"TEST\",\"messageId\":\"\(ProcessInfo.processInfo.processIdentifier)\"}")
}
fflush(stdout)
while true { Thread.sleep(forTimeInterval: 1) }
SWIFT
cat > "$test_directory/ProcessTests.swift" <<'SWIFT'
import Darwin
import Foundation

@main
struct ProcessTests {
    static func first(_ stream: any TuyaMessageStream, state: String) async -> TuyaMessage? {
        await withTaskGroup(of: TuyaMessage?.self) { group in
            group.addTask {
                for await event in stream.messages() where event.state == state { return event }
                return nil
            }
            group.addTask { try? await Task.sleep(for: .seconds(10)); return nil }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    static func main() async throws {
        var settings = TuyaDoorbellSettings()
        settings.environment = .test
        let clientID = UUID().uuidString
        func configuration(_ device: String) -> LockConfiguration {
            LockConfiguration(tuyaClientID: clientID, tuyaClientSecret: "fixture-secret", tuyaAPIHost: "openapi.tuyaus.com",
                              lockDeviceID: device, displayName: nil, group: nil)
        }
        let adapter = TuyaMessageProcessAdapter(configuration: configuration("valid"), settings: settings)
        guard let connected = await first(adapter, state: "connected"), let pid = Int32(connected.messageId ?? "") else {
            adapter.stop()
            fatalError("Signed helper did not connect")
        }
        let duplicate = TuyaMessageProcessAdapter(configuration: configuration("valid"), settings: settings)
        let rejected = await first(duplicate, state: "ConsumerAlreadyRunning")
        duplicate.stop()
        guard rejected != nil else { adapter.stop(); fatalError("Duplicate consumer was not rejected") }
        adapter.stop()
        adapter.stop()
        try await Task.sleep(for: .milliseconds(500))
        guard kill(pid, 0) == -1 else { fatalError("Helper remained alive after stop") }
        let malformed = TuyaMessageProcessAdapter(configuration: configuration("malformed"), settings: settings)
        let failure = await first(malformed, state: "DecodingFailure")
        malformed.stop()
        guard failure != nil else { fatalError("Malformed IPC was not rejected") }
        try await Task.sleep(for: .milliseconds(500))
        let crashing = TuyaMessageProcessAdapter(configuration: configuration("crash-once"), settings: settings)
        let recovered = await first(crashing, state: "connected")
        crashing.stop()
        guard recovered != nil else { fatalError("Helper crash did not reconnect") }
        try? FileManager.default.removeItem(atPath: NSTemporaryDirectory() + "domohome-crash-test-" + clientID)
        try await Task.sleep(for: .milliseconds(500))
        let stubborn = TuyaMessageProcessAdapter(configuration: configuration("ignore-termination"), settings: settings)
        let stubbornConnection = await first(stubborn, state: "connected")
        guard let stubbornPID = Int32(stubbornConnection?.messageId ?? "") else {
            stubborn.stop()
            fatalError("Termination fixture did not start")
        }
        stubborn.stop()
        try await Task.sleep(for: .milliseconds(2500))
        guard kill(stubbornPID, 0) == -1 else { fatalError("Forced helper termination failed") }
        print("PASS: signed IPC, duplicate consumer exclusion, malformed IPC, crash/reconnect with backoff, repeated stop, forced termination, no orphans")
    }
}
SWIFT
xcrun swiftc -module-cache-path "$test_directory/modules" "$test_directory/MockHelper.swift" -o "$app/Contents/Helpers/TuyaMessageService"
xcrun swiftc -module-cache-path "$test_directory/modules" \
    "$project_root/DomoHome/App/Localization.swift" \
    "$project_root/DomoHome/Domain/DeviceConfiguration.swift" \
    "$project_root/DomoHome/Domain/ConfigurationDocument.swift" \
    "$project_root/DomoHome/Infrastructure/Doorbell/TuyaMessage.swift" \
    "$project_root/DomoHome/Infrastructure/Doorbell/TuyaDoorbellCoordinator.swift" \
    "$project_root/DomoHome/Infrastructure/Doorbell/TuyaMessageProcessAdapter.swift" \
    "$test_directory/ProcessTests.swift" -o "$app/Contents/MacOS/ProcessTests"
codesign --force --sign - "$app/Contents/Helpers/TuyaMessageService"
codesign --force --sign - "$app"
"$app/Contents/MacOS/ProcessTests"
