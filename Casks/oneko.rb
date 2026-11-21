cask "oneko" do
  version "0.5.5"
  sha256 "de10cbc5cadc8b3fd4805652b29448183bfbaaf4e9d77f8b213d6b344fb26ca4"

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
