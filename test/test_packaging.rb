require_relative 'test_helper'
require_relative '../lib/apaka'

# TODO Testcases
#
# 1. naming of artifacts:
#    - build package with target distribution release name
#    verify output has target distribution release name
# 2. dependencies
#    - naming of rock-dependencies
#    - pastel
#    - cucumber
#    - tools-rubigen --> using debian packages only // with_rock_prefix
# 3. resolve gem dependencies for a specific version
#
include Apaka::Packaging

class TestDebian < Minitest::Test

    attr_reader :packager

    def setup
        @packager = Deb::Package2Deb.new(release_name: "master")
        @gem_packager = Deb::Gem2Deb.new(release_name: "master")

        @packager.build_dir = File.join(Autoproj.root_dir, "build/test-rock-packager")
        @gem_packager.build_dir = File.join(Autoproj.root_dir, "build/test-rock-packager")

        Dir.chdir(Autoproj.root_dir) do
            cmd = "RUBYLIB=#{File.join(__dir__,'..','lib')} PATH=#{File.join(__dir__,'..','bin')}:#{ENV['PATH']} apaka prepare"
            msg, status = Open3.capture2(cmd)
            if !status.success?
                raise RuntimeError, "Failed to prepare system for apaka -- #{msg}"
            end
        end

    end

    def test_release_name
        assert(packager.rock_release_hierarchy == ["master"], "Rock release hierarchy should contain self")
        prefix = packager.rock_release_prefix
        assert( prefix == "rock-master-", "Release prefix is: #{prefix} expected rock-master-")
        prefix = packager.rock_release_prefix("other-master")
        assert( prefix == "rock-other-master-", "Release prefix is: #{prefix} expected rock-other-master-")

        assert(packager.rock_ruby_release_prefix == "rock-master-ruby-")
        assert(packager.rock_ruby_release_prefix("other-master") == "rock-other-master-ruby-")
    end

    def test_canonize
        test_set = { "test-package" => "test-package",
                     "test_package" => "test-package",
                     "_a-b-c-d_e_f_"  => "-a-b-c-d-e-f-" }
        test_set.each do |tin,tout|
           assert(Deb.canonize(tin) == tout)
        end
    end

    def test_basename
        test_set = { "tools/metapackage" => "metapackage" }
        test_set = { "tools/orogen/metapackage" => "metapackage" }
        test_set.each do |tin,tout|
           assert(Apaka::Packaging.basename(tin) == tout)
        end
    end

    def test_debian_name
        test_set = { "base/cmake" => "rock-master-base-cmake",
                     "rtt"        => "rock-master-rtt",
                     "utilrb"     => "rock-master-ruby-utilrb" }

        test_set.each do |tin, tout|
            pkg = autoprojadaptor.package_by_name(tin)
            pkginfo = autoprojadaptor.pkginfo_from_pkg(pkg)

            debian_name = packager.debian_name(pkginfo, true)
            assert( debian_name == tout, "Debian name: #{debian_name}, expected: #{tout}" )
        end
    end

    def test_commit_time
        pkg = autoprojadaptor.package_by_name("base/cmake")
        pkginfo = autoprojadaptor.pkginfo_from_pkg(pkg)

        time = pkginfo.latest_commit_time.strftime("%Y%m%d")
        assert( time =~ /[1-2]\d\d\d[0-1][0-9][0-3]\d/, "Debian commit time: #{time}, expected format %Y%m%d" )
    end

    def test_debian_version
        pkg = autoprojadaptor.package_by_name("base/cmake")
        pkginfo = autoprojadaptor.pkginfo_from_pkg(pkg)

        version = packager.debian_version(pkginfo, "trusty", "9")
        assert( version =~ /[0-9]\.[1-2]\d\d\d[0-1][0-9][0-3]\d-9~trusty/, "Debian version: #{version}, expected: <version>.<timestamp>.<revision>" )
    end

    def test_recursive_dependencies
        test_set = {}
        target_platform = TargetPlatform.autodetect_target_platform

        if Apaka::Packaging::Config.packages_enforce_build.include?('gems')
            test_set["utilrb"] = ["rock-master-ruby-bundler", "rock-master-ruby-facets", "rock-master-ruby-backports"]
        else
            test_set["utilrb"] = []
            ["bundler", "facets", "ruby-backports"].each do |name|
                if target_platform.contains?(name)
                    test_set["utilrb"] << name
                elsif target_platform.contains?("ruby-#{name}")
                    test_set["utilrb"] << "ruby-#{name}"
                else
                    test_set["utilrb"] << "rock-master-ruby-#{name}"
                end
            end
        end

        test_set["rtt"] = ["cmake","omniidl","libomniorb4-dev","omniorb-nameserver",
                                "libboost-dev","libboost-graph-dev","libboost-program-options-dev",
                                "libboost-regex-dev","libboost-thread-dev","libboost-filesystem-dev",
                                "libboost-iostreams-dev","libboost-system-dev","libxml-xpath-perl"]

        test_set.each do |pkg_name, expected_deps|
            pkg = autoprojadaptor.package_by_name(pkg_name)
            pkginfo = autoprojadaptor.pkginfo_from_pkg(pkg)
            deps = packager.dep_manager.recursive_dependencies(pkginfo)
            deps.delete_if { |dep| dep == "ccache" }
            deps.delete_if { |dep| dep == "build-essential" }
            assert_equal(expected_deps.uniq.sort, deps.uniq.sort, "Recursive dependencies for '#{pkg_name}': " \
                   " #{deps} expected #{expected_deps}")
        end
    end

    def test_package
        # cmake package
        ["base/cmake","utilrb"].each do |pkg_name|
            pkg = autoprojadaptor.package_by_name(pkg_name)
            pkginfo = autoprojadaptor.pkginfo_from_pkg(pkg)
            packager.package(pkginfo)
            ["debian.tar.{gz,xz}", "dsc","orig.tar.gz"].each do |suffix|
                files = Dir.glob(File.join(packager.packaging_dir(pkginfo), "*.#{suffix}"))
                assert(files.size == 1, "File with suffix #{suffix} generated")
            end
        end
    end

    def teardown
        FileUtils.rm_rf packager.build_dir
    end

    def test_orig_tgz
        # only package equatable as basic test since it does not
        # require patching
        gems= ['equatable']

        extended_gems = ['rice', 'websocket',['state_machine',"1.1.0"],'rb-readline','concurrent-ruby','qtbindings','tty-cursor','debug_inspector','equatable','tty-color','uber','lazy_priority_queue','stream','necromancer','wisper','tty-screen','unicode-display_width','enumerable-lazy','websocket-extensions','unicode_utils','ice_nine','hoe-yard','binding_of_caller','concurrent-ruby-ext','pastel','hooks','rgl','mustermann','websocket-driver','descendants_tracker','faye-websocket','tty-prompt','tty-table','axiom-types','coercible','virtus','grape','grape_logging']

        require 'digest'

        gems.each do |gem, version|
            if gem =~ /concurrent/ || gem =~ /grape/
                # skip specially handled gems which require patching
                next
            end
            if version
                system("gem install #{gem} -v #{version}")
            else
                system("gem install #{gem}")
            end

            sha256 = nil
            ['jessie','trusty','xenial'].each do |distribution|
                @gem_packager.convert_gems([ [gem, version] ], {:distribution => distribution,
                                                :patch_dir => File.join(Autoproj.root_dir, "deb_patches")
                                               })

                files = Dir.glob(File.join(@gem_packager.build_dir,'**','*.orig.tar.gz') )
                if files.empty?
                    raise RuntimeError, "Failed to generate orig.tar.gz"
                end
                current_sha256 = Digest::SHA256.file files.first
                if !sha256
                    sha256 = current_sha256
                else
                    assert(sha256 == current_sha256, "File for distribution: #{distribution} -- with sha256: #{sha256}")
                end

                # Cleanup file to avoid redundant information
                FileUtils.rm_rf @gem_packager.build_dir
            end
        end
    end
end
