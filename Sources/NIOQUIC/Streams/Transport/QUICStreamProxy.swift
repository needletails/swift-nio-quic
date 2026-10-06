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

import NIOQUICHelpers
@_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetwork

#if canImport(Android)
import Android
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// External stream linkage for one table slot.
///
/// Every delivery lends its event context to the table, which may call back into the stack while
/// handling it.
@available(anyAppleOS 26, *)
final class QUICStreamProxy<Consumer: QUICStreamConsumer & ~Copyable>: ExternalInboundStreamLinkage, ProtocolInstance {
    let table: QUICStreamTable<Consumer>
    let handle: QUICStreamHandle
    var context: NetworkContext { self.table.stack.context }
    var identifier: InstanceIdentifier
    var eventManager = ProtocolEventManager()

    init(table: QUICStreamTable<Consumer>, handle: QUICStreamHandle) {
        self.table = table
        self.handle = handle
        self.identifier = InstanceIdentifier()
        self.identifier = table.stack.register(&self.eventManager)
    }

    func invokeAttachLowerProtocol(
        _ lowerProtocol: BaseOutboundStreamLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        throw NetworkError.posix(ENOTSUP)
    }

    func handleConnectedEvent(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        self.table.stack.lending(&eventContext) {
            self.table.streamConnected(self.handle)
        }
    }

    func handleDisconnectedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        self.table.stack.lending(&eventContext) {
            self.table.streamDisconnected(self.handle, error: error)
        }
    }

    func handleInboundDataAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        self.table.stack.lending(&eventContext) {
            self.table.markReady(handle: self.handle, events: .readable)
        }
    }

    func handleOutboundRoomAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        self.table.stack.lending(&eventContext) {
            self.table.markReady(handle: self.handle, events: .writable)
        }
    }

    func handleInboundAbortedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        guard let code = Self.applicationErrorCode(error) else { return }
        self.table.stack.lending(&eventContext) {
            self.table.peerResetStream(self.handle, code: code)
        }
    }

    func handleOutboundAbortedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        guard let code = Self.applicationErrorCode(error) else { return }
        self.table.stack.lending(&eventContext) {
            self.table.peerStoppedSending(self.handle, code: code)
        }
    }

    func handleNetworkProtocolEvent(
        event: NetworkProtocolEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        ()
    }

    private static func applicationErrorCode(_ error: NetworkError?) -> QUICApplicationErrorCode? {
        switch error?.quicApplicationError {
        case .some(let code) where code >= 0:
            return QUICApplicationErrorCode(UInt64(code))
        case .some, .none:
            return nil
        }
    }
}
