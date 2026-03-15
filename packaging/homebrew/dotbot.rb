class Dotbot < Formula
  desc "Structured AI-assisted development framework with two-phase execution"
  homepage "https://github.com/andresharpe/dotbot-v3"
  url "https://github.com/andresharpe/dotbot-v3/releases/download/v0.1.0/dotbot-v3-0.1.0.tar.gz"
  sha256 ""
  license "MIT"
  version "0.1.0"

  depends_on "powershell/tap/powershell" => :recommended

  def install
    # Install all dotbot files into the Cellar
    libexec.install Dir["*"]

    # Create a wrapper script that delegates to pwsh
    (bin/"dotbot").write <<~EOS
      #!/bin/bash
      exec pwsh -NoProfile -File "#{libexec}/bin/dotbot.ps1" "$@"
    EOS
  end

  def post_install
    # Deploy profiles and CLI to ~/dotbot
    system "pwsh", "-NoProfile", "-ExecutionPolicy", "Bypass",
           "-File", "#{libexec}/scripts/install-global.ps1",
           "-SourceDir", libexec.to_s
  end

  def caveats
    <<~EOS
      dotbot requires PowerShell 7+. If not installed:
        brew install powershell/tap/powershell

      dotbot has been deployed to ~/dotbot. Run 'dotbot init' in any
      git repository to get started.
    EOS
  end

  test do
    assert_match "D O T B O T", shell_output("#{bin}/dotbot help 2>&1")
  end
end
