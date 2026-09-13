import Testing
@testable import Picky

struct AppBundleConfigurationTests {
    @Test func appVersionIncludesTheBuildNumberWhenAvailable() {
        #expect(
            AppBundleConfiguration.formatAppVersion(
                appName: "Picky",
                version: "0.10.1",
                build: "1511"
            ) == "Picky 0.10.1 (1511)"
        )
    }

    @Test func appVersionRemainsReadableWithoutABuildNumber() {
        #expect(
            AppBundleConfiguration.formatAppVersion(
                appName: "Picky",
                version: "0.10.1",
                build: nil
            ) == "Picky 0.10.1"
        )
    }

    @Test func appVersionIsHiddenWhenTheVersionIsUnavailable() {
        #expect(
            AppBundleConfiguration.formatAppVersion(
                appName: "Picky",
                version: nil,
                build: "1511"
            ) == nil
        )
    }
}
