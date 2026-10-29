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
import NIOQUICHelpers
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

/// `QUICChannelNewFlowHandler` is responsible for dealing with new SwiftNetwork 'flows' initiated by the other end of the connection.
/// A flow in this case is a new stream of data that is registered with the QUIC stack and is represented here by `QUICChannelStreamHandler`.
/// The `QUICChannelNewFlowHandler` registered with the SwiftNetwork `QUICConnection` as a new flow handler.
/// This object deals with creating and linking the objects describing a new flow, it creates a new `QUICChannelStreamHandler`
/// for each new flow, registers it and keeps track of it.
@available(anyAppleOS 26, *)
final class QUICChannelNewFlowHandler<Consumer: QUICStreamConsumer & ~Copyable>:
    ExternalInboundStreamFlowLinkage, ProtocolInstance
{

    typealias UpperStreamHandlerType = QUICChannelStreamHandler

    // Internal mutable state
    internal var eventManager = ProtocolEventManager()
    internal var logPrefix: String
    internal var identifier = InstanceIdentifier()
    /// The connection's entry into its SwiftNetwork stack.
    internal let stack: SwiftNetworkStackAccess
    internal var context: NetworkContext { self.stack.context }
    private var connection: SwiftNetwork.QUICConnection
    /// The linkage control calls reach the connection through.
    private let listener: BaseStreamListenerLinkage

    // Private constant state
    let local: Endpoint
    let remote: Endpoint
    let parameters: Parameters
    let path: PathProperties
    let role: Role
    let logger: Logger
    let remoteAddress: SendableAddress
    let localAddress: SocketAddress
    /// The connection channel which is the parent of inbound stream channels created by this handler.
    /// Set via ``setConnectionChannel(_:)`` once the connection channel has been created.
    private var connectionChannel: (any Channel)?

    // Private mutable state
    // This view is set in the call the `start` and is required for operation. It uses
    // an implicitly unwrapped optionals because Swift's initialization rules prevent
    // passing 'self' method references during init.
    private var connectionView: SwiftNetworkQUICConnection<Consumer>.NewFlowView!

    // Internal mutable state
    var keepAliveInterval: Duration?

    /// The stream table inbound flows attach to, or nil if inbound streams become
    /// child channels.
    var streamTable: QUICStreamTable<Consumer>?

    internal init?(
        local: Endpoint,
        remote: Endpoint,
        stack: SwiftNetworkStackAccess,
        parameters: Parameters,
        path: PathProperties,
        logger: Logger,
        remoteAddress: SendableAddress,
        localAddress: SocketAddress,
        role: Role,
        connection: SwiftNetwork.QUICConnection,
        listener: BaseStreamListenerLinkage,
        keepAliveInterval: Duration? = nil
    ) {
        self.local = local
        self.remote = remote
        self.stack = stack
        self.parameters = parameters
        self.path = path
        self.role = role
        self.logger = logger
        self.remoteAddress = remoteAddress
        self.keepAliveInterval = keepAliveInterval
        self.logPrefix = "[\(self.role.description)][NewFlowHandler]"
        self.localAddress = localAddress
        self.connection = connection
        self.listener = listener
        self.identifier = stack.register(&self.eventManager)
        do throws(NetworkError) {
            try self.connection.attachUpperProtocol(
                BaseInboundStreamFlowLinkage(external: self),
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        } catch {
            return nil
        }
    }

    // Set the parent (connection) channel that inbound streams will use as their parent.
    // Called once the connection child channel has been created.
    func setConnectionChannel(_ channel: any Channel) {
        self.connectionChannel = channel
    }

    // Drop the strong reference to the connection channel, breaking the channel <-> connection
    // retain cycle once the channel has gone inactive.
    func clearConnectionChannel() {
        self.connectionChannel = nil
    }

    /// Local logging function to debug the datapath
    ///
    /// This layer adds the context and fetches the message only if the debug flags are enabled.
    ///
    /// - Parameters:
    ///     - logMessage: The logMessage that is fetched by an autoclosure.  For performance reasons we could gate this behind a flag.
    func log(_ logMessage: @autoclosure () -> String) {
        #if DEBUG
        let message = logMessage()
        self.logger.trace("\(self.logPrefix) \(message)")
        #endif
    }

    // Start the new flow handler
    func start(_ view: SwiftNetworkQUICConnection<Consumer>.NewFlowView) {
        log("start")
        self.connectionView = view
        try? self.stack.withEventContext(self.identifier) { eventContext in
            self.listener.invokeConnect(for: self.identifier, in: &eventContext)
        }
    }

    // Fetch QUIC metadata via the main connection (listener) linkage.
    // `connectionMetadata.activeConnectionIDLimit` is the peer's advertised cap
    // on how many connection IDs we may issue (RFC 9000 §18.2).
    func getConnectionMetadata() -> ProtocolMetadata<QUICProtocol>? {
        try? self.stack.withEventContext(self.identifier) { eventContext in
            self.listener.invokeGetMetadata(for: self.identifier, in: &eventContext) as ProtocolMetadata<QUICProtocol>?
        }
    }

    // Stop the new flow handler
    func stop(error: NetworkError? = nil) {
        log("stop")
        try? self.stack.withEventContext(self.identifier) { eventContext in
            self.listener.invokeDisconnect(error: error, for: self.identifier, in: &eventContext)
        }
    }

    // Teardown the new flow handler
    internal func teardown() {
        try? self.stack.withEventContext(self.identifier) { eventContext in
            do throws(NetworkError) {
                try self.listener.invokeDetach(for: self.identifier, in: &eventContext)
            } catch {
                self.log("Failed to detach lower protocol: \(error)")
            }
        }
        self.stack.release(self)
    }

    func outboundBatching(_ isEnabled: Bool) {
        let event: ApplicationEvent = isEnabled ? .outboundDataBatchStart : .outboundDataBatchEnd
        try? self.stack.withEventContext(self.identifier) { eventContext in
            self.listener.invokeApplicationEvent(event: event, for: self.identifier, in: &eventContext)
        }
    }

    func handleConnectedEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        log("connected received")
        self.stack.lending(&eventContext) {
            self.connectionView.connected()
        }
    }

    func handleDisconnectedEvent(
        error: SwiftNetwork.NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        log("received disconnected with error: \(String(describing: error))")
        self.stack.lending(&eventContext) {
            self.connectionView.disconnected(error: error)
        }
        self.connectionView = nil
    }

    func invokeAttachLowerProtocol(
        _ lowerProtocol: BaseStreamListenerLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        throw NetworkError.posix(ENOTSUP)
    }

    // Receive a new inbound flow and either give it a slot in the stream table or
    // create a QUICChannelStreamHandler for it.
    internal func handleNewInboundFlowEvent(
        flowInstance: InstanceIdentifier,
        flowMetadata: AbstractProtocolMetadata?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        log("received new inbound flow")

        guard let metadata = flowMetadata as? ProtocolMetadata<QUICProtocol>,
            let inputHandlerStreamID = metadata.streamID
        else {
            logger.error("Could not create new stream handler: invalid metadata")
            return
        }

        self.stack.lending(&eventContext) {
            self.handleNewInboundFlow(
                flowInstance: flowInstance,
                metadata: metadata,
                streamID: QUICStreamID(rawValue: inputHandlerStreamID)
            )
        }
    }

    private func handleNewInboundFlow(
        flowInstance: InstanceIdentifier,
        metadata: ProtocolMetadata<QUICProtocol>,
        streamID: QUICStreamID
    ) {
        // Before the connection channel is required below: a connection using a stream
        // table has no child channel to parent the stream to.
        if let table = self.streamTable {
            self.attachInboundFlowToTable(table, flowInstance: flowInstance, streamID: streamID)
        } else if let connectionChannel = self.connectionChannel {
            do throws(NetworkError) {
                let streamHandler = QUICChannelStreamHandler(
                    role: self.role,
                    stack: self.stack,
                    streamID: streamID,
                    logger: self.logger,
                    remoteAddress: self.remoteAddress,
                    localAddress: self.localAddress,
                    connectionChannel: connectionChannel,
                    keepAliveInterval: keepAliveInterval
                )
                streamHandler.keepaliveConfigurator = { [weak streamHandler] seconds, _ in
                    streamHandler?.configureKeepaliveAfterDelivery(seconds: seconds)
                }

                let linkage = try self.connection.attachUpperProtocolToExistingFlow(
                    BaseInboundStreamLinkage(external: streamHandler),
                    existingFlowInstance: flowInstance
                )
                streamHandler.swiftNetworkStreamHandle = SwiftNetworkStreamHandle(linkage: linkage)
                streamHandler.setNewFlowMetadata(metadata)
                streamHandler.start(fromNewFlowHandler: true)
                self.connectionView.newInboundStream(streamHandler)

                // For new inbound flows, only set the keep-alive interval once for the connection.
                // That means only the first flow should send the interval into QUICChannelStreamHandler
                self.keepAliveInterval = nil
            } catch {
                self.log("Failed to attach new inbound flow: \(error)")
            }
        } else {
            fatalError("connection channel is not available")
        }
    }

    private func attachInboundFlowToTable(
        _ table: QUICStreamTable<Consumer>,
        flowInstance: InstanceIdentifier,
        streamID: QUICStreamID
    ) {
        // No state: the consumer makes it in 'makeStreamState' before the first visit.
        let handle = table.insertSlot(id: streamID, state: nil)
        let proxy = table.external(for: handle)
        let linkage: BaseOutboundStreamLinkage
        do throws(NetworkError) {
            linkage = try self.connection.attachUpperProtocolToExistingFlow(
                BaseInboundStreamLinkage(external: proxy),
                existingFlowInstance: flowInstance
            )
        } catch {
            self.log("Failed to attach new inbound flow: \(error)")
            table.vacateSlot(handle)
            return
        }

        guard let transport = table.transportState(for: handle) else {
            preconditionFailure("slot for \(handle) was recycled while its flow was attaching")
        }

        transport.pointee.core.attach(
            identifier: proxy.identifier,
            stack: self.stack,
            linkage: linkage
        )

        table.assignID(streamID, to: handle)
        try? self.stack.withEventContext(proxy.identifier) { eventContext in
            linkage.invokeConnect(for: proxy.identifier, in: &eventContext)
        }
        table.markReady(handle: handle, events: [.opened, .readable])
    }
}

@available(anyAppleOS 26, *)
extension QUICChannelNewFlowHandler where Consumer: ~Copyable {
    func handleNetworkProtocolEvent(
        event: SwiftNetwork.NetworkProtocolEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        self.log("Network protocol event from \(instance): \(event)")
        self.stack.lending(&eventContext) {
            self.handleNetworkProtocolEvent(event)
        }
    }

    private func handleNetworkProtocolEvent(_ event: SwiftNetwork.NetworkProtocolEvent) {
        if let quicEvent = event.quicEvent {
            switch quicEvent {
            case .newInboundConnectionID(let connectionID):
                self.log("New inbound connection ID \(connectionID)")
                let nioConnectionID = NIOQUIC.QUICConnectionID(connectionID)
                self.connectionView.associateConnectionID(nioConnectionID)
            case .retiredInboundConnectionID(let connectionID):
                self.log("Retired inbound connection ID \(connectionID)")
                let nioConnectionID = NIOQUIC.QUICConnectionID(connectionID)
                self.connectionView.retireConnectionID(nioConnectionID)
            case .newOutboundConnectionID:
                break
            case .retiredOutboundConnectionID:
                break
            case .earlyDataRejected:
                break
            case .maxStreamsLimitBidirectionalUpdated:
                break
            case .maxStreamsLimitUnidirectionalUpdated:
                break
            case .receivedRemoteTransportParameters:
                // Note: This one is for early data.
                break
            case .remoteBidirectionalStreamsBlocked:
                break
            case .remoteUnidirectionalStreamsBlocked:
                break
            case .pathChanged:
                // SwiftNetwork announces a path as soon as it is attached. Not much to do at that point.
                break
            case .pathValidated(let info):
                self.connectionView.pathValidated(remote: info.remote)
            case .pathUnreachable(let info):
                self.connectionView.pathUnreachable(remote: info.remote)
            case .pathCIDAssigned:
                break
            case .pathCurrent:
                break
            }
        } else {
            // There might be more that we are interested in.
        }
    }

    // Request association of a new connection ID that our peer can use to contact us.
    func requestAssociationOfConnectionID(
        _ connectionID: QUICConnectionID,
        statelessResetToken: SwiftNetwork.QUICStatelessResetToken
    ) {
        self.log("New connection ID: '\(connectionID)'")

        let cid = SwiftNetwork.QUICConnectionID(connectionID)

        let quicEvent = QUICApplicationEvent.announceNewInboundConnectionID(
            cid,
            statelessResetToken: statelessResetToken
        )
        let event = ApplicationEvent(quicEvent: quicEvent)

        try? self.stack.withEventContext(self.identifier) { eventContext in
            self.listener.invokeApplicationEvent(event: event, for: self.identifier, in: &eventContext)
        }
    }

    // Request retirement of a connection ID that we are using to address our peer.
    func requestsRetirementOfConnectionID(_ connectionID: QUICConnectionID) {
        self.log("Retiring connection ID: '\(connectionID)'")

        let cid = SwiftNetwork.QUICConnectionID(connectionID)
        let quicEvent = QUICApplicationEvent.retireOutboundConnectionID(cid)
        let event = ApplicationEvent(quicEvent: quicEvent)

        try? self.stack.withEventContext(self.identifier) { eventContext in
            self.listener.invokeApplicationEvent(event: event, for: self.identifier, in: &eventContext)
        }
    }
}

@available(anyAppleOS 26, *)
extension QUICChannelNewFlowHandler where Consumer: ~Copyable {
    /// Attach the datagram flow to the connection.
    ///
    /// Note: This must run after the peer's transport parameters are applied: SwiftNetwork computes the
    /// flow's usable datagram size only at attach time (`updateUsableDatagramFrameSize`), from
    /// `remoteMaxDatagramFrameSize`, which is `0` until the handshake completes. Attaching earlier
    /// freezes the usable size at `0` and datagrams can never be sent.
    ///
    /// - Returns: The transport for the attached flow, or `nil` if it could not be attached.
    func attachDatagramFlow() -> QUICDatagramTransport<Consumer>? {
        do {
            let transport = QUICDatagramTransport<Consumer>(
                role: self.role,
                logger: self.logger,
                stack: self.stack
            )

            var swiftNetworkParameters = SwiftNetwork.Parameters()
            swiftNetworkParameters.context = self.stack.context
            let swiftNetworkPath = SwiftNetwork.PathProperties(parameters: swiftNetworkParameters)
            let quicOptions = QUICStreamProtocol.options()
            guard quicOptions.perProtocolOptions != nil else {
                throw QUICError.invalidConfiguration
            }
            quicOptions.modifyPerProtocolOptions { $0.isDatagram = true }
            quicOptions.setProtocolInstance(self.connection.identifier)
            swiftNetworkParameters.defaultStack.prepend(applicationProtocol: quicOptions)

            let upper = BaseInboundDatagramLinkage(external: transport)
            let linkage = try self.connection.attachUpperProtocolToNewFlow(
                upper,
                remote: nil,
                local: nil,
                parameters: swiftNetworkParameters,
                path: swiftNetworkPath
            )
            // The second leg runs the flow's setup, which sizes the datagrams it can carry.
            try linkage.invokeAttachUpperProtocol(
                upper,
                remote: nil,
                local: nil,
                parameters: swiftNetworkParameters,
                path: swiftNetworkPath
            )
            transport.setFlowLinkage(linkage)
            try? self.stack.withEventContext(transport.identifier) { eventContext in
                linkage.invokeConnect(for: transport.identifier, in: &eventContext)
            }

            return transport
        } catch {
            self.logger.error("\(self.logPrefix) Failed to attach QUIC datagram flow: \(error)")
            return nil
        }
    }
}
