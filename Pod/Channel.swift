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
	private let sema = dispatch_semaphore_create(0)

	private var v: V!

	private func send(value: V) {
		v = value
		dispatch_semaphore_signal(sema)
	}

	private func waitForSender() -> V {
		dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER)

		return v
	}
}

private class WaitForRecv<V> {
	private let sema = dispatch_semaphore_create(0)

	private let v: V

	init(value: V) {
		v = value
	}

	private func recv() -> V {
		dispatch_semaphore_signal(sema)

		return v
	}

	private func waitForRecv() {
		dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER)
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

	public func send(v: V) {
		var receiver: WaitForSend<V>?
		var sender: WaitForRecv<V>?

		dispatch_sync(q) {
			if self.waitingForSendQ.count > 0 {
				receiver = self.waitingForSendQ.removeAtIndex(0)
			} else {
				sender = WaitForRecv<V>(value: v)
				self.waitingForRecvQ.append(sender!)
			}
		}

		if receiver != nil {
			receiver!.send(v)
		} else {
			sender!.waitForRecv()
		}
	}

	public func canSend(value: V) -> Bool {
		var receiver: WaitForSend<V>?

		dispatch_sync(q) {
			if self.waitingForSendQ.count > 0 {
				receiver = self.waitingForSendQ.removeAtIndex(0)
			}
		}

		if let r = receiver {
			r.send(value)
			return true
		}

		return false
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

		if sender != nil {
			return sender!.recv()
		} else {
			return receiver!.waitForSender()
		}
	}

	public func canRecv() -> (V?, Bool) {
		var sender: WaitForRecv<V>?

		dispatch_sync(q) {
			if self.waitingForRecvQ.count > 0 {
				sender = self.waitingForRecvQ.removeAtIndex(0)
			}
		}

		if let s = sender {
			return (s.recv(), true)
		}

		return (nil, false)
	}
}

public struct SendOnlyChan<C: SendChannel>: SendChannel {
	private let ch: C

	public func send(value: C.ValueType) {
		ch.send(value)
	}

	public func canSend(value: C.ValueType) -> Bool {
		return ch.canSend(value)
	}
}

public struct RecvOnlyChan<C: RecvChannel>: RecvChannel {
	private let ch: C

	public func recv() -> C.ValueType {
		return ch.recv()
	}

	public func canRecv() -> (C.ValueType?, Bool) {
		return ch.canRecv()
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
	func canSend(value: ValueType) -> Bool
}

public protocol RecvChannel {
	typealias ValueType
	func recv() -> ValueType
	func canRecv() -> (ValueType?, Bool)
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
