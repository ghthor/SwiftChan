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

private class WaitForSend<V> {
	private var v: V!

	private let waiting = dispatch_group_create()
	private let sending = dispatch_group_create()
	private var sendAborted: Bool = false

	init() {
		dispatch_group_enter(sending)
		dispatch_group_enter(waiting)
	}

	private func maybeSend(value: V) -> Bool {
		dispatch_group_leave(waiting)
		dispatch_group_wait(sending, DISPATCH_TIME_FOREVER)

		if !sendAborted {
			v = value
			dispatch_group_leave(self.waiting)
			return true
		}

		dispatch_group_enter(self.waiting)
		return false
	}

	private func waitForMaybeSender() -> (Bool) -> V? {
		dispatch_group_wait(waiting, DISPATCH_TIME_FOREVER)

		return { (proceed) -> V? in
			self.sendAborted = !proceed
			dispatch_group_enter(self.waiting)
			dispatch_group_leave(self.sending)

			if proceed {
				dispatch_group_wait(self.waiting, DISPATCH_TIME_FOREVER)
				return self.v
			} else {
				return nil
			}
		}
	}
}

private class WaitForRecv<V> {
	private let v: V
	private var recvAborted: Bool = false

	private let waiting = dispatch_group_create()
	private let receiving = dispatch_group_create()

	init(value: V) {
		v = value
		dispatch_group_enter(waiting)
		dispatch_group_enter(receiving)
	}

	private func maybeRecv() -> V? {
		dispatch_group_leave(waiting)
		dispatch_group_wait(receiving, DISPATCH_TIME_FOREVER)

		if recvAborted {
			return nil
		}

		return v

	}

	private func waitForMaybeRecv() -> (Bool) -> () {
		dispatch_group_wait(waiting, DISPATCH_TIME_FOREVER)

		return { (proceed) in
			self.recvAborted = !proceed
			dispatch_group_leave(self.receiving)
		}
	}
}

public class chan<V>: SendChannel, RecvChannel {
	private var waitingForSendQ = [WaitForSend<V>]()
	private var waitingForRecvQ = [WaitForRecv<V>]()

	let q: dispatch_queue_t = {
		let uuid = NSUUID().UUIDString
		return dispatch_queue_create("org.eksdyne.SynchronousChan.\(uuid)", DISPATCH_QUEUE_SERIAL)
	}()

	public func asRecvOnly() -> RecvOnlyChan<chan<V>> {
		return RecvOnlyChan<chan<V>>(ch: self)
	}

	public func asSendOnly() -> SendOnlyChan<chan<V>> {
		return SendOnlyChan<chan<V>>(ch: self)
	}

	private func trySend(v: V) -> Bool {
		if waitingForSendQ.count > 0 {
			let receiver = self.waitingForSendQ.removeAtIndex(0)
			if receiver.maybeSend(v) {
				return true
			} else {
				return trySend(v)
			}
		}

		return false
	}

	public func send(v: V) {
		var sender: WaitForRecv<V>?

		dispatch_sync(q) {
			if !self.trySend(v) {
				sender = WaitForRecv<V>(value: v)
				self.waitingForRecvQ.append(sender!)
			}
		}

		if let sender = sender {
			sender.waitForMaybeRecv()(true)
		}
	}

	private func tryRecv() -> V? {
		if waitingForRecvQ.count > 0 {
			let sender = waitingForRecvQ.removeAtIndex(0)
			if let v = sender.maybeRecv() {
				return v
			} else {
				return tryRecv()
			}
		}

		return nil
	}

	public func recv() -> V {
		var v: V?
		var receiver: WaitForSend<V>?

		dispatch_sync(q) {
			v = self.tryRecv()
			if v == nil {
				receiver = WaitForSend<V>()
				self.waitingForSendQ.append(receiver!)
			}
		}

		if v != nil {
			return v!
		} else {
			return receiver!.waitForMaybeSender()(true)!
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

// FIXME: This class is broken and racy
public class BufferedChan<V>: chan<V> {
	let cap: Int
	var buf = [V]()

	init(capacity: Int) {
		cap = capacity
	}

	public override func send(v: V) {
		var wasSent: Bool = false
		dispatch_sync(q) {
			if self.buf.count < self.cap {
				self.buf.append(v)
				wasSent = true
			}
		}

		if wasSent {
			return
		}

		// FIXME: Race condidition
		super.send(v)
	}

	public override func recv() -> V {
		var v: V?
		dispatch_sync(q) {
			if self.buf.count > 0 {
				v = self.buf.removeAtIndex(0)
				// FIXME: dequeue a sender waiting for a receiver
			}
		}

		if v != nil {
			return v!
		}

		// FIXME: Race condidition
		return super.recv()
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
