// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation
import Testing
@testable import FindMouseDomain

@Test func manifestDecodesFromSpecShapedJSON() throws {
    let json = """
    {
      "schemaVersion": 1,
      "id": "fluffy-orange",
      "name": "橘色蓬鬆貓",
      "logicalHeight": 96,
      "anchor": { "x": 0.5, "y": 0.94 },
      "facing": "right",
      "mirrorForOpposite": true,
      "actions": {
        "run": { "frames": 8, "fps": 14, "loop": true },
        "sit": { "frames": 4, "fps": 10, "loop": false }
      }
    }
    """
    let manifest = try JSONDecoder().decode(PackManifest.self, from: Data(json.utf8))
    #expect(manifest.id == "fluffy-orange")
    #expect(manifest.logicalHeight == 96)
    #expect(manifest.anchor.y == 0.94)
    #expect(manifest.facing == .right)
    #expect(manifest.actions["run"]?.frames == 8)
    #expect(manifest.actions["sit"]?.loop == false)
    #expect(manifest.author == nil)
}

@Test func reportIsValidOnlyWhenErrorsEmpty() {
    let ok = PackValidationReport(errors: [], warnings: [.inconsistentSizeAcrossActions], capabilities: nil)
    #expect(ok.isValid == true)

    let bad = PackValidationReport(errors: [.invalidID("Bad ID")], warnings: [], capabilities: nil)
    #expect(bad.isValid == false)
}

@Test func fileListingCountsFrames() {
    let listing = PackFileListing(directories: [
        "run": [.init(name: "000.png", size: CGSize(width: 256, height: 256)),
                .init(name: "001.png", size: CGSize(width: 256, height: 256))]
    ])
    #expect(listing.directories["run"]?.count == 2)
}
