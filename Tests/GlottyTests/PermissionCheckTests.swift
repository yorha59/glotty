import Testing
import Foundation
@testable import Glotty

@Suite("Regular-mode launch request")
@MainActor
struct RegularLaunchRequestTests {
    @Test("Only a pending Settings or Welcome relaunch shows the Dock",
          arguments: ["none", "settings", "welcome"])
    func consumesRequest(window: String) {
        let suite = "GlottyTests.activation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: SettingsWindowController.launchRegularKey)
        if window == "settings" {
            defaults.set(true, forKey: SettingsWindowController.reopenSettingsKey)
        } else if window == "welcome" {
            defaults.set(true, forKey: WelcomeWindowController.reopenWelcomeKey)
        }
        #expect(SettingsWindowController.consumeRegularLaunchRequest(defaults: defaults)
                == (window != "none"))
        #expect(defaults.object(forKey: SettingsWindowController.launchRegularKey) == nil)
        #expect(!SettingsWindowController.consumeRegularLaunchRequest(defaults: defaults))
        if window == "settings" {
            #expect(defaults.bool(forKey: SettingsWindowController.reopenSettingsKey))
        }
    }
}

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

@Suite("Live permission status")
@MainActor
struct LivePermissionStatusTests {
    @Test("Published snapshot changes after first-time grant")
    func snapshotRefreshes() {
        var current = PermissionStatusSnapshot(
            accessibility: false,
            inputMonitoring: false,
            notifications: true
        )
        let model = PermissionStatusModel(snapshotProvider: { current })

        #expect(model.snapshot.accessibility == false)
        current.accessibility = true
        current.inputMonitoring = true
        model.refresh()

        #expect(model.snapshot.accessibility)
        #expect(model.snapshot.inputMonitoring)
        #expect(model.snapshot.anyMissing == false)
        #expect(model.refreshCount == 1)
    }

    @Test("Event-tap recovery waits for grant and retries until installed")
    func eventTapRecovery() {
        var granted = false
        var attempts = 0
        let observer = InputMonitoringGrantObserver(
            isGranted: { granted },
            onAvailable: {
                attempts += 1
                return attempts == 2
            }
        )

        observer.refresh()
        #expect(attempts == 0)

        granted = true
        observer.refresh()
        #expect(attempts == 1)
        #expect(observer.isFinished == false)

        observer.refresh()
        #expect(attempts == 2)
        #expect(observer.isFinished)

        observer.refresh()
        #expect(attempts == 2)
    }
}
