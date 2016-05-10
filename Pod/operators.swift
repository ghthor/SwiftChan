//
//  operators.swift
//  SwiftChan
//
//  Created by Willa Drengwitz on 4/29/16.
//  Copyright © 2016 Eksdyne Research. All rights reserved.
//

import Foundation

infix operator <- { associativity left }

// Send is safe to use from the main queue
public func <- <C: SupportSend, V where C.ValueType == V> (ch: C, value: V) {
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

public func <- <C: SupportReceive, V where C.ValueType == V> (receiver: ASyncReceive<V>, ch: C) {
	let queue = NSOperationQueue.currentQueue()
	go {
		let v = ch.receive()
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

public prefix func <- <C: SupportReceive, V where C.ValueType == V> (ch: C) -> V {
	return ch.receive()
}
