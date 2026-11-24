import Foundation
import Testing

@testable import SpacewiseCore

/// One rule maps a node to its coverage status, and the settled result and the scanner's live index both use it.
struct CoverageStatusRuleTests {
    private let enumerations: [DirectoryEnumeration?] = [
        nil, .unopened, .enumerated, .partial, .cancelled, .openFailed,
    ]
    private let issues: [CoverageIssue?] = [nil] + CoverageIssue.allCases

    @Test func theRule() {
        for issue in issues {
            for enumeration in enumerations {
                for unknown in [false, true] {
                    let status = NodeCoverageStatus(issue: issue, enumeration: enumeration, allocationUnknown: unknown)
                    let expected: NodeCoverageStatus
                    switch issue {
                    case .policyExcluded?, .volumeBoundary?: expected = .policyExcluded
                    case .denied?: expected = .denied
                    case .some: expected = .unavailable
                    case nil: expected = enumeration == .unopened ? .notYetScanned : (unknown ? .partial : .measured)
                    }
                    #expect(
                        status == expected,
                        "issue \(String(describing: issue)) enumeration \(String(describing: enumeration)) unknown \(unknown)"
                    )
                }
            }
        }
    }

    @Test func settledResultAndLiveIndexAgree() {
        // One child per combination under a single root; a settled (not scanning) index applies no provisional skew.
        var nodes = [ScanNode(id: 0, parent: nil, name: "Root", kind: .directory, device: 1, inode: 1)]
        var coverage = LocationCoverage()
        coverage.enumeration[0] = .enumerated
        for issue in issues {
            for enumeration in enumerations {
                for unknown in [false, true] {
                    let id = nodes.count
                    nodes.append(
                        ScanNode(
                            id: id, parent: 0, name: "n\(id)", kind: .directory, allocationUnknown: unknown,
                            issue: issue, device: 1, inode: UInt64(id + 1)))
                    coverage.enumeration[id] = enumeration
                }
            }
        }
        var progress = ScanProgress()
        progress.state = .limited
        let root = URL(fileURLWithPath: "/Synthetic")
        let result = ScanResult(
            id: UUID(), started: Date(), ended: Date(), roots: [root], nodes: nodes, progress: progress,
            coverage: coverage, volumes: [])
        var index = ProgressiveIndex()
        for node in nodes { index.append(node) }
        for id in nodes.indices.dropFirst() {
            let live = index.provisionalRow(id: id, nodes: nodes, urls: [root], coverage: coverage, progress: progress)
            #expect(live.coverage == result.coverageStatus(for: id), "node \(id)")
        }
    }
}

/// One rule says which reasons are expected by design; Scan details and record severity both follow it.
struct ExpectedByDesignRuleTests {
    @Test func theRule() {
        let expected: Set<CoverageIssue> = [.policyExcluded, .volumeBoundary, .placeholder, .unmounted]
        for issue in CoverageIssue.allCases {
            #expect(issue.isExpectedByDesign == expected.contains(issue), "\(issue)")
        }
    }

    @Test func detailsGroupingAndSeverityFollowIt() {
        for issue in CoverageIssue.allCases where issue != .denied {  // denial depends on where it happened
            var coverage = LocationCoverage(wholeDrive: false)
            coverage.record(path: "/Synthetic/x", nodeID: nil, operation: .traverse, reason: issue)
            let severity = coverage.records[0].severity(wholeDrive: false)
            #expect((severity == .informational) == issue.isExpectedByDesign, "\(issue) severity")
            let details = ScanDetails.make(coverage)
            #expect(details.groups.count == 1, "\(issue)")
            #expect(details.groups.first?.expected == issue.isExpectedByDesign, "\(issue) grouping")
        }
    }
}

/// Volume admission is decided by the production discovery path, not a separate model of it.
struct DriveAdmissionTests {
    @Test(arguments: ["sameDisk", "otherDisk", "externalStore", "multiStore"])
    func containerVolumeAdmission(scenario: String) {
        let ids = ["boot": UUID().uuidString, "aux": UUID().uuidString]
        let boot: [String: Any] = [
            "MountPoint": "/", "DeviceIdentifier": "disk3s1", "VolumeUUID": ids["boot"]!,
            "Internal": true, "FilesystemType": "apfs", "APFSSnapshot": false,
            "APFSPhysicalStores": [["APFSPhysicalStore": "disk0s2"]],
        ]
        let stores: [[String: Any]]
        switch scenario {
        case "otherDisk": stores = [["APFSPhysicalStore": "disk1s2"]]
        case "externalStore": stores = [["APFSPhysicalStore": "disk0s9"]]
        case "multiStore": stores = [["APFSPhysicalStore": "disk0s2"], ["APFSPhysicalStore": "disk1s2"]]
        default: stores = [["APFSPhysicalStore": "disk0s2"]]
        }
        let aux: [String: Any] = [
            "MountPoint": "/System/Volumes/Aux", "DeviceIdentifier": "disk3s4", "VolumeUUID": ids["aux"]!,
            "Internal": true, "FilesystemType": "apfs", "APFSSnapshot": false, "APFSPhysicalStores": stores,
        ]
        let topology: [String: Any] = [
            "Containers": [
                [
                    "PhysicalStores": [["DeviceIdentifier": "disk0s2"]],
                    "Volumes": [["DeviceIdentifier": "disk3s4"]],
                ]
            ]
        ]
        let result = DriveDiscovery.discover(
            plist: { args in
                if args == ["apfs", "list", "-plist"] { return topology }
                switch args.last {
                case "/": return boot
                case "disk0s2": return ["Internal": true, "ParentWholeDisk": "disk0"]
                case "disk1s2": return ["Internal": true, "ParentWholeDisk": "disk1"]
                case "disk0s9": return ["Internal": false, "ParentWholeDisk": "disk0"]
                case "disk3s4", "/System/Volumes/Aux": return aux
                default: return nil
                }
            }, identity: { path in path == "/" ? (1, "/dev/disk3s1") : (2, "/dev/disk3s4") })
        let admitted = result.roots.map(\.path).contains("/System/Volumes/Aux")
        #expect(admitted == (scenario == "sameDisk"))
        if scenario != "sameDisk" {
            #expect(
                result.reasons.contains {
                    if case .unresolved(_, let location) = $0 { location == "/System/Volumes/Aux" } else { false }
                })
        }
    }
}
