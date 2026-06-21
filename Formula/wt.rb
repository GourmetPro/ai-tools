class Wt < Formula
  desc "Launch Claude sessions in isolated Git worktrees"
  homepage "https://github.com/GourmetPro/ai-tools"
  url "https://github.com/GourmetPro/ai-tools.git",
      tag:      "v0.1.1",
      revision: "512fa9fadc60b78c63bb0fe5e898c5d0c8159810"
  version "0.1.1"
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
