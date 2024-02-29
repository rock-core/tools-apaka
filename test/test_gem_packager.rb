require_relative "test_helper"
require_relative "../lib/apaka/packaging/gem/package2gem"

include Apaka
include Apaka::Packaging::Gem

class TestGemPackager < Minitest::Test
    def setup
        options = { release_name: 'myrelease' }
        @package2gem = Package2Gem.new(options)
        @tempdir = File.join("/tmp/apaka-test")
        if File.directory?(@tempdir)
            FileUtils.rm_rf @tempdir
            FileUtils.mkdir_p @tempdir
        end
        @testdir = File.join("/tmp/apaka-test-dir")
        FileUtils.rm_rf @testdir if File.exist?(@testdir)
        FileUtils.mkdir_p @testdir
    end

    def test_convert_package
        pkg = autoprojadaptor.package_by_name("tools/metaruby")
        pkginfo = autoprojadaptor.pkginfo_from_pkg(pkg)

        @package2gem.convert_package(pkginfo, @testdir, gem_name: "mynewgem")
        assert(!Dir.glob(File.join(@testdir,"mynewgem*.gem")).empty?, "Ruby package #{pkg.name} converted to mynewgem*.gem")
    end
end
