//
//  Channel.swift
//  SwiftChan
//
//  Created by Willa Drengwitz on 9/1/15.
//  Copyright (c) 2015 Eksdyne Research. All rights reserved.
//

import Foundation

public protocol SendChannel {
	associatedtype ValueType
	func send(value: ValueType)
}

public protocol ReceiveChannel {
	associatedtype ValueType
	func receive() -> ValueType
}

public struct SendOnlyChan<C: SendChannel>: SendChannel {
	private let ch: C

	public func send(value: C.ValueType) {
		ch.send(value)
	}
}

public struct ReceiveOnlyChan<C: ReceiveChannel>: ReceiveChannel {
	private let ch: C

	public func receive() -> C.ValueType {
		return ch.receive()
	}
}


public class GCDChan<Element> {
	private var waiting = (receivers: [GCDHandoff<Element>](),
	                       senders: [GCDHandoff<Element>]())

	let q: dispatch_queue_t = {
		let uuid = NSUUID().UUIDString
		return dispatch_queue_create("org.eksdyne.SynchronousChan.\(uuid)", DISPATCH_QUEUE_SERIAL)
	}()

	public init() {}
}

extension GCDChan: SendChannel {
	private var handoffToSend: GCDHandoff<Element> {
		var handoff = GCDHandoff<Element>()

		dispatch_sync(q) {
			switch self.waiting.receivers.count {
			case 0:
				self.waiting.senders.append(handoff)
			default:
				handoff = self.waiting.receivers.removeFirst()
			}
		}

		return handoff
	}

	public func send(v: Element) {
		switch handoffToSend.enterAsSenderOf(v) {
		case .Completed:
			return
		default:
			send(v)
		}
	}
}

extension GCDChan: ReceiveChannel {
	private var handoffToReceive: GCDHandoff<Element> {
		var handoff = GCDHandoff<Element>()
		dispatch_sync(q) {
			switch self.waiting.senders.count {
			case 0:
				self.waiting.receivers.append(handoff)
			default:
				handoff = self.waiting.senders.removeFirst()
			}
		}

		return handoff
	}

	public func receive() -> Element {
		switch handoffToReceive.enterAsReceiver() {
		case .Completed(let value):
			return value
		default:
			return receive()
		}
	}
}

public protocol SelectableReceiveChannel {
	associatedtype PausedHandoff: Handoff
	func receive() -> PausedHandoff
}

public protocol SelectableSendChannel {
	associatedtype PausedHandoff: Handoff
	func send() -> PausedHandoff
}

extension GCDChan: SelectableReceiveChannel {
	public func receive() -> GCDHandoff<Element> {
		return handoffToReceive
	}
}

extension GCDChan: SelectableSendChannel {
	public func send() -> GCDHandoff<Element> {
		return handoffToSend
	}
}

public struct ASyncReceive<V> {
	let callback: (V) -> Void
}

public protocol SelectCase {
	func start(onReady: () -> ()) -> SelectableHandoff
	func wasSelected()
}

public class ReceiveCase<C: SelectableReceiveChannel, V where C.PausedHandoff.Element == V>: SelectCase {
	let ch: C
	let received: (V) -> ()

	private let needResult = dispatch_group_create()
	private var result: HandoffReceiveResult<V> = .Canceled

	public init(channel: C, onSelected: (V) -> ()) {
		ch = channel
		received = onSelected
	}

	public func start(onReady: () -> ()) -> SelectableHandoff {
		dispatch_group_enter(needResult)
		result = .Canceled

		let handoff = ch.receive()
		handoff.select.onReady(onReady)

		go {
			self.result = handoff.enterAsReceiver()
			dispatch_group_leave(self.needResult)
		}

		return handoff.select
	}

	public func wasSelected() {
		dispatch_group_wait(needResult, DISPATCH_TIME_FOREVER)

		// Calls into the block that is associated with the Select Case
		if case let .Completed(v) = result {
			received(v)
		}
	}
}

public func Receive<C: SelectableReceiveChannel, V where C.PausedHandoff.Element == V>(from channel: C, block: (V) -> ()) -> SelectCase {
	return ReceiveCase<C, V>(channel: channel, onSelected: block)
}

public struct SendCase<C: SelectableSendChannel, V where C.PausedHandoff.Element == V>: SelectCase {
	let ch: C
	let valueSent: () -> ()

	private let sentValue = dispatch_group_create()
	private let v: V

	public init(channel: C, value: V, onSelected: () -> ()) {
		ch = channel
		v = value
		valueSent = onSelected
	}

	public func start(onReady: () -> ()) -> SelectableHandoff {
		dispatch_group_enter(self.sentValue)

		let handoff = ch.send()
		handoff.select.onReady(onReady)

		go {
			handoff.enterAsSenderOf(self.v)
			dispatch_group_leave(self.sentValue)
		}

		return handoff.select
	}

	public func wasSelected() {
		dispatch_group_wait(sentValue, DISPATCH_TIME_FOREVER)

		// Calls into the block that is associated with the Select Case
		valueSent()
	}
}

public func Send<C: SelectableSendChannel, V where C.PausedHandoff.Element == V>(to channel: C, value: V, block: () -> ()) -> SelectCase {
	return SendCase<C, V>(channel: channel, value: value, onSelected: block)
}

public func Select (cases: () -> [SelectCase]) {
	return selectCases(cases())
}

private func selectCases(cases: [SelectCase]) {
	let commSema = dispatch_semaphore_create(0)

	let comms = cases.map { (c) -> (SelectCase, SelectableHandoff) in
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
