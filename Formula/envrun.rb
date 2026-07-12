# frozen_string_literal: true

# Homebrew formula for the envrun environment loader.
class Envrun < Formula
  desc "Run commands with local env files exported"
  homepage "https://github.com/GourmetPro/ai-tools"
  url "https://github.com/GourmetPro/ai-tools.git",
      tag:      "v0.4.1",
      revision: "ec6b9adf0ee283934cfbd0bfc28de140e29840ad"
  version "0.4.1"
  depends_on "git"

  def install
    bin.install "tools/envrun" => "envrun"
  end

  test do
    assert_match "Usage: envrun", shell_output("#{bin}/envrun --help")
  end
end
