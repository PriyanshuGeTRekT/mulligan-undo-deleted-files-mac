cask "mulligan" do
  version "1.0.0"
  sha256 "2f9b503116abfa9657736057836ec2fe2208fc6634aefe6ed4ec35b2ddcb3e4c"

  url "https://github.com/PriyanshuGeTRekT/mulligan-undo-deleted-files-mac/releases/download/v#{version}/Mulligan-#{version}.zip"
  name "Mulligan"
  desc "Undo for deleted and overwritten files, using instant APFS copies"
  homepage "https://priyanshugetrekt.github.io/mulligan-undo-deleted-files-mac/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "Mulligan.app"
  binary "#{appdir}/Mulligan.app/Contents/Resources/bin/mulligan"

  zap trash: [
    "~/Library/Application Support/Mulligan",
    "~/Library/LaunchAgents/app.mulligan.watch.plist",
    "~/Library/Preferences/app.mulligan.mac.plist",
  ]

  caveats <<~EOS
    Mulligan is not notarized by Apple, so macOS blocks it the first time it opens.
    To allow it, open Mulligan once, then go to
      System Settings › Privacy & Security
    scroll down and click "Open Anyway" next to Mulligan.

    The first time it opens, Mulligan asks which folders to protect, and macOS asks
    whether it may access Desktop, Documents and Downloads. Choose Allow.
  EOS
end
