import Testing

@Suite("Placeholder")
struct PlaceholderTests {
    @Test("project builds and tests run")
    func projectBuilds() {
        #expect(true)
    }
}
