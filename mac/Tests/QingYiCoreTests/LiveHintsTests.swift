import Testing
@testable import QingYiCore

struct LiveHintsTests {
    @Test func chinesePunctuation() {
        let cases = [
            ("在电力系统中,储能装置可以平抑新能源发电的波动,提高效率", "在电力系统中，储能装置可以平抑新能源发电的波动，提高效率"),
            ("你好吗?我很好!", "你好吗？我很好！"),
            ("注意: 使用 AI, 效果更好; 访问 https://example.com", "注意：使用 AI，效果更好；访问 https://example.com"),
            ("比例是3:2,总共3,000元", "比例是3:2，总共3,000元"),
            ("他说 Hello, world 然后走了", "他说 Hello, world 然后走了"),
            ("已经是全角，不用改。", "已经是全角，不用改。"),
        ]
        for (input, expected) in cases {
            #expect(SpeechText.useChinesePunctuation(input) == expected)
        }
    }

    @Test func silenceIsReportedOnce() {
        let watch = SilenceWatch(seconds: 8)
        #expect(!watch.update(level: 0, now: 0))
        #expect(!watch.update(level: 0.0001, now: 7.9))
        #expect(watch.update(level: 0, now: 8))
        #expect(!watch.update(level: 0, now: 20))
    }

    @Test func anySoundEndsTheWatch() {
        let watch = SilenceWatch(seconds: 8)
        #expect(!watch.update(level: 0, now: 0))
        #expect(!watch.update(level: 0.01, now: 3))
        #expect(!watch.update(level: 0, now: 30))
        watch.reset()
        #expect(!watch.update(level: 0, now: 40))
        #expect(watch.update(level: 0, now: 48))
    }
}
