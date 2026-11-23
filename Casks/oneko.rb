cask "oneko" do
  version "0.6.8"
  sha256 "90d3b4a9af172f33a95030fadbd8cf9ee9be9cdc78cf63925c5a48300804bedd"

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
