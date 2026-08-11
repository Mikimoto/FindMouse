// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

#!/usr/bin/env swift
// 印出鼠標的全域座標（原點左下、Y 向上），與 status --json 同一個座標系。
// e2e 用它當 ground truth：本機的游標會自己漂移，所以斷言只能比對
// 「同一時刻的真實位置」與「App 回報的位置」，不能比對「我要求的位置」。
import AppKit
let p = NSEvent.mouseLocation
print("\(p.x) \(p.y)")
