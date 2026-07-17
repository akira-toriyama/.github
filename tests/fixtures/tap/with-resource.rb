class Facet < Formula
  desc "Test fixture — carries a vendored third-party resource block"
  homepage "https://github.com/akira-toriyama/facet"
  url "https://github.com/akira-toriyama/facet/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "1111111111111111111111111111111111111111111111111111111111111111"
  license "MIT"

  resource "vendored" do
    url "https://github.com/someone-else/dep/archive/refs/tags/v9.9.9.tar.gz"
    sha256 "2222222222222222222222222222222222222222222222222222222222222222"
  end

  def install
    bin.install "facet"
  end
end
