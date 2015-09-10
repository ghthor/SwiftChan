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

public func go(@autoclosure routine: () -> ()) {
	go(routine)
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

public class SyncedComm<V> {
	private let sender = dispatch_group_create()
	private let receiver = dispatch_group_create()

	// Sychronizes read/write of the has[Sender|Receiver] variables
	private let q: dispatch_queue_t = {
		let uuid = NSUUID().UUIDString
		return dispatch_queue_create("org.eksdyne.SyncedComm.\(uuid)", DISPATCH_QUEUE_SERIAL)
	}()

	let readyCallback: (SyncedComm<V>) -> ()

	private var hasSender: Bool = false {
		didSet {
			if hasSender && hasReceiver {
				readyCallback(self)
			}
		}
	}

	private var hasReceiver: Bool = false {
		didSet {
			if hasSender && hasReceiver {
				readyCallback(self)
			}
		}
	}

	var v: V?
	var canceled: Bool?
	var senderCanceled: Bool?
	var receiverCanceled: Bool?

	init(onReady: (SyncedComm<V>) -> ()) {
		readyCallback = onReady
		enter()
	}

	private func enter() {
		dispatch_group_enter(sender)
		dispatch_group_enter(receiver)
	}

	var leaveOnce = dispatch_once_t()

	private func leave() {
		dispatch_once(&leaveOnce) {
			dispatch_group_leave(self.sender)
			dispatch_group_leave(self.receiver)
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

	func ready() -> Bool {
		var ready: Bool = false
		dispatch_sync(q) { ready = self.hasSender && self.hasReceiver }
		return ready
	}

	// Returns true if the Comm was canceled
	func cancel() -> Bool {
		var canceled: Bool?
		dispatch_sync(q) {
			if self.canceled == nil {
				self.canceled = true
				self.leave()
			}

			canceled = self.canceled
		}


		return !(canceled!)
	}

	// Returns true if the Comm was executed
	func proceed() -> Bool {
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

private class WaitForSend<V> {
	private let comm: SyncedComm<V>

	init() {
		comm = SyncedComm<V> { (comm) in
			go { comm.proceed() }
		}
	}

	private func send(v: V) -> Bool {
		return comm.senderEnter(v)
	}

	private func waitForSender() -> (V?, Bool) {
		return comm.receiverEnter()
	}
}

private class WaitForRecv<V> {
	private let comm: SyncedComm<V>
	init() {
		comm = SyncedComm<V> { (comm) in
			go { comm.proceed() }
		}
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

public struct ASyncRecv<V> {
	let callback: (V) -> Void
}

infix operator <- { associativity left }

// Send is safe to use from the main queue
public func <- <C: SendChannel, V where C.ValueType == V> (ch: C, value: V) {
	if NSOperationQueue.currentQueue()?.underlyingQueue == dispatch_get_main_queue() {
		go {
			ch.send(value)
		}

	} else {
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
