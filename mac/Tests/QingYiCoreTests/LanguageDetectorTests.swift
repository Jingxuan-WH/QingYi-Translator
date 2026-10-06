import Testing
import Foundation
@testable import QingYiCore

struct LanguageDetectorTests {
    @Test func chineseWithEnglishTermsIsChinese() {
        #expect(LanguageDetector.detect("我们用 MATLAB 和 Simulink 做了 power flow 仿真。") == Languages.simplifiedChinese)
    }

    @Test func traditionalChinese() {
        #expect(LanguageDetector.detect("這個問題我們會在下週開會時討論。") == Languages.traditionalChinese)
    }

    @Test func english() {
        #expect(LanguageDetector.detect("Deep neural networks have achieved remarkable success in speech recognition.") == Languages.english)
    }

    @Test func japanese() {
        #expect(LanguageDetector.detect("今日はとても良い天気ですね。") == Languages.japanese)
    }

    @Test func koreanRussianArabicThaiHindi() {
        #expect(LanguageDetector.detect("안녕하세요 반갑습니다") == Languages.korean)
        #expect(LanguageDetector.detect("Привет, как дела?") == Languages.russian)
        #expect(LanguageDetector.detect("مرحبا بكم في الموقع") == Languages.arabic)
        #expect(LanguageDetector.detect("สวัสดีครับ ยินดีต้อนรับ") == Languages.thai)
        #expect(LanguageDetector.detect("नमस्ते दुनिया") == Languages.hindi)
    }

    @Test func latinLanguages() {
        #expect(LanguageDetector.detect("Le gouvernement a annoncé une nouvelle politique pour les entreprises.") == Languages.french)
        #expect(LanguageDetector.detect("Die Regierung hat eine neue Politik für die Unternehmen angekündigt.") == Languages.german)
        #expect(LanguageDetector.detect("El gobierno anunció una nueva política para las empresas.") == Languages.spanish)
        #expect(LanguageDetector.detect("Chính phủ đã công bố một chính sách mới cho các doanh nghiệp.") == Languages.vietnamese)
        #expect(LanguageDetector.detect("Hükümet şirketler için yeni bir politika açıkladı.") == Languages.turkish)
        #expect(LanguageDetector.detect("Rząd ogłosił nową politykę dla przedsiębiorstw.") == Languages.polish)
    }

    @Test func emptyAndSymbols() {
        #expect((LanguageDetector.detect("")) == nil)
        #expect((LanguageDetector.detect("12345 !!! ???")) == nil)
    }

    @Test func fallbackTarget() {
        #expect(Languages.fallback(for: Languages.simplifiedChinese) == Languages.english)
        #expect(Languages.fallback(for: Languages.japanese) == Languages.simplifiedChinese)
        #expect(Languages.simplifiedChinese.isSameLanguage(as: Languages.traditionalChinese))
        #expect(Languages.all.count == 19)
    }
}
