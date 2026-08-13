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

// MARK: - version 欄位（分發 C 加的）

/// 加 `version` 是純加法：`JSONDecoder` 忽略未知欄位、而缺少 optional 欄位不是
/// 錯誤。既有三套 pack（mycat／test-blocks／test-blocks-tall）的 pack.json
/// 都沒有它，所以這條同時是「不用動它們」的證據。
@Test func aManifestWithoutAVersionStillDecodes() throws {
    let json = """
    {"schemaVersion":1,"id":"cat","name":"貓","logicalHeight":96,
     "anchor":{"x":0.5,"y":0.94},"facing":"right","mirrorForOpposite":true,
     "actions":{"run":{"frames":2,"fps":14,"loop":true}}}
    """
    let m = try JSONDecoder().decode(PackManifest.self, from: Data(json.utf8))
    #expect(m.version == nil)
}

@Test func aManifestWithAVersionKeepsItVerbatim() throws {
    let json = """
    {"schemaVersion":1,"id":"cat","name":"貓","version":"2026.08","logicalHeight":96,
     "anchor":{"x":0.5,"y":0.94},"facing":"right","mirrorForOpposite":true,
     "actions":{"run":{"frames":2,"fps":14,"loop":true}}}
    """
    let m = try JSONDecoder().decode(PackManifest.self, from: Data(json.utf8))
    #expect(m.version == "2026.08", "原樣保留，不正規化——正規化就是在猜語意")
}
