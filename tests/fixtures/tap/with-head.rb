class Facet < Formula
  desc "Test fixture — carries a head spec that must stay put"
  homepage "https://github.com/akira-toriyama/facet"
  url "https://github.com/akira-toriyama/facet/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "1111111111111111111111111111111111111111111111111111111111111111"
  head "https://github.com/akira-toriyama/facet.git", branch: "main"
  license "MIT"

  def install
    bin.install "facet"
  end
end
