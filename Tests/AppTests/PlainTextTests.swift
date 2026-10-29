@testable import App
import Testing

@Suite("PlainText")
struct PlainTextTests {
    @Test func stripsTagsAndDecodesEntities() {
        let html = "<p>The party enters the <b>Abyss</b>&nbsp;&amp; meets Kevin&#8217;s cousin.</p><p>Next&hellip;</p><script>alert(1)</script>"
        #expect(PlainText.fromHTML(html) == "The party enters the Abyss & meets Kevin’s cousin. Next…")
    }

    @Test func numericAndUnknownEntities() {
        #expect(PlainText.decodeEntities("&#x41;&#66; &foo; & alone") == "AB &foo; & alone")
        #expect(PlainText.decodeEntities("Tom &AMP; Jerry") == "Tom & Jerry")
    }

    @Test func excerptCutsAtWordBoundary() {
        let long = String(repeating: "word ", count: 100)
        let excerpt = PlainText.excerpt(long, maxLength: 23)
        #expect(excerpt == "word word word word…")
        #expect(PlainText.excerpt("short text") == "short text")
        #expect(PlainText.excerpt("<p> </p>") == nil)
        #expect(PlainText.excerpt(nil) == nil)
    }

    @Test func subtitleOnlyWhenItAddsSomething() {
        #expect(PlainText.subtitle("A new adventure begins.", addsTo: "A new adventure begins. The party meets…") == false)
        #expect(PlainText.subtitle("Bonus episode", addsTo: "The party meets the dragon.") == true)
        #expect(PlainText.subtitle("Bonus", addsTo: nil) == true)
        #expect(PlainText.subtitle("  ", addsTo: "x") == false)
    }
}
