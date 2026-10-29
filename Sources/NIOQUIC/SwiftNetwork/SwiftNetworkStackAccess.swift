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

/// A connection's entry into its SwiftNetwork stack.
///
/// The stack hands its event context to every call it makes into this module and expects that same
/// context to be threaded into any call made back into the stack while the delivery is running:
/// acquiring it afresh from the ``NetworkContext`` at that point overlaps the stack's own access and
/// trips exclusivity enforcement. NIO's channel API has no way to carry the context through a
/// pipeline, so a delivery lends its context here for its duration (``lending(_:_:)``) and calls made
/// in the meantime pick it up (``withEventContext(_:_:)``). A call made from outside any delivery
/// enters the stack as an external caller instead.
///
/// One instance is shared by everything attached to a connection's stack, since the stack keeps one
/// event context per ``NetworkContext``. Like the context it wraps, it is only used on the
/// connection's event loop.
@available(anyAppleOS 26, *)
final class SwiftNetworkStackAccess: @unchecked Sendable {
    /// The context which owns the stack's state.
    let context: NetworkContext

    /// The event context of the call into the stack which is in progress, if any.
    ///
    /// Only valid while the call which set it is running.
    private var lentEventContext: UnsafeMutablePointer<NetworkContext.EventContext>?

    /// Work that must run after the outermost entry into the stack has released the event context.
    ///
    /// `NIOAsyncTestingEventLoop.execute` only records a task while a callback is already running on
    /// the loop, and the integration tests drive that loop with `readOutbound` / `writeInbound`,
    /// which never drain recorded tasks. Running the work here, once this entry's `fromExternal`
    /// has returned, keeps it on the loop and ahead of the caller's next read.
    private var pendingOutsideDelivery: [() -> Void] = []

    init(context: NetworkContext) {
        self.context = context
    }

    /// Pairs an identifier with the stack's context so the stack can be entered from outside.
    ///
    /// `NetworkContext.eventContext` is internal to SwiftNetwork; the only public external entry
    /// is `ProtocolInstance.fromExternal(_:)`, which derives the event context from `context`.
    private struct ExternalEntry: ProtocolInstance, ~Copyable {
        let context: NetworkContext
        var identifier: InstanceIdentifier
        var eventManager = ProtocolEventManager()
    }

    private func externalEntry(_ identifier: InstanceIdentifier) -> ExternalEntry {
        ExternalEntry(context: self.context, identifier: identifier)
    }

    /// Runs `body`, a delivery from the stack, lending `eventContext` to any call made back into the
    /// stack while it runs.
    func lending<R>(
        _ eventContext: inout NetworkContext.EventContext,
        _ body: () throws -> R
    ) rethrows -> R {
        try withUnsafeMutablePointer(to: &eventContext) { pointer in
            try self.lending(pointer, body)
        }
    }

    /// Runs `body` with the stack's event context.
    ///
    /// Reuses the context of the call in progress if there is one; otherwise enters the stack from
    /// outside on behalf of `identifier`.
    func withEventContext<R: ~Copyable>(
        _ identifier: InstanceIdentifier,
        _ body: (inout NetworkContext.EventContext) throws -> R
    ) throws -> R {
        if let lent = self.lentEventContext {
            return try body(&lent.pointee)
        }
        defer { self.runPendingOutsideDelivery() }
        return try self.externalEntry(identifier).fromExternal { eventContext in
            try withUnsafeMutablePointer(to: &eventContext) { pointer in
                try self.lending(pointer) {
                    try body(&pointer.pointee)
                }
            }
        }
    }

    /// Runs `body` with the stack's event context, passing `value` through to it.
    ///
    /// Reuses the context of the call in progress if there is one; otherwise enters the stack from
    /// outside on behalf of `identifier`.
    func withEventContext<R, T: ~Copyable>(
        _ identifier: InstanceIdentifier,
        _ value: consuming T,
        _ body: (inout NetworkContext.EventContext, consuming T) throws -> R
    ) throws -> R {
        if let lent = self.lentEventContext {
            return try body(&lent.pointee, value)
        }
        // A closure can't consume what it captures, so the value is parked where the one call to
        // `body` can take it from.
        var parked: T? = consume value
        defer { self.runPendingOutsideDelivery() }
        return try self.externalEntry(identifier).fromExternal { eventContext in
            try withUnsafeMutablePointer(to: &eventContext) { pointer in
                try self.lending(pointer) {
                    try body(&pointer.pointee, parked.take()!)
                }
            }
        }
    }

    /// Runs `body` once no call into the stack is in progress.
    ///
    /// Attaching a new flow is the one thing the stack does not take an event context for: it
    /// acquires the context itself, so it cannot run while a delivery holds it. When called from
    /// inside a delivery, `body` runs once the outermost ``withEventContext(_:_:)`` has returned;
    /// otherwise it runs inline.
    func outsideDelivery(_ body: @escaping () -> Void) {
        if self.lentEventContext == nil {
            body()
        } else {
            self.pendingOutsideDelivery.append(body)
        }
    }

    /// Runs work queued by ``outsideDelivery(_:)`` during the entry that just released the context.
    private func runPendingOutsideDelivery() {
        while !self.pendingOutsideDelivery.isEmpty {
            let body = self.pendingOutsideDelivery.removeFirst()
            body()
        }
    }

    /// Registers `eventManager` with the stack and returns the identifier which names it.
    ///
    /// Protocols implemented in this module are created both from outside the stack and from
    /// inside a delivery (a connected event opening the datagram flow, for one), so registration
    /// goes through the lent context when there is one for the same reason calls do.
    func register(_ eventManager: inout ProtocolEventManager) -> InstanceIdentifier {
        if let lent = self.lentEventContext {
            return InstanceIdentifier(eventManager: &eventManager, in: &lent.pointee)
        }
        return InstanceIdentifier(context: self.context, eventManager: &eventManager)
    }

    /// Hands `instance`'s event state back to the stack, if it still holds one.
    ///
    /// Nothing below a protocol implemented in this module releases its state for it, so each
    /// one does this as part of its own teardown.
    func release<Instance: ProtocolInstance & AnyObject>(_ instance: Instance) {
        guard !instance.identifier.isNone else { return }
        try? self.withEventContext(instance.identifier) { eventContext in
            instance.unregisterEventManager(in: &eventContext)
        }
    }

    private func lending<R: ~Copyable>(
        _ pointer: UnsafeMutablePointer<NetworkContext.EventContext>,
        _ body: () throws -> R
    ) rethrows -> R {
        let previous = self.lentEventContext
        self.lentEventContext = pointer
        defer { self.lentEventContext = previous }
        return try body()
    }
}
