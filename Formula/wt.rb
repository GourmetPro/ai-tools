class Wt < Formula
  desc "Launch Claude sessions in isolated Git worktrees"
  homepage "https://github.com/GourmetPro/ai-tools"
  url "https://github.com/GourmetPro/ai-tools.git",
      tag:      "v0.1.0",
      revision: "fe71f4fb4f7817d3174d736d353256d9d91e692f"
  version "0.1.0"
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
