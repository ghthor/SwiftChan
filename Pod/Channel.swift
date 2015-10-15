//
//  Channel.swift
//  SwiftChan
//
//  Created by Willa Drengwitz on 9/1/15.
//  Copyright (c) 2015 CocoaPods. All rights reserved.
//

import Foundation

// Inspired from https://gist.github.com/kainosnoema/dc8b8db0007412244b4a
public func go(routine: () -> ()) {
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), routine)
}

public func go(queue: NSOperationQueue, routine: () -> ()) {
	queue.addOperation(NSBlockOperation(block: routine))
}

public func gomain(routine: () -> ()) {
	dispatch_async(dispatch_get_main_queue(), routine)
}

public func gomain(@autoclosure routine: () -> ()) {
	gomain(routine)
}

public func go(after delay: Int, routine: () -> ()) {
	let delay = dispatch_time(DISPATCH_TIME_NOW, Int64(UInt64(delay) * NSEC_PER_MSEC))
	dispatch_after(delay, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), routine)
}

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

	private var ready: CommReadyCallback?

	private var hasSender: Bool = false {
		didSet {
			if hasSender && hasReceiver {
				if let ready = ready {
					ready()
				} else {
					go { self.proceed() }
				}
			}
		}
	}

	private var hasReceiver: Bool = false {
		didSet {
			if hasSender && hasReceiver {
				if let ready = ready {
					ready()
				} else {
					go { self.proceed() }
				}
			}
		}
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

	init(onReady: CommReadyCallback) {
		ready = onReady
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
				self.ready = callback
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

public class chan<V>: SendChannel, RecvChannel {
	private var waitingForSendQ = [WaitForSend<V>]()
	private var waitingForRecvQ = [WaitForRecv<V>]()

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
		var receiver: WaitForSend<V>?
		var sender: WaitForRecv<V>?

		dispatch_sync(q) {
			if self.waitingForSendQ.count > 0 {
				receiver = self.waitingForSendQ.removeAtIndex(0)
			} else {
				sender = WaitForRecv<V>()
				self.waitingForRecvQ.append(sender!)
			}
		}

		if let receiver = receiver {
			if !receiver.send(v) {
				send(v)
			}

		} else {
			if !sender!.waitForRecv(v) {
				send(v)
			}
		}
	}

	public func recv() -> V {
		var sender: WaitForRecv<V>?
		var receiver: WaitForSend<V>?

		dispatch_sync(q) {
			if self.waitingForRecvQ.count > 0 {
				sender = self.waitingForRecvQ.removeAtIndex(0)
			} else {
				receiver = WaitForSend<V>()
				self.waitingForSendQ.append(receiver!)
			}
		}

		if let sender = sender {
			let (v, _) = sender.recv()
			if v == nil {
				return recv()
			} else {
				return v!
			}

		} else {
			let (v, _) = receiver!.waitForSender()
			if v == nil {
				return recv()
			} else {
				return v!
			}
		}
	}

}

extension chan: SelectableRecvChannel {
	public func recv(onReady: CommReadyCallback) -> (WaitForRecv<V>?, WaitForSend<V>?) {
		var sender: WaitForRecv<V>?
		var receiver: WaitForSend<V>?

		dispatch_sync(q) {
			if self.waitingForRecvQ.count > 0 {
				sender = self.waitingForRecvQ.removeAtIndex(0)
				sender!.comm.onReady(onReady)
			} else {
				receiver = WaitForSend<V>(syncedComm: SyncedComm<V>(onReady: onReady))
				self.waitingForSendQ.append(receiver!)
			}
		}

		return (sender, receiver)
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
	typealias ValueType
	func send(value: ValueType)
}

public protocol RecvChannel {
	typealias ValueType
	func recv() -> ValueType
}

public protocol SelectableRecvChannel {
	typealias ValueType
	func recv(_: CommReadyCallback) -> (WaitForRecv<ValueType>?, WaitForSend<ValueType>?)
}

public struct ASyncRecv<V> {
	let callback: (V) -> Void
}

infix operator <- { associativity left }

// Send is safe to use from the main queue
public func <- <C: SendChannel, V where C.ValueType == V> (ch: C, value: V) {
	guard let queue = NSOperationQueue.currentQueue()?.underlyingQueue else {
		ch.send(value)
		return
	}

	guard let mainQ = dispatch_get_main_queue() else {
		ch.send(value)
		return
	}

	if queue.hash != mainQ.hash {
		ch.send(value)
		return
	}

	go {
		ch.send(value)
	}
}

public func <- <C: RecvChannel, V where C.ValueType == V> (receiver: ASyncRecv<V>, ch: C) {
	let queue = NSOperationQueue.currentQueue()
	go {
		let v = ch.recv()
		if let q = queue {
			go(q) {
				receiver.callback(v)
			}

		} else {
			gomain {
				receiver.callback(v)
			}
		}
	}
}

prefix operator <- {}

public prefix func <- <C: RecvChannel, V where C.ValueType == V> (ch: C) -> V {
	return ch.recv()
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
		received(v!)
	}
}

public func recv<C: SelectableRecvChannel, V where C.ValueType == V>(from channel: C, block: (V) -> ()) -> SelectCase {
	return RecvCase<C, V>(channel: channel, onSelected: block)
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
