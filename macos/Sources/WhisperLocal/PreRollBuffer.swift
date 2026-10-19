import Foundation

/// Ring buffer holding the newest `capacitySamples` of audio.
struct PreRollBuffer {
    let capacitySamples: Int
    private var storage: [Int16]
    private var start = 0
    private(set) var count = 0

    init(capacitySamples: Int) {
        self.capacitySamples = max(0, capacitySamples)
        storage = Array(repeating: 0, count: self.capacitySamples)
    }

    mutating func append(_ samples: [Int16]) {
        guard capacitySamples > 0 else { return }
        for sample in samples.suffix(capacitySamples) {
            if count < capacitySamples {
                storage[(start + count) % capacitySamples] = sample
                count += 1
            } else {
                storage[start] = sample
                start = (start + 1) % capacitySamples
            }
        }
    }

    func snapshot() -> [Int16] {
        (0..<count).map { storage[(start + $0) % capacitySamples] }
    }

    mutating func removeAll() {
        start = 0
        count = 0
    }
}
