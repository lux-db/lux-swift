# Releasing Lux Swift

## 1.1.0 order

1. Merge and release Lux engine 0.37.0. Confirm the immutable `v0.37.0` tag and
   GitHub Release exist.
2. Replace the temporary engine commit in the Swift CI workflow with the
   released `v0.37.0` tag and confirm the real-engine contract job passes.
3. Merge the stacked Lux Swift Auth, Push, documentation/release, and final
   hardening PRs in order. Rebase each dependent PR after its parent lands.
4. Run `swift test`, the generic iOS Simulator build, DocC build, sample-app
   type-check, and the engine 0.37.0 contract test from `main`.
5. Confirm the dated Lux Lab record covers the supported physical Auth + Push
   flows without containing credentials, sessions, or device tokens.
6. Create and push the exact `1.1.0` tag from the verified `main` commit. The
   release workflow validates the tag, reruns the gates, and creates the GitHub
   Release.

Never create the SDK tag while the minimum engine tag is missing: the release
workflow deliberately checks out that engine tag and must fail closed.
