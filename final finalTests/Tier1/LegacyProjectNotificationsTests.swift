//
//  LegacyProjectNotificationsTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, rounds C5b and C8b (slice-3a-1b-everyday.md section 4.4 "Keyed posts" and section 5.5):
//  how ContentView's handlers treat `.projectDidOpen`, `.projectDidCreate` and `.projectDidClose`.
//
//    - A post that carries `userInfo["lifecycleToken"]` was made by a `perform` that ran inside `LifecycleEntry.run`:
//      the managed tail does the work, so the handler does NOTHING (C5b, unchanged).
//    - Since round C8b every production post is keyed, or is the Getting Started close, which carries its own marker
//      (`LifecycleEntry.gettingStartedCloseUserInfo`) and runs `onClosed`. Anything else is an UNKEYED post: a call
//      site that was missed. The handler does nothing (the old flush-back-up-reopen path is gone) and hits the DEBUG
//      hook (`LifecycleEntry.noteUnkeyedPost`), a counter and a log line, never an assertion, so a test or the e2e can
//      prove none is left. Before C8b an unkeyed post still ran the old handler; those tests are rewritten here.
//
//  These drive `LegacyProjectNotifications`, the code `withFileNotifications` delegates all three `.onReceive`
//  closures to, with real `Notification` values. The hook's counter is process-global DEBUG state, so the suite nests
//  under `LifecycleEntryStatic` like every suite that touches `LifecycleEntry`'s static state.
//

import Foundation
import Testing
@testable import final_final

extension LifecycleEntryStatic {
    @Suite("Project posts at the old ContentView handlers — Tier 1 (t-94369a83 3a-1b C5b, C8b)", .serialized)
    @MainActor
    struct LegacyProjectNotificationsTests {

        private func post(_ name: Notification.Name, keyed: Bool, extra: [AnyHashable: Any] = [:]) -> Notification {
            var info = extra
            if keyed { info[LifecycleEntry.tokenUserInfoKey] = UUID() }
            return Notification(name: name, object: nil, userInfo: info.isEmpty ? nil : info)
        }

        private func gettingStartedClose() -> Notification {
            Notification(name: .projectDidClose, object: nil, userInfo: LifecycleEntry.gettingStartedCloseUserInfo)
        }

        @Test("""
            the key a managed post carries is userInfo["lifecycleToken"] (its presence, any value, makes a post keyed); the \
            Getting Started close carries userInfo["gettingStartedClose"] = true instead
            """)
        func theKeysAreTheOnesThePlanNames() {
            #expect(LifecycleEntry.tokenUserInfoKey == "lifecycleToken")
            #expect(LifecycleEntry.isKeyed(post(.projectDidOpen, keyed: true)))
            #expect(!LifecycleEntry.isKeyed(post(.projectDidOpen, keyed: false)))
            #expect(!LifecycleEntry.isKeyed(Notification(name: .projectDidOpen)), "no userInfo at all is unkeyed")
            #expect(LifecycleEntry.gettingStartedCloseUserInfoKey == "gettingStartedClose")
            #expect(LifecycleEntry.isGettingStartedClose(gettingStartedClose()))
            #expect(!LifecycleEntry.isGettingStartedClose(post(.projectDidClose, keyed: true)))
            #expect(!LifecycleEntry.isGettingStartedClose(Notification(name: .projectDidClose)))
        }

        // MARK: - Keyed: ignored, and not counted

        @Test("a KEYED post of each kind is ignored: the handler body never runs and the unkeyed hook stays silent")
        func keyedPostsAreIgnored() {
            LifecycleEntry.resetForTests()
            defer { LifecycleEntry.resetForTests() }
            var closed = 0

            let opened = LegacyProjectNotifications.opened(post(.projectDidOpen, keyed: true))
            let created = LegacyProjectNotifications.created(post(.projectDidCreate, keyed: true, extra: ["content": "# Imported"]))
            let closedRouting = LegacyProjectNotifications.closed(post(.projectDidClose, keyed: true)) { closed += 1 }

            #expect(opened == .ignoredKeyed)
            #expect(created == .ignoredKeyed)
            #expect(closedRouting == .ignoredKeyed)
            #expect(closed == 0)
            #expect(LifecycleEntry.testUnkeyedPosts.isEmpty, "a keyed post is the normal case, never a fallback hit")
        }

        // MARK: - The Getting Started close

        @Test("the Getting Started close runs onClosed exactly once and is NOT an unkeyed post (the hook stays silent)")
        func gettingStartedCloseRunsTheHandler() {
            LifecycleEntry.resetForTests()
            defer { LifecycleEntry.resetForTests() }
            var closed = 0

            let routing = LegacyProjectNotifications.closed(gettingStartedClose()) { closed += 1 }

            #expect(routing == .gettingStartedClose)
            #expect(closed == 1)
            #expect(LifecycleEntry.testUnkeyedPosts.isEmpty)
        }

        // MARK: - Unkeyed: the DEBUG hook

        @Test("""
            an UNKEYED .projectDidOpen reaches the fallback: the handler does nothing (no flush, no reopen) and the DEBUG \
            hook records it -- a missed call site is visible, not silently half-working
            """)
        func unkeyedOpenHitsTheHook() {
            LifecycleEntry.resetForTests()
            defer { LifecycleEntry.resetForTests() }

            let plain = LegacyProjectNotifications.opened(post(.projectDidOpen, keyed: false))
            let restore = LegacyProjectNotifications.opened(post(.projectDidOpen, keyed: false, extra: ["isRestore": true]))

            #expect(plain == .unkeyed)
            #expect(restore == .unkeyed, "carrying other userInfo does not make a post keyed")
            #expect(LifecycleEntry.testUnkeyedPosts == ["projectDidOpen", "projectDidOpen"])
        }

        @Test("an UNKEYED .projectDidCreate (content or not) hits the hook and seeds nothing")
        func unkeyedCreateHitsTheHook() {
            LifecycleEntry.resetForTests()
            defer { LifecycleEntry.resetForTests() }

            let withContent = LegacyProjectNotifications.created(post(.projectDidCreate, keyed: false, extra: ["content": "# Imported"]))
            let withoutContent = LegacyProjectNotifications.created(post(.projectDidCreate, keyed: false))

            #expect(withContent == .unkeyed)
            #expect(withoutContent == .unkeyed)
            #expect(LifecycleEntry.testUnkeyedPosts == ["projectDidCreate", "projectDidCreate"])
        }

        @Test("an UNKEYED, UNMARKED .projectDidClose hits the hook and does NOT run onClosed (only the Getting Started close does)")
        func unkeyedCloseHitsTheHook() {
            LifecycleEntry.resetForTests()
            defer { LifecycleEntry.resetForTests() }
            var closed = 0

            let routing = LegacyProjectNotifications.closed(post(.projectDidClose, keyed: false)) { closed += 1 }

            #expect(routing == .unkeyed)
            #expect(closed == 0)
            #expect(LifecycleEntry.testUnkeyedPosts == ["projectDidClose"])
        }

        @Test("the Getting Started marker only means something on .projectDidClose: on an open post it is still an unkeyed hit")
        func theMarkerIsNotAKeyOnOtherPosts() {
            LifecycleEntry.resetForTests()
            defer { LifecycleEntry.resetForTests() }
            let marked = Notification(
                name: .projectDidOpen, object: nil, userInfo: LifecycleEntry.gettingStartedCloseUserInfo)

            #expect(LegacyProjectNotifications.opened(marked) == .unkeyed)
            #expect(LifecycleEntry.testUnkeyedPosts == ["projectDidOpen"])
        }

        @Test("resetForTests clears the hook's record (the harness resets it around every lifecycle test)")
        func resetClearsTheRecord() {
            LifecycleEntry.resetForTests()
            LegacyProjectNotifications.opened(post(.projectDidOpen, keyed: false))
            #expect(!LifecycleEntry.testUnkeyedPosts.isEmpty)
            LifecycleEntry.resetForTests()
            #expect(LifecycleEntry.testUnkeyedPosts.isEmpty)
        }
    }
}
