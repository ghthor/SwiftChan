//
//  Channel.swift
//  SwiftChan
//
//  Created by Willa Drengwitz on 9/1/15.
//  Copyright (c) 2015 Eksdyne Research. All rights reserved.
//

import Foundation

public typealias CommReadyCallback = () -> ()
public protocol Comm {
	var isReady: Bool { get }
	func onReady(_: CommReadyCallback)

	// Returns true if the Comm was canceled
	func cancel() -> Bool
	// Returns true if the Comm was executed
	func proceed() -> Bool
}

public class SyncedComm<V>: Comm {
	private let sender = dispatch_semaphore_create(0)
	private let receiver = dispatch_semaphore_create(0)

	// Sychronizes read/write of the has[Sender|Receiver] variables
	private let q: dispatch_queue_t = {
		let uuid = NSUUID().UUIDString
		return dispatch_queue_create("org.eksdyne.SyncedComm.\(uuid)", DISPATCH_QUEUE_SERIAL)
	}()

	private lazy var triggerHandoff: () -> () = { go { self.proceed() }}

	private var hasSender: Bool = false {
		didSet { maybeTriggerHandoff() }
	}

	private var hasReceiver: Bool = false {
		didSet { maybeTriggerHandoff() }
	}

	private var readyForHandoff: Bool { return hasSender && hasReceiver }

	private func maybeTriggerHandoff() {
		if readyForHandoff { triggerHandoff() }
	}

	public var isReady: Bool {
		get {
			var ready: Bool = false
			dispatch_sync(q) { ready = self.hasSender && self.hasReceiver }
			return ready
		}
	}

	var v: V?
	var canceled: Bool?

	init() {}

	init(onReady callback: CommReadyCallback) {
		triggerHandoff = callback
	}

	private func leave() {
		dispatch_semaphore_signal(sender)
		dispatch_semaphore_signal(receiver)
	}

	// Override the current onReady callback
	public func onReady(callback: CommReadyCallback) {
		dispatch_sync(q) {
			let isReady = self.hasSender && self.hasReceiver
			if !isReady {
				self.triggerHandoff = callback
			} else {
				go { callback() }
			}
		}
	}

	// Returns true if the communication went through
	private func senderEnter(v: V) -> Bool {
		self.v = v
		dispatch_sync(q) { self.hasSender = true }
		dispatch_semaphore_wait(sender, DISPATCH_TIME_FOREVER)
		if canceled! {
			return false
		}

		return true
	}

	// Returns true if the communication went through
	private func receiverEnter() -> (V?, Bool) {
		dispatch_sync(q) { self.hasReceiver = true }
		dispatch_semaphore_wait(receiver, DISPATCH_TIME_FOREVER)
		if canceled! {
			return (nil, false)
		}

		return (v, true)
	}

	// Returns true if the Comm was canceled
	public func cancel() -> Bool {
		var canceled: Bool?
		dispatch_sync(q) {
			if self.canceled == nil {
				self.canceled = true
				self.leave()
			}

			canceled = self.canceled
		}


		return canceled!
	}

	// Returns true if the Comm was executed
	public func proceed() -> Bool {
		var canceled: Bool?
		dispatch_sync(q) {
			if self.canceled == nil {
				self.canceled = false
				self.leave()
			}

			canceled = self.canceled
		}


		return !(canceled!)
	}
}

public class WaitForSend<V> {
	private let comm: SyncedComm<V>

	init() {
		comm = SyncedComm<V>()
	}

	init(syncedComm: SyncedComm<V>) {
		comm = syncedComm
	}

	private func send(v: V) -> Bool {
		return comm.senderEnter(v)
	}

	private func waitForSender() -> (V?, Bool) {
		return comm.receiverEnter()
	}
}

public class WaitForRecv<V> {
	private let comm: SyncedComm<V>

	init() {
		comm = SyncedComm<V>()
	}

	init(syncedComm: SyncedComm<V>) {
		comm = syncedComm
	}

	private func recv() -> (V?, Bool) {
		return comm.receiverEnter()
	}

	private func waitForRecv(v: V) -> Bool {
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

public class chan<V>: SendChannel, RecvChannel {
	private var receivers = [WaitForSend<V>]()
	private var senders = [WaitForRecv<V>]()

	let q: dispatch_queue_t = {
		let uuid = NSUUID().UUIDString
		return dispatch_queue_create("org.eksdyne.SynchronousChan.\(uuid)", DISPATCH_QUEUE_SERIAL)
	}()

	public init() {
	}

	public func asRecvOnly() -> RecvOnlyChan<chan<V>> {
		return RecvOnlyChan<chan<V>>(ch: self)
	}

	public func asSendOnly() -> SendOnlyChan<chan<V>> {
		return SendOnlyChan<chan<V>>(ch: self)
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
		case let .Block(thread)
			where thread.waitForRecv(v): return
		case let .ToReceiver(thread)
			where thread.send(v): return
		default:
			// When thread.waitForRecv(v) or thread.send(v) return false
			// the communication was canceled so the thread recurses into
			// another attempt to send the value.
			send(v)
		}
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
			if case let (v?, _) = thread.waitForSender() {
				return v
			}

		case let .FromSender(thread):
			if case let (v?, _) = thread.recv() {
				return v
			}
		}

		return recv()
	}

}

extension chan: SelectableRecvChannel {
	public func recv(onReady: CommReadyCallback) -> Receive<V> {
		var action: Receive = .Block(WaitForSend<V>(syncedComm: SyncedComm<V>(onReady: onReady)))

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

extension chan: SelectableSendChannel {
	public func send(onReady: CommReadyCallback) -> Send<V> {
		var action: Send = .Block(WaitForRecv<V>(syncedComm: SyncedComm<V>(onReady: onReady)))

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
	func recv(_: CommReadyCallback) -> Receive<ValueType>
}

public protocol SelectableSendChannel {
	associatedtype ValueType
	func send(_: CommReadyCallback) -> Send<ValueType>
}

public struct ASyncRecv<V> {
	let callback: (V) -> Void
}

public protocol SelectCase {
	func start(onReady: CommReadyCallback) -> Comm
	func wasSelected()
}

public class RecvCase<C: SelectableRecvChannel, V where C.ValueType == V>: SelectCase {
	let ch: C
	let received: (V) -> ()

	private let receivedValue = dispatch_group_create()
	private var v: V?

	public init(channel: C, onSelected: (V) -> ()) {
		ch = channel
		received = onSelected
	}

	public func start(onReady: CommReadyCallback) -> Comm {
		dispatch_group_enter(receivedValue)
		v = nil

		func haveValue(v: V?) {
			self.v = v
			dispatch_group_leave(self.receivedValue)
			onReady()
		}

		switch ch.recv(onReady) {
		case let .Block(thread):
			go {
				let (v, _) = thread.waitForSender()
				haveValue(v)
			}

			return thread.comm

		case let .FromSender(thread):
			go {
				let (v, _) = thread.recv()
				haveValue(v)
			}

			return thread.comm
		}
	}

	public func wasSelected() {
		dispatch_group_wait(receivedValue, DISPATCH_TIME_FOREVER)

		// Calls into the block that is associated with the Select Case
		received(v!)
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


	public func start(onReady: CommReadyCallback) -> Comm {
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
	let commSema = dispatch_semaphore_create(1)

	let comms = cases.map { (c) -> (SelectCase, Comm) in
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
