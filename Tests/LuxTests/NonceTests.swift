import Testing
@testable import Lux

struct NonceTests {
    @Test func sha256HexMatchesKnownVector() {
        // SHA-256("abc") — must equal what the engine computes for nonce checks.
        #expect(Nonce.sha256Hex("abc")
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
