// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

public struct PackValidationReport: Sendable, Equatable {
    public var errors: [PackIssue]
    public var warnings: [PackIssue]
    /// pack 無效時為 nil
    public var capabilities: PackCapabilities?

    public init(errors: [PackIssue], warnings: [PackIssue], capabilities: PackCapabilities?) {
        self.errors = errors
        self.warnings = warnings
        self.capabilities = capabilities
    }

    public var isValid: Bool { errors.isEmpty }
}
