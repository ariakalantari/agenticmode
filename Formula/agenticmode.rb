# frozen_string_literal: true

# Homebrew package definition for agenticmode.
class Agenticmode < Formula
  desc "Keep a Mac awake with its lid closed while agent runs finish"
  homepage "https://github.com/ariakalantari/agenticmode"
  url "https://github.com/ariakalantari/agenticmode/archive/3a4c6a2bfea5a4905767b43bf8aa78460ced56b9.tar.gz"
  version "1.2.0"
  sha256 "d0917003144016a1906c3f1079e7c595db22d718c7a3c14605ed67dd9b312fa9"
  license "MIT"
  revision 1
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
    assert_equal "agenticmode 1.2.0", shell_output("#{bin}/agenticmode --version").strip
    assert_equal "agenticmode 1.2.0", shell_output("#{bin}/am --version").strip
    assert_match(/^  agenticmode \[options\]$/, shell_output("#{bin}/agenticmode --help"))
  end
end
