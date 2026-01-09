import Foundation

extension BinaryInteger {
    mutating func postIncrement() -> Self {
        let oldValue = self
        self += 1
        return oldValue
    }
}

// MARK: -

internal protocol RadixSortable {
    /// Returns an 8-bit chunk of the sortable key for the given shift (in bits).
    func key(shift: Int) -> Int
    /// Total number of bits required to represent the sortable key.
    static var totalKeyBitWidth: Int { get }
}

internal struct RadixSortCPU <T> where T: RadixSortable {
    private func histogram(input: UnsafeMutableBufferPointer<T>, shift: Int) -> [UInt32] {
        input.reduce(into: Array(repeating: 0, count: 256)) { result, value in
            result[value.key(shift: shift)] += 1
        }
    }

    private func prefixSumExclusive(_ input: [UInt32]) -> [UInt32] {
        input.prefixSumExclusive()
    }

    private func shuffle(_ input: UnsafeMutableBufferPointer<T>, summedHistogram histogram: [UInt32], shift: Int, output: UnsafeMutableBufferPointer<T>) {
        assert(input.count <= output.count)
        var histogram = histogram
        for i in input.indices {
            let value = input[i]
            let key = value.key(shift: shift)
            let outputIndex = histogram[key].postIncrement()
            assert(outputIndex < output.count)
            output[Int(outputIndex)] = input[i]
        }
    }

    internal func countingSort(input: UnsafeMutableBufferPointer<T>, shift: Int, output: UnsafeMutableBufferPointer<T>) {
        let histogram = histogram(input: input, shift: shift)
        let summedHistogram = prefixSumExclusive(histogram)
        shuffle(input, summedHistogram: summedHistogram, shift: shift, output: output)
    }

    internal func radixSort(input: UnsafeMutableBufferPointer<T>, temp: UnsafeMutableBufferPointer<T>) {
        var input = input
        var temp = temp
        let radixBits = 8
        let phases = (T.totalKeyBitWidth + radixBits - 1) / radixBits
        for phase in 0..<phases {
            countingSort(input: input, shift: phase * radixBits, output: temp)
            swap(&input, &temp)
        }
        if phases.isMultiple(of: 2) {
            for i in input.indices {
                temp[i] = input[i]
            }
        }
    }
}

// MARK: -

internal extension Collection where Element: BinaryInteger {
    @inline(__always) func prefixSumExclusive() -> [Element] {
        reduce(into: [0]) { result, value in
            result.append(result.last! + value)
        }.dropLast()
    }
}
