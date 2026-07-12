# frozen_string_literal: true

# Homebrew formula for the envrun environment loader.
class Envrun < Formula
  desc "Run commands with local env files exported"
  homepage "https://github.com/GourmetPro/ai-tools"
  url "https://github.com/GourmetPro/ai-tools.git",
      tag:      "v0.5.0",
      revision: "fe48624994d6d3dbbef33050aa5a33640983a973"
  version "0.5.0"
  depends_on "git"

  def install
    bin.install "tools/envrun" => "envrun"
  end

  test do
    assert_match "Usage: envrun", shell_output("#{bin}/envrun --help")
  end
end
