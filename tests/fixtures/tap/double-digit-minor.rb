class Facet < Formula
  desc "Test fixture — sits at v1.9.0, so bumping it to v1.10.0 only succeeds under version-aware ordering"
  homepage "https://github.com/akira-toriyama/facet"
  url "https://github.com/akira-toriyama/facet/archive/refs/tags/v1.9.0.tar.gz"
  sha256 "1111111111111111111111111111111111111111111111111111111111111111"
  license "MIT"

  def install
    bin.install "facet"
  end
end
