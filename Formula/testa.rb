# Homebrew formula for Testa. Builds from source, so no notarized binary is
# needed. Install via the tap (Homebrew 2.x+ no longer accepts a raw formula URL):
#   brew tap valewnrt/testa
#   brew install valewnrt/testa/testa
#
# Release checklist for each tag (there is no automation for this — release.sh
# only builds/signs the standalone zip, it does not rewrite this file):
#   1. git tag vX.Y.Z && git push --tags
#   2. curl -sL https://github.com/valewnrt/testa/archive/refs/tags/vX.Y.Z.tar.gz | shasum -a 256
#   3. paste that digest into `sha256` below and commit
class Testa < Formula
  desc "Autonomous iOS Simulator E2E driver for AI agents"
  homepage "https://github.com/valewnrt/testa"
  url "https://github.com/valewnrt/testa/archive/refs/tags/v0.2.1.tar.gz"
  sha256 "86d626d248aa0579a1a66ac4303bb79e7f591b8d3f524542c5f7c8e661d7e85a"
  license "MIT"
  head "https://github.com/valewnrt/testa.git", branch: "main"

  depends_on xcode: ["26.0", :build]
  depends_on :macos

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    bin.install ".build/release/testa"
    (pkgshare/"skills/testa").install "skills/testa/SKILL.md"
  end

  def caveats
    <<~EOS
      Finish setup (installs the Claude Code skill + registers the MCP server):
        testa setup

      Then boot a simulator, and:  testa info && testa ui
    EOS
  end

  test do
    assert_match "testa", shell_output("#{bin}/testa help")
  end
end
