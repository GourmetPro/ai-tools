# frozen_string_literal: true

# Homebrew formula for the envrun environment loader.
class Envrun < Formula
  desc "Run commands with local env files exported"
  homepage "https://github.com/GourmetPro/ai-tools"
  url "https://github.com/GourmetPro/ai-tools.git",
      tag:      "v0.3.1",
      revision: "3a3e100d9cbbf0b72160fa9c3617df02e7e4f794"
  version "0.3.1"
  depends_on "git"

  def install
    bin.install "tools/envrun" => "envrun"
  end

  test do
    assert_match "Usage: envrun", shell_output("#{bin}/envrun --help")
  end
end
