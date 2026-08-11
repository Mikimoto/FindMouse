#!/usr/bin/env swift
// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

// 把鼠標移到指定的**全域座標**（原點左下、Y 向上，與 status --json 一致）。
// 用法：Scripts/warp-cursor.swift <x> <y>
//
// 為什麼自己寫而不用 cliclick：多一個外部依賴，而 e2e 要在乾淨的機器上跑得起來。
// 為什麼不放進專案的任何 target：`CGWarpMouseCursorPosition` 正是
// ArchitectureBoundaryTests 註解點名的「CoreGraphics 給得出但不該進 Domain」的函式。
// 一支獨立腳本讓它離所有 target 都很遠。
import AppKit
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 3,
      let x = Double(CommandLine.arguments[1]),
      let y = Double(CommandLine.arguments[2]) else {
    FileHandle.standardError.write(Data("用法：warp-cursor.swift <x> <y>\n".utf8))
    exit(2)
}

// CGWarpMouseCursorPosition 吃的是**事件座標**（原點左上、Y 向下），
// 而我們的介面是全域座標。主螢幕高度就是兩者的換算基準。
// 不翻轉的話，「往上移」的斷言會在兩個座標系裡都成立一半，測不出東西。
let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
CGWarpMouseCursorPosition(CGPoint(x: x, y: mainHeight - y))
CGAssociateMouseAndMouseCursorPosition(1)

// 印出**實際**落點的全域座標。
//
// 系統不保證鼠標會停在要求的位置（多螢幕錯位排列時，要求的點可能不在任何一片
// 螢幕上，游標會被拉到最近的合法位置）。呼叫端要拿這個回報值去比對，
// 而不是拿自己傳進來的值——後者測的是這支腳本，不是被測的 App。
let actual = NSEvent.mouseLocation
print("\(actual.x) \(actual.y)")
