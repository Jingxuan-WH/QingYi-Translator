import Testing
import Foundation
@testable import QingYiCore

struct GlossaryTests {
    @Test func containsTermWordStart() {
        #expect(Glossary.containsTerm("We use AI models", "AI"))
        #expect(!(Glossary.containsTerm("Send an email", "AI")))
        #expect(Glossary.containsTerm("The power flows here", "power flow"))
        #expect(Glossary.containsTerm("计算潮流分布", "潮流"))
        #expect(Glossary.containsTerm("droop CONTROL", "Droop Control"))
    }

    @Test func matchLimitsAndBothDirections() {
        let entries = [GlossaryEntry(source: "power flow", target: "潮流"), GlossaryEntry(source: "MATLAB", target: "MATLAB")]
        #expect(Glossary.match(entries, "潮流计算").map(\.source) == ["power flow"])
        #expect(Glossary.match(entries, "nothing here").count == 0)
    }

    @Test func parseFormats() {
        let text = """
        术语\t译法
        power flow\t潮流
        droop control = 下垂控制
        "a, b" , "c ""quoted"" d"
        inverter -> 逆变器
        no separator here
        """
        let entries = Glossary.parse(text)
        #expect(entries.count == 4)
        #expect(entries[0] == GlossaryEntry(source: "power flow", target: "潮流"))
        #expect(entries[1] == GlossaryEntry(source: "droop control", target: "下垂控制"))
        #expect(entries[2] == GlossaryEntry(source: "a, b", target: "c \"quoted\" d"))
        #expect(entries[3] == GlossaryEntry(source: "inverter", target: "逆变器"))
    }

    @Test func cleanDropsDuplicatesAndIncomplete() {
        let cleaned = Glossary.clean([
            GlossaryEntry(source: " a ", target: "b"),
            GlossaryEntry(source: "A", target: "B"),
            GlossaryEntry(source: "", target: "x"),
            GlossaryEntry(source: "multi\nline", target: "y"),
        ])
        #expect(cleaned == [GlossaryEntry(source: "a", target: "b"), GlossaryEntry(source: "multi line", target: "y")])
    }

    @Test func csvRoundTrip() throws {
        let entries = [GlossaryEntry(source: "a,b", target: "c\"d"), GlossaryEntry(source: "plain", target: "简单")]
        let csv = Glossary.toCsv(entries)
        #expect(csv == "\"a,b\",\"c\"\"d\"\r\nplain,简单\r\n")
        #expect(Glossary.parse(csv) == entries)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("glossary-test-\(UUID().uuidString).csv")
        try Glossary.writeCsv(to: url, entries: entries)
        #expect(try Glossary.readFile(url) == entries)
        try FileManager.default.removeItem(at: url)
    }

    @Test func readsGB18030File() throws {
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        let data = "潮流,power flow\r\n".data(using: String.Encoding(rawValue: gb))!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("glossary-gb-\(UUID().uuidString).csv")
        try data.write(to: url)
        #expect(try Glossary.readFile(url) == [GlossaryEntry(source: "潮流", target: "power flow")])
        try FileManager.default.removeItem(at: url)
    }
}
