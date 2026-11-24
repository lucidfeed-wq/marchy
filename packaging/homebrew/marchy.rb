# Template for <owner>/homebrew-marchy/Casks/marchy.rb (filled in by .github/workflows/release.yml).
#   brew tap <owner>/marchy && brew trust <owner>/marchy && brew install --cask marchy
cask "marchy" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/@REPO@/releases/download/v#{version}/Marchy-#{version}.dmg"
  name "Marchy"
  desc "Omarchy-style keyboard-driven desktop (unofficial)"
  homepage "https://github.com/@REPO@"

  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "Marchy.app"

  zap trash: "~/Library/Application Support/Marchy"

  caveats <<~EOS
    Open Marchy and press Set Up on the Home screen.

    This build is not notarized yet. If macOS says Marchy can't be opened, go to
    System Settings > Privacy & Security and click "Open Anyway" (once).
  EOS
end
