# frozen_string_literal: true

# Homebrew package definition for agenticmode.
class Agenticmode < Formula
  desc "Keep a Mac awake with its lid closed while agent runs finish"
  homepage "https://github.com/ariakalantari/agenticmode"
  url "https://github.com/ariakalantari/agenticmode/archive/aa5db607bfbc5726db576b8e1eb4eca3a71b85c2.tar.gz"
  version "1.1.0"
  sha256 "9c6d37ee78a4204eacc5c162b65076388fde5a2ae504d0ca14f2d55cefddf0a8"
  license "MIT"
  head "https://github.com/ariakalantari/agenticmode.git", branch: "main"

  depends_on :macos

  def install
    bin.install "bin/agenticmode"
    libexec.install "libexec/agenticmode-watchdog"
  end

  def caveats
    <<~EOS
      The first awake-mode run installs the root-owned safety watchdog and may
      ask for an administrator password.

      Before uninstalling, restore normal sleep and remove the watchdog:
        agenticmode off
        sudo rm -f /Library/PrivilegedHelperTools/com.ariakalantari.agenticmode.watchdog
    EOS
  end

  test do
    assert_equal "agenticmode 1.1.0", shell_output("#{bin}/agenticmode --version").strip
    assert_match(/^  agenticmode \[options\]$/, shell_output("#{bin}/agenticmode --help"))
  end
end
