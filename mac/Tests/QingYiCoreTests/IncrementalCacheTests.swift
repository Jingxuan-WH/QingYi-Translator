import Testing
import Foundation
@testable import QingYiCore

struct IncrementalCacheTests {
    @Test func appendedParagraphOnlyTranslatesTheNewPart() {
        let cache = IncrementalCache()
        let first = "First paragraph.\n\nSecond paragraph."
        let plan1 = cache.plan(contextKey: "k", text: first)
        #expect(plan1.isFull)
        cache.commit(contextKey: "k", plan: plan1, remainderTranslation: "第一段。\n\n第二段。")

        let plan2 = cache.plan(contextKey: "k", text: first + "\n\nThird paragraph.")
        #expect(!(plan2.isFull))
        #expect(plan2.reused.count == 2)
        #expect(plan2.reusedTranslation == "第一段。\n\n第二段。\n\n")
        #expect(plan2.remainder == "Third paragraph.")
        #expect(plan2.context.map(\.source) == ["First paragraph.", "Second paragraph."])
    }

    @Test func unfinishedParagraphIsNotReused() {
        let cache = IncrementalCache()
        let plan1 = cache.plan(contextKey: "k", text: "Hello world")
        cache.commit(contextKey: "k", plan: plan1, remainderTranslation: "你好世界")
        #expect(cache.plan(contextKey: "k", text: "Hello world and more").isFull)
    }

    @Test func contextKeyChangeForcesFull() {
        let cache = IncrementalCache()
        let plan1 = cache.plan(contextKey: "a", text: "One.\n\nTwo.")
        cache.commit(contextKey: "a", plan: plan1, remainderTranslation: "一。\n\n二。")
        #expect(cache.plan(contextKey: "b", text: "One.\n\nTwo.\n\nThree.").isFull)
    }

    @Test func nothingNewWhenTextUnchanged() {
        let cache = IncrementalCache()
        let plan1 = cache.plan(contextKey: "k", text: "One.\n\nTwo.")
        cache.commit(contextKey: "k", plan: plan1, remainderTranslation: "一。\n\n二。")
        let plan2 = cache.plan(contextKey: "k", text: "One.\n\nTwo.\n")
        #expect(plan2.nothingNew)
        #expect(plan2.reusedTranslation.trimmingCharacters(in: .whitespacesAndNewlines) == "一。\n\n二。")
    }

    @Test func splitKeepsBlockWhenCountsDiffer() {
        #expect(IncrementalCache.split(source: "A.\n\nB.", translation: "甲。").count == 1)
        #expect(IncrementalCache.split(source: "A.\n\nB.", translation: "甲。\n\n乙。").count == 2)
        #expect(IncrementalCache.endsSentence("Done.”"))
        #expect(!(IncrementalCache.endsSentence("Not done")))
    }
}
