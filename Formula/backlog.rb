class Backlog < Formula
  desc "Database-backed backlog CLI"
  homepage "https://github.com/GourmetPro/ai-tools"
  url "https://github.com/GourmetPro/ai-tools.git",
      tag:      "v0.1.0",
      revision: "fe71f4fb4f7817d3174d736d353256d9d91e692f"
  version "0.1.0"
  depends_on "libpq"
  depends_on "node"

  def install
    libexec.install "tools/backlog" => "backlog"
    chmod 0755, libexec/"backlog"

    (bin/"backlog").write <<~SH
      #!/bin/sh
      export PATH="#{Formula["libpq"].opt_bin}:#{Formula["node"].opt_bin}:$PATH"
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
    assert_match "usage: tools/backlog", shell_output("#{bin}/backlog 2>&1", 2)
  end
end
