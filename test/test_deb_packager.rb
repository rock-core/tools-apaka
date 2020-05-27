require_relative 'test_helper'
require_relative '../lib/apaka/packaging/packageinfo'
require_relative '../lib/apaka/packaging/packager'
require_relative '../lib/apaka/packaging/deb/package2deb'

require 'tempfile'

include Apaka
include Apaka::Packaging

class TestDebPackager < Minitest::Test
    def setup
        options = { release_name: 'myrelease' }
        @package2deb = Deb::Package2Deb.new(options)
        @tempdir = File.join("/tmp/apaka-test")
        if File.directory?(@tempdir)
            FileUtils.rm_rf @tempdir
            FileUtils.mkdir_p @tempdir
        end
        @pkginfo = flexmock(@pkginfo)
        @pkginfo.should_receive(:srcdir).and_return(@tmpdir)

        @testdir = File.join("/tmp/apaka-test-dir")
        FileUtils.rm_rf @testdir if File.exist?(@testdir)
        FileUtils.mkdir_p @testdir
    end

    def test_canonize_name
        assert_equal("mixed-case-package", Deb.canonize("Mixed_Case_Package"))
    end

    def test_basename
        assert_equal("metaruby", Packaging.basename("tools/metaruby"))
    end

    def test_as_var_name
        assert_equal("CMAKE_PREFIX", Packaging.as_var_name("cmake_prefix"))
        assert_equal("PACKAGE_NAME", Packaging.as_var_name("package-name"))
    end

    def test_release_prefix
        assert_equal("rock-myrelease-", @package2deb.rock_release_prefix("myrelease"))
        assert_equal("rock-myrelease-", @package2deb.rock_release_prefix(nil))

    end

    def test_ruby_release_prefix
        assert_equal("rock-myrelease-ruby-", @package2deb.rock_ruby_release_prefix("myrelease"))
        assert_equal("rock-myrelease-ruby-", @package2deb.rock_ruby_release_prefix(nil))
    end

    def test_debian_name
        @pkginfo.should_receive(:name).and_return("my/test-ruby-package")
        @pkginfo.should_receive(:build_type).and_return(:ruby)

        name = @package2deb.debian_name(@pkginfo)
        assert_equal(name , "rock-myrelease-ruby-my-test-ruby-package")
    end

    def test_create_env
        assert @package2deb.env_setup =~ /PATH/
        assert @package2deb.env_create_exports =~ /PATH/
    end

    def test_generate_debian_dir
        pkg = autoprojadaptor.package_by_name("base/cmake")
        pkginfo = autoprojadaptor.pkginfo_from_pkg(pkg)

        @package2deb.generate_debian_dir(pkginfo, @testdir, options = { distribution: "bionic"})
    end

    def test_cmake_package
        pkg = autoprojadaptor.package_by_name("base/cmake")
        pkginfo = autoprojadaptor.pkginfo_from_pkg(pkg)
        @package2deb.package(pkginfo, { distribution: "bionic",
                                        architecture: "amd64" })


        # Run second time to check with equal content
        @package2deb.package(pkginfo, { distribution: "bionic",
                                        architecture: "amd64" })
    end

    def test_ruby_package
        pkg = autoprojadaptor.package_by_name("tools/metaruby")
        pkginfo = autoprojadaptor.pkginfo_from_pkg(pkg)
        @package2deb.package(pkginfo, { distribution: "bionic",
                                        architecture: "amd64" })
        
        packaging_dir = @package2deb.packaging_dir(pkginfo)
        package_prefix = "rock-myrelease-ruby-tools-metaruby"
        expected = [ "orig.tar.gz",
                     "dsc",
                     "debian.tar.xz"
        ]

        expected.each do |suffix|
            assert(!Dir.glob(File.join(packaging_dir,"#{package_prefix}*#{suffix}")).empty?, "No file with suffix #{suffix}")
        end

        # Run second time to check with equal content
        @package2deb.package(pkginfo, { distribution: "bionic",
                                        architecture: "amd64" })
        expected.each do |suffix|
            assert(!Dir.glob(File.join(packaging_dir,"#{package_prefix}*#{suffix}")).empty?, "No file with suffix #{suffix}")
        end
    end
end
