//
//  Channel.swift
//  SwiftChan
//
//  Created by Willa Drengwitz on 9/1/15.
//  Copyright (c) 2015 Eksdyne Research. All rights reserved.
//

import Foundation

public class WaitForSend<V> {
	private let comm: GCDHandoff<V>

	init() {
		comm = GCDHandoff<V>()
	}

	init(syncedComm: GCDHandoff<V>) {
		comm = syncedComm
	}

	private func send(v: V) -> HandoffResult {
		return comm.senderEnter(v)
	}

	private func waitForSender() -> HandoffReceiveResult<V> {
		return comm.receiverEnter()
	}
}

public class WaitForRecv<V> {
	private let comm: GCDHandoff<V>

	init() {
		comm = GCDHandoff<V>()
	}

	init(syncedComm: GCDHandoff<V>) {
		comm = syncedComm
	}

	private func recv() -> HandoffReceiveResult<V> {
		return comm.receiverEnter()
	}

	private func waitForRecv(v: V) -> HandoffResult {
		return comm.senderEnter(v)
	}
}

// What is about to happen as a thread enters into a receive action on a channel.
public enum Receive<V> {
	case FromSender(WaitForRecv<V>)
	case Block(WaitForSend<V>)
}

// What is about to happen as a thread enters into a send action on a channel.
public enum Send<V> {
	case ToReceiver(WaitForSend<V>)
	case Block(WaitForRecv<V>)
}

public class Chan<V>: SendChannel, RecvChannel {
	private var receivers = [WaitForSend<V>]()
	private var senders = [WaitForRecv<V>]()

	let q: dispatch_queue_t = {
		let uuid = NSUUID().UUIDString
		return dispatch_queue_create("org.eksdyne.SynchronousChan.\(uuid)", DISPATCH_QUEUE_SERIAL)
	}()

	public init() {
	}

	public func asRecvOnly() -> RecvOnlyChan<Chan<V>> {
		return RecvOnlyChan<Chan<V>>(ch: self)
	}

	public func asSendOnly() -> SendOnlyChan<Chan<V>> {
		return SendOnlyChan<Chan<V>>(ch: self)
	}

	public func send(v: V) {
		// Prep a default action of blocking
		var action: Send = .Block(WaitForRecv<V>())

		dispatch_sync(q) {
			switch (action, self.receivers) {
			case let (.Block(thread), receivers) where receivers.count == 0:
				// Proceed with a Block waiting for a receiver
				self.senders.append(thread)

			default:
				// Proceed with a send to an existing receiver
				action = .ToReceiver(self.receivers.removeFirst())
			}
		}

		switch action {
		case let .Block(thread):
			if case .Completed = thread.waitForRecv(v) {
				return
			}

		case let .ToReceiver(thread):
			if case .Completed = thread.send(v) {
				return
			}
		}

		// When thread.waitForRecv(v) or thread.send(v) return false
		// the communication was canceled so the thread recurses into
		// another attempt to send the value.
		send(v)
	}

	public func recv() -> V {
		var action: Receive = .Block(WaitForSend<V>())

		dispatch_sync(q) {
			switch (action, self.senders) {

			case let (.Block(thread), senders) where senders.count == 0:
				self.receivers.append(thread)

			default:
				action = .FromSender(self.senders.removeFirst())

			}
		}

		switch action {
		case let .Block(thread):
			if case let .Completed(v) = thread.waitForSender() {
				return v
			}

		case let .FromSender(thread):
			if case let .Completed(v) = thread.recv() {
				return v
			}
		}

		return recv()
	}

}

extension Chan: SelectableRecvChannel {
	public func recv(onReady: () -> ()) -> Receive<V> {
		var action: Receive = .Block(WaitForSend<V>(syncedComm: GCDHandoff<V>(onReady: onReady)))

		dispatch_sync(q) {
			switch (action, self.senders) {
			case let (.Block(thread), senders) where senders.count == 0:
				self.receivers.append(thread)
			default:
				let sender = self.senders.removeFirst()
				sender.comm.onReady(onReady)
				action = .FromSender(sender)
			}
		}

		return action
	}
}

extension Chan: SelectableSendChannel {
	public func send(onReady: () -> ()) -> Send<V> {
		var action: Send = .Block(WaitForRecv<V>(syncedComm: GCDHandoff<V>(onReady: onReady)))

		dispatch_sync(q) {
			switch (action, self.receivers) {
			case let (.Block(thread), receivers) where receivers.count == 0:
				self.senders.append(thread)
			default:
				let receiver = self.receivers.removeFirst()
				receiver.comm.onReady(onReady)
				action = .ToReceiver(receiver)
			}
		}

		return action
	}
}

public struct SendOnlyChan<C: SendChannel>: SendChannel {
	private let ch: C

	public func send(value: C.ValueType) {
		ch.send(value)
	}
}

public struct RecvOnlyChan<C: RecvChannel>: RecvChannel {
	private let ch: C

	public func recv() -> C.ValueType {
		return ch.recv()
	}
}

public protocol SendChannel {
	associatedtype ValueType
	func send(value: ValueType)
}

public protocol RecvChannel {
	associatedtype ValueType
	func recv() -> ValueType
}

public protocol SelectableRecvChannel {
	associatedtype ValueType
	func recv(_: () -> ()) -> Receive<ValueType>
}

public protocol SelectableSendChannel {
	associatedtype ValueType
	func send(_: () -> ()) -> Send<ValueType>
}

public struct ASyncRecv<V> {
	let callback: (V) -> Void
}

public protocol SelectCase {
	func start(onReady: () -> ()) -> Handoff
	func wasSelected()
}

public class RecvCase<C: SelectableRecvChannel, V where C.ValueType == V>: SelectCase {
	let ch: C
	let received: (V) -> ()

	private let needResult = dispatch_group_create()
	private var result: HandoffReceiveResult<V> = .Canceled

	public init(channel: C, onSelected: (V) -> ()) {
		ch = channel
		received = onSelected
	}

	public func start(onReady: () -> ()) -> Handoff {
		dispatch_group_enter(needResult)
		result = .Canceled

		func haveResult(result: HandoffReceiveResult<V>) {
			self.result = result
			dispatch_group_leave(self.needResult)
			onReady()
		}

		switch ch.recv(onReady) {
		case let .Block(thread):
			go { haveResult(thread.waitForSender()) }
			return thread.comm

		case let .FromSender(thread):
			go { haveResult(thread.recv()) }
			return thread.comm
		}
	}

	public func wasSelected() {
		dispatch_group_wait(needResult, DISPATCH_TIME_FOREVER)

		// Calls into the block that is associated with the Select Case
		if case let .Completed(v) = result {
			received(v)
		}
	}
}

public func recv<C: SelectableRecvChannel, V where C.ValueType == V>(from channel: C, block: (V) -> ()) -> SelectCase {
	return RecvCase<C, V>(channel: channel, onSelected: block)
}

public struct SendCase<C: SelectableSendChannel, V where C.ValueType == V>: SelectCase {
	let ch: C
	let valueSent: () -> ()

	private let sentValue = dispatch_group_create()
	private let v: V

	public init(channel: C, value: V, onSelected: () -> ()) {
		ch = channel
		v = value
		valueSent = onSelected
	}


	public func start(onReady: () -> ()) -> Handoff {
		dispatch_group_enter(self.sentValue)

		func sentValue() {
			dispatch_group_leave(self.sentValue)
			onReady()
		}

		switch ch.send(onReady) {
		case let .Block(thread):
			go {
				thread.waitForRecv(self.v)
				sentValue()
			}

			return thread.comm

		case let .ToReceiver(thread):
			go {
				thread.send(self.v)
				sentValue()
			}

			return thread.comm
		}
	}

	public func wasSelected() {
		dispatch_group_wait(sentValue, DISPATCH_TIME_FOREVER)

		// Calls into the block that is associated with the Select Case
		valueSent()
	}
}

public func send<C: SelectableSendChannel, V where C.ValueType == V>(to channel: C, value: V, block: () -> ()) -> SelectCase {
	return SendCase<C, V>(channel: channel, value: value, onSelected: block)
}

public func Select (cases: () -> [SelectCase]) {
	return selectCases(cases())
}

private func selectCases(cases: [SelectCase]) {
	let commSema = dispatch_semaphore_create(0)

	let comms = cases.map { (c) -> (SelectCase, Handoff) in
		return (c, c.start {
			dispatch_semaphore_signal(commSema)
		})
	}

	dispatch_semaphore_wait(commSema, DISPATCH_TIME_FOREVER)

	let caseProceeded: SelectCase? = { () in
		let ready = comms.filter { (_, comm) in
			comm.isReady
		}

		if ready.count == 0 {
			return nil
		}

		let i = Int(arc4random_uniform(UInt32(ready.count)))
		let (c, comm) = ready[i]
		// TODO: Use return value to fix multiple select statement contention
		comm.proceed()
		return c
	}()


	for (_, comm) in comms {
		comm.cancel()
	}

	if let c = caseProceeded {
		return c.wasSelected()
	}

	return selectCases(cases)
}
