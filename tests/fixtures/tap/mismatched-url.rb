class Facet < Formula
  desc "Test fixture — source url does not match the caller repo"
  homepage "https://github.com/akira-toriyama/facet"
  url "https://github.com/akira-toriyama/OTHER/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "1111111111111111111111111111111111111111111111111111111111111111"
  license "MIT"

  def install
    bin.install "facet"
  end
end
