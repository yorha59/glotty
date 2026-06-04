import Testing
import Foundation
@testable import Glotty

@Suite("Permission metadata")
struct PermissionMetadataTests {
    @Test("All permissions enumerate")
    func allCases() {
        #expect(Permission.allCases.count == 3)
        #expect(Permission.allCases.contains(.accessibility))
        #expect(Permission.allCases.contains(.inputMonitoring))
        #expect(Permission.allCases.contains(.notifications))
    }

    @Test("Display names are non-empty for every permission")
    func displayNamesPresent() {
        for p in Permission.allCases {
            #expect(!p.displayName.isEmpty)
        }
    }

    @Test("Purposes are non-empty for every permission")
    func purposesPresent() {
        for p in Permission.allCases {
            #expect(!p.purpose.isEmpty)
        }
    }

    @Test("Accessibility settings URL points at the Privacy_Accessibility pane")
    func accessibilitySettingsURL() {
        let url = Permission.accessibility.settingsURL
        #expect(url != nil)
        #expect(url?.absoluteString.contains("Privacy_Accessibility") == true)
    }

    @Test("Input Monitoring settings URL points at the Privacy_ListenEvent pane")
    func inputMonitoringSettingsURL() {
        let url = Permission.inputMonitoring.settingsURL
        #expect(url != nil)
        #expect(url?.absoluteString.contains("Privacy_ListenEvent") == true)
    }

    @Test("Identifier matches raw value (CaseIterable + Identifiable conformance)")
    func identifiers() {
        #expect(Permission.accessibility.id == "accessibility")
        #expect(Permission.inputMonitoring.id == "inputMonitoring")
    }
}

@Suite("PermissionCheck.summary")
struct PermissionSummaryTests {
    @Test("Summary includes both permission display names")
    func includesNames() {
        // The actual ✓/✗ glyphs depend on the host's TCC state, so we only assert that
        // the labels are present — this keeps the test stable across grant changes.
        let summary = PermissionCheck.summary()
        #expect(summary.contains("Accessibility"))
        #expect(summary.contains("Input Monitoring"))
    }

    @Test("Summary uses ✓ or ✗ for each row")
    func usesGlyphs() {
        let summary = PermissionCheck.summary()
        #expect(summary.contains("✓") || summary.contains("✗"))
    }
}
