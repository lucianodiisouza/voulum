cask "voulum" do
  version "0.2.1"
  sha256 "4703d84b39683053265a5f10d42363997a7f78c06e0db23f8ea60bc4f8a4ebcd"

  url "https://github.com/lucianodiisouza/voulum/releases/download/v#{version}/Voulum-v#{version}-macos.dmg"
  name "Voulum"
  desc "Per-app volume, routing and EQ from the menu bar"
  homepage "https://audio.oprimo.dev/"

  # Newest release wins; version/sha256 above are kept in sync by the release
  # workflow (see docs/HOMEBREW.md).
  livecheck do
    url :url
    strategy :github_latest
  end

  # Process taps (the whole point of Voulum) are macOS 14.4+.
  # Sparkle updates the app in place.
  auto_updates true
  depends_on macos: :sonoma

  app "Voulum.app"

  # Voulum stores nothing but a UserDefaults domain and an SMAppService login
  # item; `brew uninstall` drops the app, `zap` clears the leftovers.
  zap trash: [
    "~/Library/Preferences/dev.oprimo.voulum.plist",
    "~/Library/Preferences/com.voulum.app.plist", # 0.4.1 and older
  ]
end
