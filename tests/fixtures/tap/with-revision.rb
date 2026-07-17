class Facet < Formula
  desc "Test fixture — carries a revision line to be dropped on bump"
  homepage "https://github.com/akira-toriyama/facet"
  url "https://github.com/akira-toriyama/facet/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "1111111111111111111111111111111111111111111111111111111111111111"
  revision 2
  license "MIT"

  def install
    bin.install "facet"
  end
end
