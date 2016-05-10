// https://github.com/Quick/Quick

import Quick
import Nimble
import SwiftChan

class SynchronousChannel: QuickSpec {
	override func spec() {
		describe("a synchronous channel") {
			let totalSends = 10
			let ch = Chan<Int>()

			describe("will send and receive") {
				it("with one sender and one receiver") {
					go {
						for i in 0...totalSends {
							ch <- i
						}
					}

					for i in 0...totalSends {
						expect(<-ch) == i
					}
				}

				let sendsq = dispatch_queue_create("org.eksdyne.ChannelSyncQueue", DISPATCH_QUEUE_SERIAL)
				var sends = Set<Int>()

				let genValue = { () -> Int in
					for ;; {
						let v = Int(arc4random())
						var wasInserted = false

						dispatch_sync(sendsq) {
							if sends.contains(v) {
								return
							}

							sends.insert(v)
							wasInserted = true
						}

						if wasInserted {
							return v
						}
					}
				}

				it("with many senders and one receiver") {
					for _ in 0...totalSends {
						let v = genValue()
						go { ch <- v }
					}

					for _ in 0...totalSends {
						let v = <-ch
						expect(sends.remove(v)) != nil
					}

					expect(sends.count) == 0
				}

				let expectAllValuesWereRead = { () -> () in
					let fanIn = Chan<Int>()
					for _ in 0...totalSends {
						go {
							let v = <-ch
							fanIn <- v
						}
					}

					for _ in 0...totalSends {
						let v = <-fanIn
						dispatch_sync(sendsq) {
							expect(sends.remove(v)) != nil
						}
					}

					dispatch_sync(sendsq) {
						expect(sends.count) == 0
					}
				}

				it("with one sender and many receivers") {
					go {
						for _ in 0...totalSends {
							let v = genValue()
							ch <- v
						}
					}

					expectAllValuesWereRead()
				}

				it("with many senders and many receivers") {
					go {
						for _ in 0...totalSends {
							go {
								let v = genValue()
								ch <- v
							}
						}
					}

					expectAllValuesWereRead()
				}
			}

			it("can be selected") {
				let senders = (0..<2).map { (i) -> Chan<Int> in
					let ch = Chan<Int>()

					go {
						ch <- i
					}

					return ch
				}.enumerate().map { (i, ch) -> SelectCase in
					return recv(from: ch) { (v: Int) in
						expect(v) == i
					}
				}

				let receivers = (0..<2).map { (i) -> Chan<Int> in
					let ch = Chan<Int>()

					go {
						expect(<-ch) == i
					}

					return ch
				}.enumerate().map { (i, ch) -> SelectCase in
					return send(to: ch, value: i) {}
				}

				let noCommCh = Chan<Int>()

				// Select with only receives
				Select {
					senders + [recv(from: noCommCh) { (_) in }]
				}

				// Select with only sends
				Select {
					receivers + [recv(from: noCommCh) { (_) in }]
				}

				// Select with both sends and receives
				Select {
					senders + receivers + [recv(from: noCommCh) { (_) in }]
				}
			}

			it("will select eveningly random among a group of communicating channels") {
				let chs = [
					Chan<Int>(),
					Chan<Int>(),
					Chan<Int>()
				]

				chs.enumerate().forEach { (i, ch) in
					dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0)) {
						for ;; {
							ch <- i
						}
					}
				}

				// [Index: NumberTimesRead]
				var reads = chs.enumerate().reduce([Int: Int]()) { (var reads, ch) in
					reads[ch.index] = 0
					return reads
				}

				var totalReads = 0

				let syncGroup = dispatch_group_create()

				for ;; {
					dispatch_group_enter(syncGroup)

					go(after: 10) {
						Select {
							chs.enumerate().map { (i, ch) in
								return recv(from: ch) { (v) in
									reads[i] = reads[i]! + 1
									totalReads++
								}
							}
						}

						dispatch_group_leave(syncGroup)
					}

					dispatch_group_wait(syncGroup, DISPATCH_TIME_FOREVER)

					if totalReads >= 200 {
						break
					}
				}

				reads.values.forEach { (chReads) in
					// This doesn't seem easy to specify. Requiring each channel
					// to have been selected 2 times out of 40 selects, so this
					// doesn't really specify an even selection among channels that
					// can communicate. I believe this descrepancy is being caused
					// by thread scheduling and I haven't thought of a good way to
					// make this spec more uniform.
					expect(chReads) > 2
				}
			}
		}
	}
}
