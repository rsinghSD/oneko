cask "oneko" do
  version "0.6.5"
  sha256 "8e151fa4720549c2a2d5fd4e6e5144294762c873f6ba7b4f30b5485aa9da1be3"

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
