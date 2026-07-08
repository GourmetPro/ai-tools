# frozen_string_literal: true

# Homebrew formula for the envrun environment loader.
class Envrun < Formula
  desc "Run commands with local env files exported"
  homepage "https://github.com/GourmetPro/ai-tools"
  url "https://github.com/GourmetPro/ai-tools.git",
      tag:      "v0.3.3",
      revision: "43334e375feab6a10ba179436c02e105f56d7fa5"
  version "0.3.3"
  depends_on "git"

  def install
    bin.install "tools/envrun" => "envrun"
  end

  test do
    assert_match "Usage: envrun", shell_output("#{bin}/envrun --help")
  end
end
