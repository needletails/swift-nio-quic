//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation

/// Path of a test resource (`privateKey.der`, `publicKey.der`).
///
/// On Android the generated `Bundle.module` accessor fatals unless
/// `swift-nio-quic_IntegrationTests.bundle` is installed next to the process. `skip android test`
/// does not upload that bundle, so the same bytes are written beside the test process instead.
func testResourcePath(_ name: String, withExtension ext: String) -> String {
    #if os(Android)
    return AndroidTestResources.path(forResource: name, withExtension: ext)
    #else
    return Bundle.module.url(forResource: name, withExtension: ext)!.path
    #endif
}

#if os(Android)
private enum AndroidTestResources {
    private static let payloads: [String: String] = [
        "privateKey.der": """
        MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgAwx2URy4NAHA77bWmUT6k5cplHkF
        welMaFOWHN1qyeyhRANCAARVi0dP1kVNh4FvNibyhsbOkFFFXy9GFzuS/e4c2eG9BwiQ3SS48L7J
        +ekRfoPi9AIDoElOCi7l2jwjy3sBbVxN
        """,
        "publicKey.der": """
        MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEVYtHT9ZFTYeBbzYm8obGzpBRRV8vRhc7kv3uHNnh
        vQcIkN0kuPC+yfnpEX6D4vQCA6BJTgou5do8I8t7AW1cTQ==
        """,
    ]

    static func path(forResource name: String, withExtension ext: String) -> String {
        let key = "\(name).\(ext)"
        guard let encoded = payloads[key], let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)
        else {
            fatalError("missing embedded test resource \(key)")
        }
        let url = resourceDirectory().appendingPathComponent(key)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            fatalError("unable to write test resource \(key): \(error)")
        }
        return url.path
    }

    private static func resourceDirectory() -> URL {
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
            FileManager.default.temporaryDirectory,
        ]
        for base in candidates {
            let directory = base.appendingPathComponent("nioquic-test-resources", isDirectory: true)
            if (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil {
                return directory
            }
        }
        fatalError("unable to create a directory for test resources")
    }
}
#endif
