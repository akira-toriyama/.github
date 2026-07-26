class Facet < Formula
  desc "Test fixture — vendors a resource from THE SAME repo, which repo-qualification alone cannot protect"
  homepage "https://github.com/akira-toriyama/facet"
  url "https://github.com/akira-toriyama/facet/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "1111111111111111111111111111111111111111111111111111111111111111"
  license "MIT"

  resource "vendored-from-self" do
    url "https://github.com/akira-toriyama/facet/archive/refs/tags/v0.5.0.tar.gz"
    sha256 "3333333333333333333333333333333333333333333333333333333333333333"
  end

  def install
    bin.install "facet"
  end
end
