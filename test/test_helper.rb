require 'minitest/autorun'
require 'flexmock/minitest'
require 'autoproj'
require_relative '../lib/apaka/packaging/autoproj2adaptor'
require_relative '../lib/apaka/packaging/packageinfoask'

Autoproj.root_dir = File.join(__dir__,"workspace")

# create .autoproj/bin/bundle
bin_dir = File.join(Autoproj.root_dir, ".autoproj","bin")
FileUtils.mkdir_p bin_dir unless File.exist?(bin_dir)
Dir.chdir(bin_dir) do
    bundle_bin = `which bundle`.strip
    FileUtils.ln_s bundle_bin, "bundle" if bundle_bin and not File.symlink?("bundle")
end
$autoprojadaptor = Apaka::Packaging::PackageInfoAsk.new(:detect, Hash.new())

def autoprojadaptor
    $autoprojadaptor
end

Apaka::Packaging.root_dir = autoprojadaptor.root_dir

Apaka::Packaging::TargetPlatform.osdeps_release_tags= autoprojadaptor.osdeps_release_tags

