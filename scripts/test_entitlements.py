#!/usr/bin/env python3
"""Verify Pastemin's StoreKit entitlement decisions."""
from pathlib import Path
import subprocess
import tempfile

from build import ROOT, swift_compiler

fixture = r'''
import Foundation

@main
enum EntitlementTests {
    static func main() {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
        }

        let now = Date()
        check(PasteminFreeAccessPolicy.isTrialActive(
            startedAt: now,
            now: now.addingTimeInterval(29 * 24 * 60 * 60)
        ), "The local trial remains active through day 29")
        check(!PasteminFreeAccessPolicy.isTrialActive(
            startedAt: now,
            now: now.addingTimeInterval(30 * 24 * 60 * 60)
        ), "The local trial expires at 30 days")
        check(PasteminFreeAccessPolicy.trialDaysRemaining(startedAt: now, now: now) == 30,
              "A new local trial reports 30 days")

        let localStart = now.addingTimeInterval(24 * 60 * 60)
        check(PasteminFreeAccessPolicy.authoritativeTrialStartDate(
            appStoreOriginalPurchaseDate: now,
            localStartedAt: localStart,
            usesAppStoreDate: true
        ) == now, "The signed App Store date overrides local state")
        check(PasteminFreeAccessPolicy.authoritativeTrialStartDate(
            appStoreOriginalPurchaseDate: nil,
            localStartedAt: localStart,
            usesAppStoreDate: true
        ) == nil, "A missing signed date never falls back to local state")
        check(PasteminFreeAccessPolicy.authoritativeTrialStartDate(
            appStoreOriginalPurchaseDate: nil,
            localStartedAt: localStart,
            usesAppStoreDate: false
        ) == localStart, "Source builds retain their local trial date")

        let yearly = PasteminTransactionSummary(
            productID: PasteminProductID.yearly,
            expirationDate: now.addingTimeInterval(3600),
            revocationDate: nil,
            isFamilyShared: false,
            isIntroductoryOffer: true
        )
        let trial = PasteminEntitlementLogic.evaluate([yearly])
        check(trial.kind == .subscription && trial.isTrial, "An introductory subscription is a trial")

        let lifetime = PasteminTransactionSummary(
            productID: PasteminProductID.lifetime,
            expirationDate: nil,
            revocationDate: nil,
            isFamilyShared: true,
            isIntroductoryOffer: false
        )
        let permanent = PasteminEntitlementLogic.evaluate([yearly, lifetime])
        check(permanent.kind == .lifetime && permanent.isFamilyShared, "Lifetime access wins")

        var revoked = lifetime
        revoked.revocationDate = now
        check(!PasteminEntitlementLogic.evaluate([revoked]).hasAccess, "Revoked purchases do not unlock")
        print("Pastemin entitlement logic passed")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='pastemin-entitlement-test-', dir='/private/tmp') as folder_name:
    folder = Path(folder_name)
    main = folder / 'main.swift'
    main.write_text(fixture)
    output = folder / 'tests'
    command = swift_compiler() + [
        '-parse-as-library', '-swift-version', '5',
        '-module-cache-path', str(folder / 'modules'),
        '-target', 'arm64-apple-macos14.0',
        str(ROOT / 'Sources/PasteminApp/PasteminEntitlementLogic.swift'),
        str(main), '-o', str(output),
    ]
    subprocess.run(command, check=True)
    subprocess.run([str(output)], check=True)
