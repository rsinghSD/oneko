cask "oneko" do
  version "0.6.0"
  sha256 "4b1895dd1c0e0efded17b4f1ca7692c1e303e3579f613fc71d7297019db62ec8"

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
