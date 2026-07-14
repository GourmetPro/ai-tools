# frozen_string_literal: true

# Homebrew formula for the wt worktree launcher.
class Wt < Formula
  desc "Create isolated Git worktrees with optional Claude launch"
  homepage "https://github.com/GourmetPro/ai-tools"
  url "https://github.com/GourmetPro/ai-tools.git",
      tag:      "v0.5.1",
      revision: "21836a153b8974b85e10c5d6e4af280072f9e769"
  version "0.5.1"
  depends_on "git"
  depends_on "zsh"

  def install
    bin.install "tools/wt" => "wt"
  end

  def caveats
    <<~EOS
      wt --claude launches the claude CLI. Install and authenticate claude separately
      only when using that option.
    EOS
  end

  test do
    system "#{bin}/wt", "--help"
  end
end
