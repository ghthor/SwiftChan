// https://github.com/Quick/Quick

import Quick
import Nimble
import SwiftChan

class SynchronousChannel: QuickSpec {
	override func spec() {
		describe("a synchronous channel") {
			let totalSends = 10
			let ch = chan<Int>()

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
					let fanIn = chan<Int>()
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
				go {
					ch <- 1
				}

				let noCommCh = chan<Int>()

				Select {
					[
						recv(from: ch) { (v) in
							expect(v) == 1
						},
						recv(from: noCommCh) { (_) in
						},
					]
				}
			}
		}
	}
}
