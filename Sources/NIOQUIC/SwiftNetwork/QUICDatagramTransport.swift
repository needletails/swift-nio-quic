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
@_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetwork

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(Musl)
import Musl
#endif

/// Implementation of `QUICDatagramProtocol` backed by a SwiftNetwork QUIC datagram flow.
///
/// Conforms to SwiftNetwork's `ExternalInboundDatagramLinkage` so the stack can deliver
/// inbound datagram events. The connection which owns it talks to it only through
/// `QUICDatagramProtocol`.
@available(anyAppleOS 26, *)
final class QUICDatagramTransport<Consumer: QUICStreamConsumer & ~Copyable>:
    ExternalInboundDatagramLinkage, ProtocolInstance
{

    typealias LowerProtocol = BaseOutboundDatagramLinkage

    internal var identifier = InstanceIdentifier()
    internal var eventManager = ProtocolEventManager()
    /// The datagram flow this transport sends and receives on. Replaced with a live linkage by
    /// `setFlowLinkage(_:)` once the flow has been attached.
    internal var lower = BaseOutboundDatagramLinkage()
    /// The connection's entry into its SwiftNetwork stack.
    internal let stack: SwiftNetworkStackAccess
    internal var context: NetworkContext { self.stack.context }

    internal var logPrefix: String
    internal let logger: Logger

    /// Datagrams written since the last successful `flush()`.
    private var bufferedDatagrams: TinyArray<ByteBuffer> = []

    /// The connection notified of inbound datagrams and errors.
    private var reader: SwiftNetworkQUICConnection<Consumer>?

    init(role: Role, logger: Logger, stack: SwiftNetworkStackAccess) {
        self.logPrefix = "[\(role.description)][DatagramTransport]"
        self.logger = logger
        self.stack = stack
        self.identifier = stack.register(&self.eventManager)
    }

    /// Installs the flow linkage returned by attaching this transport to a new datagram flow.
    func setFlowLinkage(_ linkage: BaseOutboundDatagramLinkage) {
        self.lower = linkage
    }

    func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        self.logger.trace("\(self.logPrefix) \(message())")
        #endif
    }
}

@available(anyAppleOS 26, *)
extension QUICDatagramTransport: QUICDatagramProtocol where Consumer: ~Copyable {
    /// Buffers `datagram` for the next `flush()`, always returning `true`.
    ///
    /// Datagram delivery is unreliable: buffering here always succeeds, but the datagram may still
    /// be dropped later. SwiftNetwork enforces the real on-the-wire size at packetization (the
    /// peer's `max_datagram_frame_size` and the path MTU), so this method does not itself
    /// reject oversized datagrams.
    func write(datagram: NIOCore.ByteBuffer) -> Bool {
        self.bufferedDatagrams.append(datagram)
        return true
    }

    /// Sends all buffered datagrams if the flow is connected.
    func flush() {
        guard self.bufferedDatagrams.count > 0, !self.lower.isDetached else {
            return
        }

        do {
            try self.stack.withEventContext(self.identifier) { eventContext in
                guard self.lower.isConnected(in: &eventContext) else { return }
                self.log("writing \(self.bufferedDatagrams.count) QUIC datagrams")
                var frameArray = FrameArray(capacity: self.bufferedDatagrams.count)
                for var datagram in self.bufferedDatagrams {
                    datagram.withUnsafeMutableReadableBytesWithStorageManagement2 { buffer, owner in
                        frameArray.add(frame: Frame(customBuffer: buffer, owner: owner))
                    }
                }
                try self.lower.invokeSendDatagrams(
                    frameArray,
                    from: self.identifier,
                    in: &eventContext
                )
                self.bufferedDatagrams.removeAll(where: { _ in true })
            }
        } catch {
            self.logger.error("QUIC send datagrams: \(error)")
            self.reader?.error(error)
        }
    }

    /// Clears the reader and detaches the underlying flow.
    func close() {
        // Log dropped datagrams.
        if !self.bufferedDatagrams.isEmpty {
            self.logger.debug(
                "\(self.logPrefix) dropping \(self.bufferedDatagrams.count) unflushed datagrams on close"
            )
        }

        // Cleanup linkage with SwiftNetwork.
        do {
            try self.stack.withEventContext(self.identifier) { eventContext in
                try self.lower.invokeDetach(for: self.identifier, in: &eventContext)
            }
        } catch {
            self.logger.error("datagram flow detach failed: \(error)")
        }
        self.stack.release(self)

        // Remove reference to reader.
        self.reader = nil
    }

    /// Register the connection which owns this transport as its reader.
    ///
    /// This can only hold one endpoint. Each call overwrite the previously set reader.
    func setReader(connection: SwiftNetworkQUICConnection<Consumer>) {
        self.reader = connection
    }
}

@available(anyAppleOS 26, *)
extension QUICDatagramTransport where Consumer: ~Copyable {
    /// Drains all datagrams currently available on the flow and forwards each to the reader.
    /// Does nothing if no reader has been set.
    func handleInboundDataAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        guard let reader = self.reader else {
            self.log("handle inbound data, but no reader set")
            return
        }

        // The reader fires each datagram into the channel pipeline, which may write back.
        self.stack.lending(&eventContext) {
            do {
                try self.stack.withEventContext(self.identifier) { eventContext in
                    while var frames = try self.lower.invokeReceiveDatagrams(
                        maximumDatagramCount: .max,
                        for: self.identifier,
                        in: &eventContext
                    ), frames.count > 0 {
                        frames.iterateMutableFrames { frame in
                            frame.span?.withUnsafeBufferPointer { spanBuffer in
                                var datagram = ByteBuffer()
                                datagram.writeWithUnsafeMutableBytes(
                                    minimumWritableBytes: spanBuffer.count
                                ) { buffer in
                                    buffer.copyMemory(from: UnsafeRawBufferPointer(spanBuffer))
                                    return spanBuffer.count
                                }
                                reader.read(datagram: datagram)
                            }
                            frame.finalize(success: true)
                            return true
                        }
                    }
                }
            } catch {
                self.logger.error("QUIC datagram receive error: \(error)")
            }
        }
    }
}

// Connection events are already handled by the `QUICChannelNewFlowHandler`.
@available(anyAppleOS 26, *)
extension QUICDatagramTransport where Consumer: ~Copyable {
    func invokeAttachLowerProtocol(
        _ lowerProtocol: BaseOutboundDatagramLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        throw NetworkError.posix(ENOTSUP)
    }

    func handleOutboundRoomAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        // nop
    }

    func handleConnectedEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        log("received connected event")
        // Defer connection-level handling to `SwiftNetworkQUICConnection`.
    }

    func handleDisconnectedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        log("received disconnected event, error \(error.debugDescription)")
        // Defer connection-level handling to `SwiftNetworkQUICConnection`.
    }

    func handleNetworkProtocolEvent(
        event: NetworkProtocolEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        // nop
    }
}
