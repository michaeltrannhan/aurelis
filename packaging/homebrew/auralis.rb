# Homebrew Cask template for the notarized Auralis.app GitHub release.
# CI sibling: replace `sha256` with the zip line from
# Auralis-{version}-SHA256SUMS after Scripts/package-release.sh.
#
#   brew install --cask auralis
#
# License: GPL-3.0-or-later (see LICENSE). Do not ship the unsigned SPM binary.

cask "auralis" do
  version "0.0.8"
  sha256 :no_check

  url "https://github.com/michaeltrannhan/aurelis/releases/download/v#{version}/Auralis-#{version}-aarch64-apple-darwin.zip"
  name "Auralis"
  desc "Menu-bar audio controller for macOS"
  homepage "https://github.com/michaeltrannhan/aurelis"

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "Auralis.app"

  zap trash: [
    "~/Library/Application Support/Auralis",
    "~/Library/Logs/Auralis",
  ]
end
