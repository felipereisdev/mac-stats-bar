import XCTest
@testable import MacStatsBarCore

final class ApplicationWorkloadTests: XCTestCase {
    let root = ProcessIdentity(pid: 100, ownerUID: 501, executable: "/Applications/Editor.app/Contents/MacOS/Editor", startTime: 100)

    func process(_ pid: Int32, parent: Int32, path: String, cpu: UInt64?,
                 start: UInt64 = 200, bundle: String? = nil) -> ProcessActivity {
        ProcessActivity(identity: .init(pid: pid, ownerUID: 501, executable: path, startTime: start),
                        parentPID: parent, cpuTime: cpu, residentBytes: 1024, bundleIdentifier: bundle)
    }

    func testBusyExternalCompilerPreventsQuietApplicationCPU() throws {
        let previous = [
            ProcessActivity(identity: root, parentPID: 1, cpuTime: 0, residentBytes: 1024),
            process(101, parent: 100, path: "/usr/bin/clang", cpu: 0)
        ]
        let current = [
            ProcessActivity(identity: root, parentPID: 1, cpuTime: 0, residentBytes: 1024),
            process(101, parent: 100, path: "/usr/bin/clang", cpu: 30_000_000_000)
        ]
        let members = ApplicationWorkload.members(mainProcess: root, bundlePath: "/Applications/Editor.app", processes: current)
        XCTAssertEqual(Set(members.map(\.identity.pid)), [100, 101])
        let cpu = try XCTUnwrap(ApplicationWorkload.cpuPercent(current: members, previous: previous, elapsed: 30))
        XCTAssertEqual(cpu, 100, accuracy: 0.001)
    }

    func testGrandchildrenAreIncludedButUnrelatedInterpreterIsNot() {
        let values = [
            ProcessActivity(identity: root, parentPID: 1, cpuTime: 0, residentBytes: 1024),
            process(101, parent: 100, path: "/bin/sh", cpu: 0),
            process(102, parent: 101, path: "/usr/local/bin/python3", cpu: 30_000_000_000),
            process(200, parent: 1, path: "/usr/local/bin/python3", cpu: 30_000_000_000)
        ]
        let members = ApplicationWorkload.members(mainProcess: root, bundlePath: "/Applications/Editor.app", processes: values)
        XCTAssertEqual(Set(members.map(\.identity.pid)), [100, 101, 102])
    }

    func testBundleCloneCanBeAttributedByItsVerifiedBundleIdentifier() {
        let values = [
            ProcessActivity(identity: root, parentPID: 1, cpuTime: 0, residentBytes: 1024),
            process(101, parent: 1, path: "/private/var/Editor.app.bundle/Contents/MacOS/Helper", cpu: 1, bundle: "example.editor")
        ]
        let members = ApplicationWorkload.members(mainProcess: root, bundlePath: "/Applications/Editor.app",
                                                   bundleIdentifier: "example.editor", processes: values)
        XCTAssertEqual(members.count, 2)
    }

    func testChangedHelperMembershipOrMissingCPUHasNoActivityEstimate() {
        let main = ProcessActivity(identity: root, parentPID: 1, cpuTime: 10, residentBytes: 1024)
        let child = process(101, parent: 100, path: "/usr/bin/clang", cpu: 20)
        XCTAssertNil(ApplicationWorkload.cpuPercent(current: [main, child], previous: [main], elapsed: 30))
        let unreadable = process(101, parent: 100, path: "/usr/bin/clang", cpu: nil)
        XCTAssertNil(ApplicationWorkload.cpuPercent(current: [main, unreadable], previous: [main, child], elapsed: 30))
    }

    func testOtherApplicationRootAndInvalidParentReuseAreNotAttributed() {
        let other = process(101, parent: 100, path: "/Applications/Other.app/Contents/MacOS/Other", cpu: 30_000_000_000)
        let descendant = process(102, parent: 101, path: "/usr/bin/clang", cpu: 30_000_000_000, start: 300)
        let tooOld = process(103, parent: 100, path: "/usr/bin/python3", cpu: 1, start: 50)
        let values = [ProcessActivity(identity: root, parentPID: 1, cpuTime: 0, residentBytes: 1024), other, descendant, tooOld]
        let members = ApplicationWorkload.members(mainProcess: root, bundlePath: "/Applications/Editor.app",
                                                   processes: values, otherApplicationPIDs: [101])
        XCTAssertEqual(members.map(\.identity.pid), [100])
    }
}
