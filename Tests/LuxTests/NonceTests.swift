import Testing
@testable import Lux

struct NonceTests {
    @Test func sha256HexMatchesKnownVector() {
        // SHA-256("abc") — must equal what the engine computes for nonce checks.
        #expect(Nonce.sha256Hex("abc")
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func pkceChallengeMatchesRFC7636Vector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(PKCE.challenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func generatedPKCEPairUsesValidVerifierAndChallenge() throws {
        let pair = try PKCE.generate()
        #expect(pair.verifier.count == 43)
        #expect(pair.challenge == PKCE.challenge(for: pair.verifier))
    }
}
