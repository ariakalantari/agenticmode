# frozen_string_literal: true

# Homebrew package definition for agenticmode.
class Agenticmode < Formula
  desc "Keep a Mac awake with its lid closed while agent runs finish"
  homepage "https://github.com/ariakalantari/agenticmode"
  url "https://github.com/ariakalantari/agenticmode/releases/download/v1.3.0/agenticmode.tar.gz"
  sha256 "e01971727a2d14819a5c38bd85dc4d73a162075781447a67a03c9171ed1eea08"
  license "MIT"
  head "https://github.com/ariakalantari/agenticmode.git", branch: "main"

  depends_on :macos

  def install
    bin.install "bin/agenticmode"
    bin.install_symlink bin/"agenticmode" => "am"
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
    assert_equal "agenticmode 1.3.0", shell_output("#{bin}/agenticmode --version").strip
    assert_equal "agenticmode 1.3.0", shell_output("#{bin}/am --version").strip
    assert_match(/^  agenticmode \[options\]$/, shell_output("#{bin}/agenticmode --help"))
  end
end
