import Foundation
internal import os

public struct Pool<T>: @unchecked Sendable {
    private let elements: OSAllocatedUnfairLock<[T]>

    public init(elements: [T]) {
        self.elements = OSAllocatedUnfairLock(uncheckedState: elements)
    }

    public func acquire() -> T {
        return elements.withLockUnchecked { elements in
            guard !elements.isEmpty else {
                fatalError("Pool exhausted: no more elements available to acquire.")
            }
            return elements.removeLast()
        }
    }

    public func release(_ element: T) {
        elements.withLockUnchecked { elements in
            elements.append(element)
        }
    }
}
