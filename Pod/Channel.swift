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
	private let sender = dispatch_group_create()
	private let receiver = dispatch_group_create()

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
	var senderCanceled: Bool?
	var receiverCanceled: Bool?

	init() {
		enter()
	}

	init(onReady callback: CommReadyCallback) {
		triggerHandoff = callback
		enter()
	}

	private func enter() {
		dispatch_group_enter(sender)
		dispatch_group_enter(receiver)
	}

	private var leaveOnce = dispatch_once_t()
	private func leave() {
		dispatch_once(&leaveOnce) {
			dispatch_group_leave(self.sender)
			dispatch_group_leave(self.receiver)
		}
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
		dispatch_group_wait(sender, DISPATCH_TIME_FOREVER)
		if canceled! {
			return false
		}

		return true
	}

	// Returns true if the communication went through
	private func receiverEnter() -> (V?, Bool) {
		dispatch_sync(q) { self.hasReceiver = true }
		dispatch_group_wait(receiver, DISPATCH_TIME_FOREVER)
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
private enum Receive<V> {
	case FromSender(WaitForRecv<V>)
	case Block(WaitForSend<V>)
}

// What is about to happen as a thread enters into a send action on a channel.
private enum Send<V> {
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
	public func recv(onReady: CommReadyCallback) -> (WaitForRecv<V>?, WaitForSend<V>?) {
		var sender: WaitForRecv<V>?
		var receiver: WaitForSend<V>?

		dispatch_sync(q) {
			if self.senders.count > 0 {
				sender = self.senders.removeAtIndex(0)
				sender!.comm.onReady(onReady)
			} else {
				receiver = WaitForSend<V>(syncedComm: SyncedComm<V>(onReady: onReady))
				self.receivers.append(receiver!)
			}
		}

		return (sender, receiver)
	}
}

extension chan: SelectableSendChannel {
	public func send(onReady: CommReadyCallback) -> (WaitForSend<V>?, WaitForRecv<V>?) {
		var receiver: WaitForSend<V>?
		var sender: WaitForRecv<V>?

		dispatch_sync(q) {
			if self.receivers.count > 0 {
				receiver = self.receivers.removeAtIndex(0)
				receiver!.comm.onReady(onReady)
			} else {
				sender = WaitForRecv<V>(syncedComm: SyncedComm<V>(onReady: onReady))
				self.senders.append(sender!)
			}
		}

		return (receiver, sender)
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
	func recv(_: CommReadyCallback) -> (WaitForRecv<ValueType>?, WaitForSend<ValueType>?)
}

public protocol SelectableSendChannel {
	associatedtype ValueType
	func send(_: CommReadyCallback) -> (WaitForSend<ValueType>?, WaitForRecv<ValueType>?)
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
		v = nil
		dispatch_group_enter(receivedValue)

		let (sender, receiver) = ch.recv(onReady)
		if let sender = sender {
			go {
				let (v, _) = sender.recv()
				self.v = v
				dispatch_group_leave(self.receivedValue)
				onReady()
			}

			return sender.comm

		} else {
			go {
				let (v, _) = receiver!.waitForSender()
				self.v = v
				dispatch_group_leave(self.receivedValue)
				onReady()
			}

			return receiver!.comm
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
		dispatch_group_enter(sentValue)

		let (receiver, sender) = ch.send(onReady)
		if let receiver = receiver {
			go {
				receiver.send(self.v)
				dispatch_group_leave(self.sentValue)
				onReady()
			}

			return receiver.comm

		} else {
			go {
				sender!.waitForRecv(self.v)
				dispatch_group_leave(self.sentValue)
				onReady()
			}

			return sender!.comm
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
