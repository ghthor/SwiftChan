//
//  goroutine.swift
//  SwiftChan
//
//  Created by Willa Drengwitz on 4/29/16.
//  Copyright © 2016 Eksdyne Research. All rights reserved.
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

public func go(after delay: Int, routine: () -> ()) {
	let delay = dispatch_time(DISPATCH_TIME_NOW, Int64(UInt64(delay) * NSEC_PER_MSEC))
	dispatch_after(delay, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), routine)
}
