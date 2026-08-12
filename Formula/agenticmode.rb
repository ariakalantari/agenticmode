# frozen_string_literal: true

# Homebrew package definition for agenticmode.
class Agenticmode < Formula
  desc "Keep a Mac awake with its lid closed while agent runs finish"
  homepage "https://github.com/ariakalantari/agenticmode"
  url "https://github.com/ariakalantari/agenticmode/releases/download/v1.4.1/agenticmode.tar.gz"
  sha256 "e90bd0012dfbb4b004e92ec5650c2be339743f460aad6a5878b6d06c07d779de"
  license "MIT"

  head do
    url "https://github.com/ariakalantari/agenticmode.git", branch: "main"
    depends_on "go" => :build
  end

  depends_on :macos

  resource "ui" do
    url "https://github.com/ariakalantari/agenticmode/releases/download/v1.4.1/agenticmode-ui"
    sha256 "ba5dc191bf72eda0f06f4bf826793646ac57f9c37564f6ce8a60e7e15cc19697"
  end

  def install
    if build.head?
      system "go", "build", *std_go_args(output: libexec/"agenticmode-ui", ldflags: "-s -w"), "./cmd/agenticmode-ui"
    else
      resource("ui").stage do
        chmod 0755, "agenticmode-ui"
        libexec.install "agenticmode-ui"
      end
    end
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
    assert_equal "agenticmode 1.4.1", shell_output("#{bin}/agenticmode --version").strip
    assert_equal "agenticmode 1.4.1", shell_output("#{bin}/am --version").strip
    assert_match(/^  agenticmode \[options\]$/, shell_output("#{bin}/agenticmode --help"))
    assert_predicate libexec/"agenticmode-ui", :executable?
    assert_equal "1", shell_output("#{libexec}/agenticmode-ui --protocol-version").strip
  end
end
