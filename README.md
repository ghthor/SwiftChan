# SwiftChan

Go concurrency primitives implemented for use in swift using similar syntax. This project was a experiment conducted after my excitement over custom operators. The syntax additions provided in this library are ALMOST identical to go's channel syntax. The results of this project are that I finally understood a use case for semaphores, but also that using semaphores + GCD causes thread exhaustion on iOS and the kernel will just start killing threads which results in deadlocks using this library.

## Usage

See [Tests](Example/Tests/Tests.swift) for Usage examples.
See [Pod](Pod/) for library implementation.

## Author

Wilhelmina Drengwitz, ghthor@gmail.com

## License

SwiftChan is available under the MIT license. See the LICENSE file for more info.
