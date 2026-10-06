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

import Logging
import NIOCore
import NIOEmbedded
@_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetwork
import Testing

@testable import NIOQUIC

struct QUICConnectionPathTests {
    /// Runs `body` with a path which is torn down afterwards, as the stack would, so its event
    /// state is handed back.
    @available(anyAppleOS 26, *)
    private func withPath(
        isValidated: Bool = false,
        remoteAddress: SocketAddress = try! SocketAddress(ipAddress: "127.0.0.1", port: 9000),
        _ body: (QUICConnectionPath<QUICStreamChannels>) throws -> Void
    ) throws {
        let eventLoop = EmbeddedEventLoop()
        let context = NetworkContext(
            identifier: "test-context",
            externalScheduler: EventLoopBackedScheduler(eventLoop: eventLoop)
        )
        let path = QUICConnectionPath<QUICStreamChannels>(
            role: .server,
            remoteAddress: remoteAddress,
            stack: SwiftNetworkStackAccess(context: context),
            framePool: .makePool(forGSO: false),
            isValidated: isValidated,
            maxSegments: 1,
            bufferPoolCapacity: 8,
            logger: Logger(label: "test")
        )
        defer {
            try? path.stack.withEventContext(path.identifier) { eventContext in
                path.teardown(in: &eventContext)
            }
        }
        try body(path)
    }

    @available(anyAppleOS 26, *)
    @Test
    func freshPathHasNoQueuedData() throws {
        try self.withPath { path in
            #expect(!path.hasQueuedInboundPackets)
            #expect(!path.hasQueuedOutboundData)
        }
    }

    @available(anyAppleOS 26, *)
    @Test
    func enqueueInboundPacketTracksQueue() throws {
        try self.withPath { path in
            path.enqueueInboundPacket(ByteBuffer(repeating: 0xAA, count: 100))
            #expect(path.hasQueuedInboundPackets)
        }
    }

    @available(anyAppleOS 26, *)
    @Test
    func drainInboundFramesEmptiesQueue() throws {
        try self.withPath { path in
            path.enqueueInboundPacket(ByteBuffer(repeating: 0xAA, count: 50))
            var drained = path.drainInboundFrames(maximumDatagramCount: 10)
            if drained == nil {
                Issue.record("Expected non-nil drained frames")
            } else {
                drained!.finalizeAllFramesAsFailed()
            }
            #expect(!path.hasQueuedInboundPackets)
        }
    }

    @available(anyAppleOS 26, *)
    @Test
    func drainInboundFramesReturnsNilWhenEmpty() throws {
        try self.withPath { path in
            let result = path.drainInboundFrames(maximumDatagramCount: 10)
            if result != nil {
                Issue.record("Expected nil when draining empty queue")
            }
        }
    }

    @available(anyAppleOS 26, *)
    @Test
    func idlePathDropsOutboundDatagrams() throws {
        try self.withPath { path in
            try path.stack.withEventContext(path.identifier) { eventContext in
                if let datagrams = try path.getDatagramsToSend(
                    maximumDatagramCount: 2,
                    minimumDatagramSize: 100,
                    for: path.identifier,
                    in: &eventContext
                ) {
                    try path.sendDatagrams(datagrams, from: path.identifier, in: &eventContext)
                }
            }
            #expect(!path.hasQueuedOutboundData)
        }
    }

    @available(anyAppleOS 26, *)
    @Test
    func detachedPathDropsInboundPackets() throws {
        try self.withPath { path in
            path.detach()

            path.enqueueInboundPacket(ByteBuffer(repeating: 0xAA, count: 50))
            #expect(!path.hasQueuedInboundPackets)
        }
    }
}
