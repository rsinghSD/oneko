cask "oneko" do
  version "0.5.5"
  sha256 "071ea6a0c518d1f37b9b09a70e06ce1b8d03b4ff52dc3fe88e0b1ef32dbae23d"

  url "https://github.com/rsinghSD/oneko/releases/download/v#{version}/Oneko-#{version}.dmg"
  name "Oneko"
  desc "Desktop cat that chases your cursor, with physics, toys and Touch Bar support"
  homepage "https://github.com/rsinghSD/oneko"

  depends_on macos: :ventura

  app "Oneko.app"

  zap trash: "~/Library/Preferences/local.oneko.app.plist"

  caveats <<~EOS
    Oneko isn't notarized by Apple yet. If macOS says it can't be opened,
    right-click Oneko in Applications and choose Open (once), or run:
      xattr -dr com.apple.quarantine /Applications/Oneko.app
  EOS
end
