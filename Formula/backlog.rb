# frozen_string_literal: true

# Homebrew formula for the backlog CLI.
class Backlog < Formula
  desc "Database-backed backlog CLI"
  homepage "https://github.com/GourmetPro/ai-tools"
  url "https://github.com/GourmetPro/ai-tools.git",
      tag:      "v0.3.3",
      revision: "43334e375feab6a10ba179436c02e105f56d7fa5"
  version "0.3.3"
  depends_on "libpq"
  depends_on "node"

  def install
    libexec.install "tools/backlog" => "backlog"
    chmod 0755, libexec/"backlog"

    (bin/"backlog").write <<~SH
      #!/bin/sh
      export PATH="#{formula_opt_bin("libpq")}:#{formula_opt_bin("node")}:$PATH"
      exec "#{libexec}/backlog" "$@"
    SH
  end

  def caveats
    <<~EOS
      Configure backlog before first use:
        mkdir -p ~/.config/ai-tools
        $EDITOR ~/.config/ai-tools/backlog.json

      Example config:
        {
          "default": "gtm-console",
          "backends": [
            { "name": "gtm-console", "type": "postgres", "databaseUrlEnv": "BACKLOG_DATABASE_URL" },
            { "name": "github", "type": "github-issues", "tokenEnv": "GITHUB_TOKEN" }
          ]
        }

      You can choose a backend with --backend or BACKLOG_BACKEND.
      GitHub backends can use tokenEnv, or a literal token in a private
      mode-0600 backlog.json.
      Existing ~/.config/ai-tools/backlog.conf files remain supported for
      Postgres compatibility when no backlog.json exists.
    EOS
  end

  test do
    ENV["BACKLOG_DATABASE_URL"] = "postgres://example.invalid/backlog"
    assert_match "Purpose:", shell_output("#{bin}/backlog --help")
  end
end
