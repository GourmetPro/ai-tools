# frozen_string_literal: true

# Homebrew formula for the wt worktree launcher.
class Wt < Formula
  desc "Launch Claude sessions in isolated Git worktrees"
  homepage "https://github.com/GourmetPro/ai-tools"
  url "https://github.com/GourmetPro/ai-tools.git",
      tag:      "v0.4.0",
      revision: "ff8c6ec42a1849868f676cf306c95f066da260d9"
  version "0.4.0"
  depends_on "git"
  depends_on "zsh"

  def install
    bin.install "tools/wt" => "wt"
  end

  def caveats
    <<~EOS
      wt launches the claude CLI. Install and authenticate claude separately.
    EOS
  end

  test do
    system "#{bin}/wt", "--help"
  end
end
