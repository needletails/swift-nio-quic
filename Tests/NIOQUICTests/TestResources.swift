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

/// Path of a test resource (`testcert.pem`, `testkey.pem`, `privateKey.der`, `publicKey.der`).
///
/// On Android the generated `Bundle.module` accessor fatals unless
/// `swift-nio-quic_NIOQUICTests.bundle` is installed next to the process. `skip android test`
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
        "testcert.pem": """
        LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSURFakNDQWZvQ0NRRFVFVnhTRjRneVF6QU5C
        Z2txaGtpRzl3MEJBUXNGQURCTE1Rc3dDUVlEVlFRR0V3SlYKVXpFVE1CRUdBMVVFQ0F3S1EyRnNh
        V1p2Y201cFlURVRNQkVHQTFVRUNnd0tRWEJ3YkdVZ1NXNWpMakVTTUJBRwpBMVVFQXd3SmJHOWpZ
        V3hvYjNOME1CNFhEVEl3TURneU5qQTVNVEl5TVZvWERUTXdNRGd5TkRBNU1USXlNVm93ClN6RUxN
        QWtHQTFVRUJoTUNWVk14RXpBUkJnTlZCQWdNQ2tOaGJHbG1iM0p1YVdFeEV6QVJCZ05WQkFvTUNr
        RncKY0d4bElFbHVZeTR4RWpBUUJnTlZCQU1NQ1d4dlkyRnNhRzl6ZERDQ0FTSXdEUVlKS29aSWh2
        Y05BUUVCQlFBRApnZ0VQQURDQ0FRb0NnZ0VCQUxDMkdCcllmVURXUERFcHdxTEdRUG8veE1XZURn
        d0VseGlJSUk2Ky9VVVIrc3dZCmlzRCs1UDZjU0JwWW1HQzVRTUtiZXoza0tVdVNxNHFzVHRHWUx6
        TmFndnRjZnNrWmVjd01WQS8xb0VWNWlCVlcKNmZ5ME9GcXI2c2VwUFR6K09tcitmc0VTaStiWTBt
        NDNPZFgzWUxxM3ptYVdHVkNIUlpuQkZld0kvM2ZRTjhpYwpwUzkvVXRCOVZNMHZGbWt3TGczTURC
        ak1ZNDRCWkE5dCtvUFVjQ0RrZGhNVStVS2cyMERRTE5XTFFvVUlRazhHCnBGcjhEZkhmc0pXSG94
        TXpLSjZoS0w3WVB1V0NLdnh6bHh2Q0hCWmVsV3laeUhRQmJjQ1dhK3BSTDBtQk5JNEgKeGQ4cWJ1
        QkhpU2FFci8yYStZdGowN1VZQXlhRmdLMkR5bnNVRmlrQ0F3RUFBVEFOQmdrcWhraUc5dzBCQVFz
        RgpBQU9DQVFFQWJ2cDBEM3ZkOTFsRktkSDZXMWNhdDVmY1NSOGF2eVRob2s4WDJsTjVLOWVlUEND
        cXdBMkFXR1hnClYrczZGNFloVlRyQysvSVVVZUJFWUtYSDZIakp2dGxtWnNLdEtYK2hiakhIazlV
        WlFVcmxPbXY3MS9semRsRU8KQlBLZFhqVTBMdkpCWnkxY3FiN2pOOUdScktNNE56YmJwTlFFY092
        ekZlVUtUVnZ0MS81c2pCZ1FJNTY3THFocApXN2creHFHd21oQ0I4cTBQdHRLUm1hai91aDJDOHZk
        dmU2Rm5Idzd0NGtZUkVBNHRndWo1b21KbSt5eDVzQTNVCnRKdFY3dFhhWXJDcVpqdVJJTG1BK3JV
        QUFPVXZPSE1TeWhndUtFQ2JmbDFwUzd5ZE83SHBseHp1aU53SE85WDMKRi9RYkJzaWROU0pFT0ND
        ZlVlTEdLcGlCTDN5a0V3PT0KLS0tLS1FTkQgQ0VSVElGSUNBVEUtLS0tLQo=
        """,
        "testkey.pem": """
        LS0tLS1CRUdJTiBQUklWQVRFIEtFWS0tLS0tCk1JSUV2Z0lCQURBTkJna3Foa2lHOXcwQkFRRUZB
        QVNDQktnd2dnU2tBZ0VBQW9JQkFRQ3d0aGdhMkgxQTFqd3gKS2NLaXhrRDZQOFRGbmc0TUJKY1lp
        Q0NPdnYxRkVmck1HSXJBL3VUK25FZ2FXSmhndVVEQ20zczk1Q2xMa3F1SwpyRTdSbUM4eldvTDdY
        SDdKR1huTURGUVA5YUJGZVlnVlZ1bjh0RGhhcStySHFUMDgvanBxL243QkVvdm0yTkp1Ck56blY5
        MkM2dDg1bWxobFFoMFdad1JYc0NQOTMwRGZJbktVdmYxTFFmVlROTHhacE1DNE56QXdZekdPT0FX
        UVAKYmZxRDFIQWc1SFlURlBsQ29OdEEwQ3pWaTBLRkNFSlBCcVJhL0EzeDM3Q1ZoNk1UTXlpZW9T
        aSsyRDdsZ2lyOApjNWNid2h3V1hwVnNtY2gwQVczQWxtdnFVUzlKZ1RTT0I4WGZLbTdnUjRrbWhL
        Lzltdm1MWTlPMUdBTW1oWUN0Cmc4cDdGQllwQWdNQkFBRUNnZ0VCQUoxLzcwUWVLS1VkVFZEVVU3
        SVkyZGt4OVFQZHQ4OW1WL1Y1ZnVzN3R5bFUKdVNBbno2UHNpOVdUSFlDOTdqSm5heDBJejNOK1pJ
        QURIZm5mVWZEbG4wdzZJL3c5bUpOTXJZMzhmd0FxZ01ycgpZeXNCNkZOZm5jclM1OU5GT0Z1Z2pC
        akk4OWpKMnYvSnlPU0xQSFZFbzJaSVpTSnlMZVhrYTFoN0REcndXaUpDCmJCRHVZT0xubDlneGhr
        L3g0eVNkMlRjM2dYNjRwTjhMZ1FVc3pxRFZyelVXbzRuV0tlVjhnM2pZQzIwK2t6Y0QKWW82bmtX
        VEV0ZkFnYmdqc2NWbm9RNkl4NCtxUTA4WU9MaEwrMkpQVGQ0bVduRFRUOUcybmg0VmxjeVZ5UTNT
        WApaSlJyd2NkMHVNellFTmY0WHpIYmVabTErWVdWbjFXRTBxWDRPUDlkZEFFQ2dZRUExTkc1M3BH
        ckJzUFFkU1YyCmtLV1F3dGhDOWpuS21tZ000cTU4OEVENFA4cGhUMnhpNnkzUnZLbkxOWXByWlFk
        ZEVBdmM2Z3JJdnJqRGxuTy8KQVMyeHpSSGZ3alVlK3hQRzROSjBFQjhhbTU1andCSFdhUVpnOXV5
        eVpNZTJnd0pDbG9nTDY4bFl1SndQcFFlbQpvazRFcjVPNWY5REx5dVNxM0M3YUFNTW55K0VDZ1lF
        QTFKRFl4b0YyYlFzSjk4blZwUmtVak83ME5rc0ZmSXByCjdJRm1lbzRuSWRQMEdTSUluMXY1RU8x
        M0VsOW1EazZJODcwNE5UZ2Fwa2JPOExOODBlY1RjNFZlVHQ2ZkVGcXMKSklWR3RCM2JiaTM1T3ZK
        MGc3RXNMYUlaZFhwV3dWcnJSWDZUWEErVnVKTGJaRnRwdE11MlNPU1RpbzNrbDVNNwpDdmQ0eTFu
        QlUwa0NnWUVBd2hlTUJwcWZlZ240QWY3cXhUemFhM2xFaUw5b01hNFhvbDAwZ1FFZjV6Mnh4ZmU1
        CnQzY1FRNW92UkdNN1V1YUdUMjRpU2lrUHNERmQzOGNzT2V6c3JYUlJ1Qk11Y0JvM1ZTOWF2cUUv
        YVJIcE0zQ1IKTlRPbUYwMEQzYm51a0VqdFpkQXAzeDdBbFkxdkR6bU5GWlZGM01ORGVIaDZoRTVN
        TFlkbE56REZDTUVDZ1lCVApvUWtvVUJiL243QTBSTHhCVURTOW5lV0cxczA1eWx2Ym1LMXcyaXli
        S29DR3d0VVJuV1hJT3lUMW5ZTFJiaVNECmdKWjBtYllpWlFsVnVjZ0o3UmZDQTE2dk9QYnJ3RUNw
        dmFXcmgzT2xUWUVZcC9zZk5MMWsxcm1kZHB4YlJpSDYKSFdwc2RkVTU0TTFnRm5ib0lwMTg0REVM
        K2ZkTml5ZFhrVFY5QzdyN3dRS0JnR0Zka3gzYk11MmllY2pib0lxYwpxNHNTYTdGZkZBWGVvSmJU
        RWQ1bHFSWUVBWmxCNjVVYnJ1R280blBRYTFMY2tQVStSNjd3TUMrUTJDZllXMXJwCnJZbU1Zd0VG
        T1dISHBDUTJ1cHFNejZaam5rcGt3cFZpUnBuU2hUNWtjNGhkTUZkNDZxbFN4YkU4OVVXTFNGREoK
        MWFRU2s0UlYvTEw5Zy9oZTZUUWJGaE5xCi0tLS0tRU5EIFBSSVZBVEUgS0VZLS0tLS0K
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
