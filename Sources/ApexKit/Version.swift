/// The version of Apex Control, `apexctl` and ApexKit: one number for all
/// three, following Semantic Versioning (semver.org).
///
/// This constant is the single source of truth. `Scripts/version.sh` reads it
/// for the app bundle's `Info.plist`, and the release workflow refuses to
/// publish a tag that disagrees with it, so a release can never carry a
/// version different from its tag. Bump it in the same change that adds the
/// `CHANGELOG.md` entry.
///
/// Keep the declaration on a single line — the scripts parse it with `sed`.
public enum ApexVersion {
    /// `MAJOR.MINOR.PATCH`, optionally followed by `-prerelease` (`0.2.0-rc.1`).
    public static let current = "0.2.0-dev"
}
