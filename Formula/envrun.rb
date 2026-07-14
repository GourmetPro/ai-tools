# frozen_string_literal: true

# Homebrew formula for the envrun environment loader.
class Envrun < Formula
  desc "Run commands with local env files exported"
  homepage "https://github.com/GourmetPro/ai-tools"
  url "https://github.com/GourmetPro/ai-tools.git",
      tag:      "v0.5.1",
      revision: "21836a153b8974b85e10c5d6e4af280072f9e769"
  version "0.5.1"
  depends_on "git"

  def install
    bin.install "tools/envrun" => "envrun"
  end

  test do
    assert_match "Usage: envrun", shell_output("#{bin}/envrun --help")
  end
end
