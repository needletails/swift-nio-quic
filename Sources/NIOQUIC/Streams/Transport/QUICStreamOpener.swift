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

@_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetwork

/// What a stream table needs to attach a locally-opened stream to the stack.
@available(anyAppleOS 26, *)
struct QUICStreamOpener {
    /// The SwiftNetwork connection that owns the stream listener.
    var connection: SwiftNetwork.QUICConnection

    /// The connection's entry into its SwiftNetwork stack.
    let stack: SwiftNetworkStackAccess

    /// Attaches a new outbound flow for a stream.
    mutating func attach(
        isUnidirectional: Bool,
        upper: BaseInboundStreamLinkage
    ) throws(NetworkError) -> BaseOutboundStreamLinkage {
        var parameters = SwiftNetwork.Parameters()
        parameters.context = self.stack.context
        let path = SwiftNetwork.PathProperties(parameters: parameters)

        let options = QUICStreamProtocol.options()
        options.isUnidirectional = isUnidirectional
        options.setProtocolInstance(self.connection.identifier)
        parameters.defaultStack.prepend(applicationProtocol: options)

        // Creating the flow only binds the upper linkage. Attaching that upper back onto the
        // flow is what runs the stream's setup, which is where the stack assigns its ID.
        let linkage = try self.connection.attachUpperProtocolToNewFlow(
            upper,
            remote: nil,
            local: nil,
            parameters: parameters,
            path: path
        )
        try linkage.invokeAttachUpperProtocol(
            upper,
            remote: nil,
            local: nil,
            parameters: parameters,
            path: path
        )
        return linkage
    }
}
