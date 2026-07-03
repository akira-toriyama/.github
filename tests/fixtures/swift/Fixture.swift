/// Fixture consumed by the hub's self-test (smoke-swift-format). swift-format.yml
/// is pointed at this dir via `paths:` and runs `swift format lint --strict` on
/// macOS with the pinned latest-stable Xcode — so the smoke proves the reusable
/// actually runs the linter, not just that the runner booted. Kept
/// strict-clean on purpose; reformat with `swift format --in-place`.
enum SelfTestFixture {
  static let name = "self-test fixture"
}
