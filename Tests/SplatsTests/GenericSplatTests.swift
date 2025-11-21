import Foundation
import Testing
@testable import Splats

@Suite
struct GenericSplatTests {

    @Test
    func testGenericSplatInit() {
        let splat = GenericSplat(
            position: [1, 2, 3],
            scale: [0.1, 0.2, 0.3],
            color: [1, 0, 0, 1],
            rotation: .init(ix: 0, iy: 0, iz: 0, r: 1)
        )

        #expect(splat.position == [1, 2, 3])
        #expect(splat.scale == [0.1, 0.2, 0.3])
        #expect(splat.color == [1, 0, 0, 1])
    }
}
