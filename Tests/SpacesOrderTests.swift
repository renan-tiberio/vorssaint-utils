// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import CoreFoundation
import Foundation

enum SpacesOrderTests {
    /// A Dock that only exists in memory. The live system is never built here,
    /// so nothing in this suite can reach the real preference or the Dock.
    final class FakeDock {
        var value: SpacesRearrangeSetting
        var liveAvailable = true
        var liveApplies = true
        var writable = true
        var restartSucceeds = true
        var events: [String] = []
        var reads = 0
        var pauses = 0
        /// The user's own change in System Settings, landing right after the
        /// first read, on the same thread as that read.
        var changeAfterFirstRead: SpacesRearrangeSetting?
        /// The saved marker at the first call that could change the setting.
        var markerAtFirstCall: String?
        /// One signal per recorded event, for the syncs that run on the
        /// hold's own queue.
        let signals = DispatchSemaphore(value: 0)
        private var sawFirstCall = false
        private let defaults: UserDefaults

        init(_ value: SpacesRearrangeSetting, defaults: UserDefaults) {
            self.value = value
            self.defaults = defaults
        }

        private func record(_ event: String) {
            if !sawFirstCall {
                sawFirstCall = true
                markerAtFirstCall = defaults.string(forKey: DefaultsKey.spacesOrderRestore)
            }
            events.append(event)
            signals.signal()
        }

        var system: SpacesOrderSystem {
            SpacesOrderSystem(
                read: {
                    let current = self.value
                    if self.reads == 0, let change = self.changeAfterFirstRead { self.value = change }
                    self.reads += 1
                    return current
                },
                setLive: { rearranging in
                    guard self.liveAvailable else { return false }
                    self.record("live(\(rearranging))")
                    if self.liveApplies { self.value = rearranging ? .on : .off }
                    return true
                },
                write: { rearranging in
                    self.record("write(\(rearranging.map { String($0) } ?? "nil"))")
                    guard self.writable else { return false }
                    self.value = rearranging.map { $0 ? .on : .off } ?? .absent
                    return true
                },
                restartDock: {
                    self.record("restart")
                    return self.restartSucceeds
                },
                pause: { self.pauses += 1 }
            )
        }
    }

    static func run(_ suite: TestSuite) {
        let name = "com.vorssaint.tests.spaces-order.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let marker = DefaultsKey.spacesOrderRestore
        let absent = SpacesOrderSupport.restoreAbsent
        let on = SpacesOrderSupport.restoreOn

        func setMarker(_ value: String?) {
            if let value {
                defaults.set(value, forKey: marker)
            } else {
                defaults.removeObject(forKey: marker)
            }
        }
        func make(_ value: SpacesRearrangeSetting, marker saved: String? = nil) -> (SpacesOrderHold, FakeDock) {
            setMarker(saved)
            let dock = FakeDock(value, defaults: defaults)
            return (SpacesOrderHold(defaults: defaults, system: dock.system), dock)
        }

        // MARK: Reading the preference

        suite.expect(SpacesOrderSupport.setting(raw: nil, isForced: false) == .absent
                     && SpacesOrderSupport.setting(raw: true, isForced: false) == .on
                     && SpacesOrderSupport.setting(raw: false, isForced: false) == .off
                     && SpacesOrderSupport.setting(raw: NSNumber(value: 0), isForced: false) == .off
                     && SpacesOrderSupport.setting(raw: kCFBooleanFalse as CFTypeRef, isForced: false) == .off
                     && SpacesOrderSupport.setting(raw: kCFBooleanTrue as CFTypeRef, isForced: false) == .on,
                     "a missing key reads as the default and Booleans read as on or off")
        suite.expect(SpacesOrderSupport.setting(raw: "NO", isForced: false) == .unsupported
                     && SpacesOrderSupport.setting(raw: true, isForced: true) == .unsupported
                     && SpacesOrderSupport.setting(raw: nil, isForced: true) == .unsupported,
                     "a managed value or one that is not a Boolean is never treated as the user's own")

        // MARK: Planning

        let step = SpacesOrderSupport.step
        suite.expect(step(true, .off, nil) == .none && step(true, .off, absent) == .none
                     && step(true, .unsupported, nil) == .none && step(true, .unsupported, on) == .none,
                     "a setting already off or managed is left alone, so launch never restarts the Dock")
        suite.expect(step(true, .absent, nil) == .hold(marker: absent)
                     && step(true, .on, nil) == .hold(marker: on),
                     "turning the feature on saves exactly the state it found")
        suite.expect(step(true, .absent, on) == .letGo && step(true, .on, absent) == .letGo
                     && step(true, .on, on) == .letGo && step(true, .absent, absent) == .letGo,
                     "rearranging turned back on while the feature held it off is the user's choice, never undone")
        suite.expect([SpacesRearrangeSetting.absent, .on, .off, .unsupported].allSatisfy {
                         step(false, $0, nil) == .none
                     },
                     "without a marker nothing is restored, so an original off setting stays off")
        suite.expect(step(false, .off, absent) == .release(removeKey: true)
                     && step(false, .off, on) == .release(removeKey: false),
                     "turning the feature off returns to a missing key or an explicit on")
        suite.expect(step(false, .absent, absent) == .forget && step(false, .on, absent) == .forget
                     && step(false, .on, on) == .forget && step(false, .unsupported, on) == .forget,
                     "a setting the user already changed is never undone")

        // MARK: Turning rearranging off

        var (hold, dock) = make(.absent)
        suite.expect(hold.reconcile(wanted: true) && dock.events == ["live(false)"]
                     && dock.value == .off && defaults.string(forKey: marker) == absent,
                     "the Dock's own call turns rearranging off without a write or a restart")
        suite.expect(dock.markerAtFirstCall == absent,
                     "the state to put back is saved before the system setting changes")

        (hold, dock) = make(.on)
        suite.expect(hold.reconcile(wanted: true) && defaults.string(forKey: marker) == on,
                     "an explicit on is remembered as on")

        (hold, dock) = make(.off)
        suite.expect(hold.reconcile(wanted: true) && dock.events.isEmpty
                     && defaults.object(forKey: marker) == nil,
                     "a user who already keeps a fixed order gets no marker and no Dock change")
        (hold, dock) = make(.off, marker: absent)
        suite.expect(hold.reconcile(wanted: true) && dock.events.isEmpty
                     && defaults.string(forKey: marker) == absent,
                     "a relaunch with the setting already applied never touches or restarts the Dock")

        (hold, dock) = make(.absent)
        dock.liveAvailable = false
        suite.expect(hold.reconcile(wanted: true) && dock.events == ["write(false)", "restart"]
                     && dock.value == .off && defaults.string(forKey: marker) == absent,
                     "without the Dock's call the preference is written and the Dock restarts once")

        (hold, dock) = make(.absent)
        dock.liveApplies = false
        suite.expect(hold.reconcile(wanted: true)
                     && dock.events == ["live(false)", "write(false)", "restart"]
                     && dock.reads == 1 + SpacesOrderSupport.confirmAttempts
                     && dock.pauses == SpacesOrderSupport.confirmAttempts,
                     "an unconfirmed live call waits out its checks, then writes and restarts exactly once")

        (hold, dock) = make(.absent)
        dock.liveAvailable = false
        dock.writable = false
        suite.expect(!hold.reconcile(wanted: true) && dock.events == ["write(false)"]
                     && defaults.object(forKey: marker) == nil,
                     "a hold that changed nothing removes the marker it created and never restarts the Dock")
        (hold, dock) = make(.absent)
        dock.liveAvailable = false
        dock.restartSucceeds = false
        suite.expect(!hold.reconcile(wanted: true) && dock.value == .off
                     && defaults.string(forKey: marker) == absent,
                     "a written preference whose restart failed keeps its marker, so it can still return")

        // MARK: Putting the user's setting back

        (hold, dock) = make(.off, marker: absent)
        suite.expect(hold.reconcile(wanted: false) && dock.events == ["live(true)", "write(nil)"]
                     && dock.value == .absent && defaults.object(forKey: marker) == nil,
                     "a setting that started missing is turned back on and its key removed, without a restart")
        (hold, dock) = make(.off, marker: on)
        suite.expect(hold.reconcile(wanted: false) && dock.events == ["live(true)"]
                     && dock.value == .on && defaults.object(forKey: marker) == nil,
                     "a setting that started on is turned back on and left explicit")

        (hold, dock) = make(.off, marker: absent)
        dock.liveAvailable = false
        suite.expect(hold.reconcile(wanted: false) && dock.events == ["write(nil)", "restart"]
                     && dock.value == .absent && defaults.object(forKey: marker) == nil,
                     "without the Dock's call a missing key is restored with one restart")
        (hold, dock) = make(.off, marker: on)
        dock.liveAvailable = false
        suite.expect(hold.reconcile(wanted: false) && dock.events == ["write(true)", "restart"]
                     && dock.value == .on,
                     "without the Dock's call an explicit on is restored with one restart")

        (hold, dock) = make(.off, marker: absent)
        dock.liveAvailable = false
        dock.writable = false
        suite.expect(!hold.reconcile(wanted: false) && dock.value == .off
                     && defaults.string(forKey: marker) == absent,
                     "a failed restore keeps its marker so the next sync tries again")
        dock.writable = true
        suite.expect(hold.reconcile(wanted: false) && dock.value == .absent
                     && defaults.object(forKey: marker) == nil,
                     "the next sync finishes an interrupted restore")

        (hold, dock) = make(.on, marker: absent)
        suite.expect(hold.reconcile(wanted: false) && dock.events.isEmpty
                     && dock.value == .on && defaults.object(forKey: marker) == nil,
                     "rearranging the user turned back on themselves is kept and the marker forgotten")
        (hold, dock) = make(.absent, marker: on)
        suite.expect(hold.reconcile(wanted: false) && dock.events.isEmpty && dock.value == .absent,
                     "a key the user removed themselves is never written back")

        // MARK: Rearranging turned back on in System Settings

        let enabled = DefaultsKey.spacesOrderEnabled
        defaults.set(true, forKey: enabled)
        (hold, dock) = make(.on, marker: absent)
        suite.expect(hold.reconcile(wanted: true) && dock.events.isEmpty && dock.value == .on
                     && defaults.object(forKey: marker) == nil && !defaults.bool(forKey: enabled),
                     "a sync that finds rearranging back on keeps it and turns the feature off to match")
        defaults.set(true, forKey: enabled)
        (hold, dock) = make(.absent, marker: on)
        suite.expect(hold.reconcile(wanted: true) && dock.events.isEmpty && dock.value == .absent
                     && defaults.object(forKey: marker) == nil && !defaults.bool(forKey: enabled),
                     "a key removed while the feature was on is never turned off again")

        let available = AppFeature.spacesOrder.availabilityKey
        defaults.set(true, forKey: available)
        defaults.set(true, forKey: enabled)
        (hold, dock) = make(.off, marker: absent)
        suite.expect(!hold.letGoIfRearrangingReturned() && dock.events.isEmpty
                     && defaults.string(forKey: marker) == absent && defaults.bool(forKey: enabled),
                     "the check leaves a setting still held off alone")
        dock.value = .on
        suite.expect(hold.letGoIfRearrangingReturned() && dock.events.isEmpty
                     && defaults.object(forKey: marker) == nil && !defaults.bool(forKey: enabled),
                     "the check notices rearranging turned back on and turns the feature off")
        defaults.set(true, forKey: enabled)
        (hold, dock) = make(.on)
        suite.expect(!hold.letGoIfRearrangingReturned() && dock.events.isEmpty
                     && defaults.object(forKey: marker) == nil && defaults.bool(forKey: enabled),
                     "the check never turns rearranging off itself, so a hold is left to its own sync")
        defaults.set(false, forKey: available)
        (hold, dock) = make(.on, marker: absent)
        suite.expect(!hold.letGoIfRearrangingReturned() && defaults.string(forKey: marker) == absent,
                     "an uninstalled feature is left to its own sync, which restores or forgets")

        // The sync starts the watch, so the check needs no caller of its own.
        defaults.set(true, forKey: available)
        defaults.set(true, forKey: enabled)
        (hold, dock) = make(.off, marker: absent)
        dock.changeAfterFirstRead = .on
        hold.syncWithPreferences()
        let noticeDeadline = Date().addingTimeInterval(3)
        while defaults.string(forKey: marker) != nil, Date() < noticeDeadline {
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification,
                                                       object: nil)
            usleep(20_000)
        }
        suite.expect(defaults.object(forKey: marker) == nil && !defaults.bool(forKey: enabled)
                     && dock.events.isEmpty && dock.value == .on && dock.reads == 2,
                     "a Space change after rearranging is turned back on turns the feature off")
        defaults.removeObject(forKey: enabled)
        defaults.removeObject(forKey: available)

        // MARK: Managed settings

        for wanted in [true, false] {
            (hold, dock) = make(.unsupported)
            suite.expect(hold.reconcile(wanted: wanted) && dock.events.isEmpty
                         && defaults.object(forKey: marker) == nil,
                         "a managed setting is never changed and never marked (wanted: \(wanted))")
        }

        // MARK: Following the toggle and the hub

        // A feature's keys survive its removal from the hub, so the toggle
        // alone must never keep rearranging off.
        func waitForMarker(_ expected: String?) -> Bool {
            let deadline = Date().addingTimeInterval(3)
            while defaults.string(forKey: marker) != expected, Date() < deadline { usleep(10_000) }
            return defaults.string(forKey: marker) == expected
        }
        defaults.set(true, forKey: DefaultsKey.spacesOrderEnabled)
        defaults.set(true, forKey: available)
        (hold, dock) = make(.absent)
        hold.syncWithPreferences()
        suite.expect(dock.signals.wait(timeout: .now() + 3) == .success
                     && dock.events == ["live(false)"] && defaults.string(forKey: marker) == absent,
                     "an installed feature with its toggle on keeps Spaces in place")
        defaults.set(false, forKey: available)
        (hold, dock) = make(.off, marker: absent)
        hold.syncWithPreferences()
        suite.expect(dock.signals.wait(timeout: .now() + 3) == .success
                     && dock.signals.wait(timeout: .now() + 3) == .success
                     && waitForMarker(nil)
                     && dock.events == ["live(true)", "write(nil)"],
                     "uninstalling the feature restores the setting even with its toggle still on")
        defaults.removeObject(forKey: DefaultsKey.spacesOrderEnabled)
        defaults.removeObject(forKey: available)

        // MARK: Catalog

        let feature = AppFeature.spacesOrder
        suite.expect(feature.group == .windowsDock && feature.enabledKeys == [DefaultsKey.spacesOrderEnabled]
                     && feature.permissions.isEmpty && feature.energyProfile == .idle && !feature.isBeta,
                     "fixed Space order is an idle windows-and-Dock feature that needs no permission")
        suite.expect(feature.settingsDestination == FeatureSettingsDestination(.switcher, sectionAnchor: .spacesOrder)
                     && SettingsSectionAnchor.spacesOrder.page == .switcher
                     && FeatureVisibilitySupport.features(for: .switcher).contains(.spacesOrder),
                     "fixed Space order has its own card on the Switcher page")
        suite.expect(FeaturePreset.allCases.allSatisfy {
                         !$0.features.contains(.spacesOrder)
                             && !$0.enableKeys.contains(DefaultsKey.spacesOrderEnabled)
                     },
                     "no preset installs or turns on a feature that can restart the Dock")
        suite.expect(SettingsBackupSupport.machineStateKeys.contains(marker)
                     && !SettingsBackupSupport.exportKeys().contains(marker),
                     "the restore marker belongs to this Mac and never travels in a backup")
    }
}
