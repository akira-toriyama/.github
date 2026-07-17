class Facet < Formula
  desc "Test fixture — plain formula (source url + sha only)"
  homepage "https://github.com/akira-toriyama/facet"
  url "https://github.com/akira-toriyama/facet/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "1111111111111111111111111111111111111111111111111111111111111111"
  license "MIT"

  def install
    bin.install "facet"
  end
end
