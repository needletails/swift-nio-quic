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

import NIOEmbedded
@_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetwork
import Testing

@testable import NIOQUIC

/// Records the order in which the steps of a test ran.
private final class Steps {
    var recorded: [String] = []
}

/// A protocol instance with no behaviour of its own, registered with a stack for a test.
@available(anyAppleOS 26, *)
private final class TestInstance: ProtocolInstance {
    let context: NetworkContext
    var identifier = InstanceIdentifier()
    var eventManager = ProtocolEventManager()

    init(stack: SwiftNetworkStackAccess) {
        self.context = stack.context
        self.identifier = stack.register(&self.eventManager)
    }
}

/// A value which can only be passed on, not copied.
private struct Token: ~Copyable {
    let value: Int
}

private struct TestError: Error {}

@Suite
struct SwiftNetworkStackAccessTests {
    /// Runs `body` with a stack and an instance registered with it, which is released afterwards.
    @available(anyAppleOS 26, *)
    private func withInstance(_ body: (SwiftNetworkStackAccess, TestInstance) throws -> Void) rethrows {
        // An embedded loop counts the thread driving it as its own, so the stack runs inline.
        let context = NetworkContext(
            identifier: "test-context",
            externalScheduler: EventLoopBackedScheduler(eventLoop: EmbeddedEventLoop())
        )
        let stack = SwiftNetworkStackAccess(context: context)
        let instance = TestInstance(stack: stack)
        defer { stack.release(instance) }
        try body(stack, instance)
    }

    @available(anyAppleOS 26, *)
    @Test
    func nestedCallsShareTheEventContextOfTheCallInProgress() throws {
        try self.withInstance { stack, instance in
            // Entering the stack again while a call holds the event context would trip exclusivity
            // enforcement, so this only completes if the nested call reuses the outer one's context.
            let depth = try stack.withEventContext(instance.identifier) { _ in
                try stack.withEventContext(instance.identifier) { _ in
                    try stack.withEventContext(instance.identifier) { _ in 3 }
                }
            }
            #expect(depth == 3)
        }
    }

    @available(anyAppleOS 26, *)
    @Test
    func workOutsideACallRunsInline() {
        self.withInstance { stack, _ in
            let steps = Steps()
            stack.outsideDelivery { steps.recorded.append("work") }
            steps.recorded.append("after")
            #expect(steps.recorded == ["work", "after"])
        }
    }

    @available(anyAppleOS 26, *)
    @Test
    func workDuringACallRunsOnceTheOutermostCallReturns() throws {
        try self.withInstance { stack, instance in
            let steps = Steps()
            try stack.withEventContext(instance.identifier) { _ in
                try stack.withEventContext(instance.identifier) { _ in
                    stack.outsideDelivery { steps.recorded.append("first") }
                    stack.outsideDelivery { steps.recorded.append("second") }
                    steps.recorded.append("inner call")
                }
                steps.recorded.append("outer call")
            }
            steps.recorded.append("returned")
            #expect(steps.recorded == ["inner call", "outer call", "first", "second", "returned"])
        }
    }

    @available(anyAppleOS 26, *)
    @Test
    func deferredWorkCanEnterTheStack() throws {
        try self.withInstance { stack, instance in
            let steps = Steps()
            try stack.withEventContext(instance.identifier) { _ in
                stack.outsideDelivery {
                    // No call holds the event context any more, so this enters the stack afresh.
                    try? stack.withEventContext(instance.identifier) { _ in
                        steps.recorded.append("entered")
                    }
                }
            }
            #expect(steps.recorded == ["entered"])
        }
    }

    @available(anyAppleOS 26, *)
    @Test
    func deferredWorkRunsWhenTheCallThrows() {
        self.withInstance { stack, instance in
            let steps = Steps()
            #expect(throws: TestError.self) {
                try stack.withEventContext(instance.identifier) { _ in
                    stack.outsideDelivery { steps.recorded.append("work") }
                    throw TestError()
                }
            }
            #expect(steps.recorded == ["work"])
        }
    }

    @available(anyAppleOS 26, *)
    @Test
    func valueIsPassedThroughToTheBody() throws {
        try self.withInstance { stack, instance in
            let outside = try stack.withEventContext(instance.identifier, Token(value: 1)) { _, token in
                token.value
            }
            let nested = try stack.withEventContext(instance.identifier) { _ in
                try stack.withEventContext(instance.identifier, Token(value: 2)) { _, token in
                    token.value
                }
            }
            #expect(outside == 1)
            #expect(nested == 2)
        }
    }

    @available(anyAppleOS 26, *)
    @Test
    func noncopyableResultIsReturned() throws {
        try self.withInstance { stack, instance in
            let token = try stack.withEventContext(instance.identifier) { _ in Token(value: 4) }
            let value = token.value
            #expect(value == 4)
        }
    }

    @available(anyAppleOS 26, *)
    @Test
    func instancesRegisterInsideAndOutsideACall() throws {
        try self.withInstance { stack, instance in
            #expect(!instance.identifier.isNone)

            let registeredDuringACall = try stack.withEventContext(instance.identifier) { _ in
                TestInstance(stack: stack)
            }
            #expect(!registeredDuringACall.identifier.isNone)
            #expect(registeredDuringACall.identifier != instance.identifier)
            stack.release(registeredDuringACall)
        }
    }

    @available(anyAppleOS 26, *)
    @Test
    func releaseHandsBackTheEventStateOnce() {
        self.withInstance { stack, _ in
            let instance = TestInstance(stack: stack)
            stack.release(instance)
            #expect(instance.identifier.isNone)

            // A second release has nothing left to hand back.
            stack.release(instance)
            #expect(instance.identifier.isNone)
        }
    }
}
