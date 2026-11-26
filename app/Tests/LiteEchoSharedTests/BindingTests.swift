import SwiftUI
import Testing
@testable import LiteEchoShared

@Suite struct BindingTests {
    final class Box { var value = true; var writes = 0 }

    private func counted(_ box: Box) -> Binding<Bool> {
        Binding(get: { box.value }, set: { box.value = $0; box.writes += 1 })
    }

    @Test func sameValueWritesAreDropped() {
        let box = Box()
        let binding = counted(box).ignoringRepeatedValues()
        binding.wrappedValue = true
        binding.wrappedValue = true
        #expect(box.writes == 0)
    }

    @Test func changesStillGoThrough() {
        let box = Box()
        let binding = counted(box).ignoringRepeatedValues()
        binding.wrappedValue = false
        #expect(box.value == false)
        #expect(box.writes == 1)
        binding.wrappedValue = false
        #expect(box.writes == 1)
        binding.wrappedValue = true
        #expect(box.value == true)
        #expect(box.writes == 2)
    }
}
