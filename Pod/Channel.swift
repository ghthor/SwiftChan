//
//  Channel.swift
//  SwiftChan
//
//  Created by Willa Drengwitz on 9/1/15.
//  Copyright (c) 2015 Eksdyne Research. All rights reserved.
//

import Foundation

public protocol SendOnlyChannel {
	associatedtype ValueType
	func send(value: ValueType)
}

public protocol ReceiveOnlyChannel {
	associatedtype ValueType
	func receive() -> ValueType
}

extension SendOnlyChannel {
	public func asSendOnly() -> Self {
		return self
	}
}

extension ReceiveOnlyChannel {
	public func asReceiveOnly() -> Self {
		return self
	}
}

typealias RWChannel = protocol<SendOnlyChannel, ReceiveOnlyChannel>

public class GCDChan<Element> {
	private var waiting = (receivers: [GCDHandoff<Element>](),
	                       senders: [GCDHandoff<Element>]())

	let q: dispatch_queue_t = {
		let uuid = NSUUID().UUIDString
		return dispatch_queue_create("org.eksdyne.SynchronousChan.\(uuid)", DISPATCH_QUEUE_SERIAL)
	}()

	public init() {}
}

extension GCDChan: SendOnlyChannel {
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

extension GCDChan: ReceiveOnlyChannel {
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

