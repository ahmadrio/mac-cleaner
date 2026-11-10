import Testing
@testable import MacCleanerCore

@Test func formatsLikeHsize() {
    #expect(ByteFormat.string(kb: -1) == "?")
    #expect(ByteFormat.string(kb: 0) == "0 KB")
    #expect(ByteFormat.string(kb: 1023) == "1023 KB")
    #expect(ByteFormat.string(kb: 1024) == "1 MB")
    #expect(ByteFormat.string(kb: 1536) == "2 MB")
    #expect(ByteFormat.string(kb: 1_048_576) == "1.0 GB")
    #expect(ByteFormat.string(kb: 3_565_158) == "3.4 GB")
}
