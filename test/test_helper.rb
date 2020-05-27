require 'minitest/autorun'
require 'flexmock/minitest'
require 'autoproj'
require_relative '../lib/apaka/packaging/autoproj2adaptor'
require_relative '../lib/apaka/packaging/packageinfoask'

Autoproj.root_dir = File.join(__dir__,"workspace")
$autoprojadaptor = Apaka::Packaging::PackageInfoAsk.new(:detect, Hash.new())

def autoprojadaptor
    $autoprojadaptor
end

Apaka::Packaging.root_dir = autoprojadaptor.root_dir

Apaka::Packaging::TargetPlatform.osdeps_release_tags= autoprojadaptor.osdeps_release_tags

