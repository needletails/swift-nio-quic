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

/// One network path for a connection.
///
/// The path is the bridge between SwiftNetwork and our code on the network-side. It is attached to
/// the SwiftNetwork `QUICConnection` as the lower datagram protocol of this path and deals with
/// both getting bytes in and out of it.
@available(anyAppleOS 26, *)
final class QUICConnectionPath<Consumer: QUICStreamConsumer & ~Copyable>:
    ExternalOutboundDatagramLinkage, ProtocolInstance
{

    typealias UpperProtocol = BaseInboundDatagramLinkage

    /// The endpoint information (IP, port) for this path.
    let remoteAddress: SocketAddress
    /// The address and port the way SwiftNetwork tells paths apart and names them in its events.
    let addressEndpointType: AddressEndpoint.AddressEndpointType
    /// QUIC path validation status.
    var isValidated: Bool
    /// After detaching the path SwiftNetwork, swift-nio-quic should keep the path until draining its outgoing packets.
    private(set) var isDetachedBySwiftNetwork = false

    private let logger: Logger
    private var logPrefix: String

    // SwiftNetwork requirements for protocol conformance
    internal var identifier = InstanceIdentifier()
    internal var eventManager = ProtocolEventManager()
    /// The connection's entry into its SwiftNetwork stack.
    internal let stack: SwiftNetworkStackAccess
    internal var context: NetworkContext { self.stack.context }
    private var upperProtocol = BaseInboundDatagramLinkage()

    private enum State {
        /// Not attached to a connection yet.
        case idle
        /// Attached to the related connection.
        case attached(SwiftNetworkQUICConnection<Consumer>.PathView)
        /// Detached from its connection on teardown.
        case detached
    }

    private var state: State = .idle

    private let framePool: FramePool
    private var coalescer: GSOCoalescer
    private var inputPacketQueue: FrameArray

    init(
        role: Role,
        remoteAddress: SocketAddress,
        stack: SwiftNetworkStackAccess,
        framePool: FramePool,
        isValidated: Bool,
        maxSegments: Int,
        bufferPoolCapacity: Int,
        logger: Logger
    ) {
        self.remoteAddress = remoteAddress
        self.addressEndpointType = remoteAddress.addressEndpointType
        self.isValidated = isValidated
        self.logPrefix = "[\(role.description)][Path]"
        self.logger = logger
        self.stack = stack
        self.framePool = framePool
        self.coalescer = GSOCoalescer(
            remoteAddress: remoteAddress,
            framePool: framePool,
            maxSegments: maxSegments,
            bufferPoolCapacity: bufferPoolCapacity
        )
        self.inputPacketQueue = FrameArray(capacity: 10)
        self.identifier = stack.register(&self.eventManager)
    }

    deinit {
        self.inputPacketQueue.finalizeAllFramesAsFailed()
        self.coalescer.finalizeAllFramesAsFailed()
    }

    /// Attaches the path to the connection behind `view`, which it reports to.
    ///
    /// Precondition: The current state must be idle.
    func attach(_ view: SwiftNetworkQUICConnection<Consumer>.PathView) {
        switch self.state {
        case .idle:
            self.state = .attached(view)
        case .attached, .detached:
            preconditionFailure("A path can only be attached from an idle state.")
        }
    }

    /// Log a message. Disabled in DEBUG builds.
    func log(_ logMessage: @autoclosure () -> String) {
        #if DEBUG
        let message = logMessage()
        self.logger.trace("\(self.logPrefix) \(message)")
        #endif
    }

    // Called from SwiftNetworkQUICConnection to notify the stack that there are inbound packets available.
    // This function is important for getting data into the stack
    func invokeInputAvailable() {
        guard !self.upperProtocol.isDetached else { return }
        try? self.stack.withEventContext(self.identifier) { eventContext in
            self.upperProtocol.deliverInboundDataAvailableEvent(from: self.identifier, in: &eventContext)
        }
    }

    /// Notify SwiftNetwork that the path is gone.
    func invokeDisconnected() {
        guard !self.upperProtocol.isDetached else { return }
        try? self.stack.withEventContext(self.identifier) { eventContext in
            self.upperProtocol.deliverDisconnectedEvent(error: nil, from: self.identifier, in: &eventContext)
        }
    }

    // MARK: - Inbound

    var hasQueuedInboundPackets: Bool {
        !self.inputPacketQueue.isEmpty
    }

    func enqueueInboundPacket(_ packet: NIOCore.ByteBuffer) {
        switch self.state {
        case .idle, .attached:
            var packet = packet
            packet.withUnsafeMutableReadableBytesWithStorageManagement2 { buffer, owner in
                self.inputPacketQueue.add(frame: Frame(customBuffer: buffer, owner: owner))
            }
        case .detached:
            // A late packet for a torn-down connection: drop it instead of holding it until deinit.
            return
        }
    }

    func drainInboundFrames(maximumDatagramCount: Int) -> FrameArray? {
        if self.inputPacketQueue.count == 0 {
            return nil
        }
        return self.inputPacketQueue.drainArray(maximumFrameCount: maximumDatagramCount)
    }

    func finalizeQueuedInboundFramesAsFailed() {
        self.inputPacketQueue.finalizeAllFramesAsFailed()
    }

    // MARK: - Outbound

    var hasQueuedOutboundData: Bool {
        !self.coalescer.isEmpty
    }

    func appendOutboundFrames(_ frames: consuming FrameArray) {
        self.coalescer.append(frames: frames)
    }

    func finalizeQueuedOutboundFramesAsFailed() {
        self.coalescer.finalizeAllFramesAsFailed()
    }

    /// Writes every packet queued for sending on this path to `transport`.
    func drainPacketsToSend(to transport: some QUICTransport) {
        while let packet = self.coalescer.next() {
            transport.writeDatagram(packet, promise: nil)
        }
    }

    // MARK: - Teardown

    /// Detaches the path from its connection and from SwiftNetwork, breaking the cycles with both. A detached path
    /// drops inbound packets and outbound datagrams.
    func detach() {
        self.state = .detached
        // SwiftNetwork's path holds this path as its lower protocol, so drop the reference back to it.
        self.upperProtocol = UpperProtocol()
    }
}

@available(anyAppleOS 26, *)
extension QUICConnectionPath where Consumer: ~Copyable {
    func protocolIsConnected(in eventContext: inout NetworkContext.EventContext) -> Bool {
        switch self.state {
        case .attached:
            return true
        case .idle, .detached:
            return false
        }
    }

    func getMetrics(
        requestedNetworkMetric: SwiftNetwork.RequestedNetworkMetrics,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> SwiftNetwork.NetworkMetrics? {
        nil
    }

    func getMetadata<P: NetworkProtocol>(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> ProtocolMetadata<P>? {
        nil
    }

    func disconnect(
        error: SwiftNetwork.NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        log("received disconnect")
        guard !self.upperProtocol.isDetached else { return }
        self.upperProtocol.deliverDisconnectedEvent(error: error, from: self.identifier, in: &eventContext)
    }

    func handleApplicationEvent(
        event: SwiftNetwork.ApplicationEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        log("application event: \(event)")
    }

    func connect(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        log("received connect")
        guard !self.upperProtocol.isDetached else { return }
        self.upperProtocol.deliverConnectedEvent(from: self.identifier, in: &eventContext)
    }

    func invokeAttachUpperProtocol(
        _ upperProtocol: BaseInboundDatagramLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        log("received attach upper protocol")
        self.upperProtocol = upperProtocol
    }

    func detach(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        log("received detach")
        // Do not reset the upper linkage here so the last packets can get out the door, e.g.,
        // APPLICATION_CLOSE or CONNECTION_CLOSE frames.
        self.isDetachedBySwiftNetwork = true
        switch self.state {
        case .attached(let connectionView):
            // The connection decides whether the path is still needed.
            connectionView.upperProtocolDetached(from: self)
        case .idle, .detached:
            break
        }
    }

    func teardown(in eventContext: inout NetworkContext.EventContext) {
        log("received teardown")
        self.unregisterEventManager(in: &eventContext)
    }

    func receiveDatagrams(
        maximumDatagramCount: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        self.drainInboundFrames(maximumDatagramCount: maximumDatagramCount)
    }

    func getDatagramsToSend(
        maximumDatagramCount: Int,
        minimumDatagramSize: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        var array = FrameArray(capacity: maximumDatagramCount)

        for _ in 0..<maximumDatagramCount {
            let frame = self.framePool.takeOrCreateFrame(minimumSize: minimumDatagramSize)
            array.add(frame: frame)
        }

        return array
    }

    func sendDatagrams(
        _ datagrams: consuming FrameArray,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        log("received finalize output frames")
        switch self.state {
        case .attached(let connectionView):
            let count = datagrams.count
            self.appendOutboundFrames(datagrams)
            connectionView.outboundDatagramsQueued(on: self, count: count)
        case .idle, .detached:
            self.logger.error("path is not attached: dropping frame array with \(datagrams.count) frames")
            datagrams.finalizeAllFramesAsFailed()
        }
    }
}
