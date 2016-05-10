//
//  Handoff.swift
//  SwiftChan
//
//  Created by Willa Drengwitz on 5/10/16.
//  Copyright © 2016 Eksdyne Research. All rights reserved.
//

import Foundation

// The result of a handoff without access to the value.
public enum HandoffResult {
	case Canceled
	case Completed
}

// The result of a handoff with access to the value if
// the handoff was completed succesfully.
public enum HandoffReceiveResult<V> {
	case Canceled
	case Completed(V)

	var withoutValue: HandoffResult {
		switch self {
		case .Canceled:  return .Canceled
		case .Completed: return .Completed
		}
	}
}

public enum HandoffValue<V> {
	case Waiting

	case HasReader
	case HasValue(V)

	case Ready(V)

	case Done(HandoffReceiveResult<V>)

	func setValue(v: V) -> HandoffValue {
		switch self {
		case .HasReader:
			return .Ready(v)
		default:
			return .HasValue(v)
		}
	}

	func hasReader() -> HandoffValue {
		switch self {
		case let .HasValue(v):
			return Ready(v)
		default:
			return .HasReader
		}
	}

	func cancel() -> HandoffValue {
		switch self {
		case .Done: return self
		default:    return .Done(.Canceled)
		}
	}

	func complete() -> HandoffValue {
		switch self {
		case .Ready(let v):
			return .Done(.Completed(v))
		default:
			return .Done(.Canceled)
		}
	}

	var isReady: Bool {
		switch self {
		case .Ready, .Done:
			return true

		default:
			return false
		}
	}
}

public protocol Handoff {
	var isReady: Bool { get }
	func onReady(_: () -> ())

	func cancel() -> HandoffResult
	func proceed() -> HandoffResult
}

public class GCDHandoff<V>: Handoff, Unique {
	private let partner = dispatch_semaphore_create(0)

	private let q = dispatch_queue_create("\(GCDHandoff<V>.newURI).lock", DISPATCH_QUEUE_SERIAL)
	private lazy var triggerHandoff: () -> () = { go { self.proceed() }}
	private var handoff: HandoffValue<V> = .Waiting {
		didSet {
			switch handoff {
			case .Ready:
				triggerHandoff()

			case .Done:
				release()

			default: break
			}
		}
	}

	private func setValue(v: V) { handoff = handoff.setValue(v) }
	private func hasReader()    { handoff = handoff.hasReader() }
	private func cancelHandoff() -> HandoffValue<V> {
		handoff = handoff.cancel()
		return handoff
	}

	private func completedHandoff() -> HandoffValue<V> {
		handoff = handoff.complete()
		return handoff
	}

	public var isReady: Bool {
		get {
			var ready: Bool = false
			dispatch_sync(q) { ready = self.handoff.isReady }
			return ready
		}
	}

	init() {}

	init(onReady callback: () -> ()) {
		triggerHandoff = callback
	}

	// Release both the sender and receiver threads.
	private func release() {
		dispatch_semaphore_signal(partner)
		dispatch_semaphore_signal(partner)
	}

	// Override the current onReady callback
	public func onReady(callback: () -> ()) {
		dispatch_sync(q) {
			self.triggerHandoff = callback
			if case .Ready = self.handoff {
				go { callback() }
			}
		}
	}

	func senderEnter(v: V) -> HandoffResult {
		dispatch_sync(q) { self.setValue(v) }
		return wait().withoutValue
	}

	func receiverEnter() -> HandoffReceiveResult<V> {
		dispatch_sync(q) { self.hasReader() }
		return wait()
	}

	private func wait() -> HandoffReceiveResult<V> {
		dispatch_semaphore_wait(partner, DISPATCH_TIME_FOREVER)
		guard case .Done(let result) = handoff else {
			return .Canceled
		}

		return result
	}

	public func cancel() -> HandoffResult {
		var handoff: HandoffValue<V> = .Done(.Canceled)
		dispatch_sync(q) {
			handoff = self.cancelHandoff()
		}

		guard case .Done(let result) = handoff else {
			return .Canceled
		}

		return result.withoutValue
	}

	public func proceed() -> HandoffResult {
		var handoff: HandoffValue<V> = .Done(.Canceled)
		dispatch_sync(q) {
			handoff = self.completedHandoff()
		}

		guard case .Done(let result) = handoff else {
			return .Canceled
		}

		return result.withoutValue
	}
}
