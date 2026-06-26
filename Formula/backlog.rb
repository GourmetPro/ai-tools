class Backlog < Formula
  desc "Database-backed backlog CLI"
  homepage "https://github.com/GourmetPro/ai-tools"
  url "https://github.com/GourmetPro/ai-tools.git",
      tag:      "v0.2.0",
      revision: "fbfee4ca2d6619343ece03634a0a9866c1bdebbb"
  version "0.2.0"
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
        $EDITOR ~/.config/ai-tools/backlog.conf

      The config file should contain:
        DATABASE_URL='postgres://user:pass@host/db'

      You can also point at another config file with BACKLOG_CONFIG.
    EOS
  end

  test do
    ENV["BACKLOG_DATABASE_URL"] = "postgres://example.invalid/backlog"
    assert_match "Purpose:", shell_output("#{bin}/backlog --help")
  end
end
