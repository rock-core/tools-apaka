require 'minitest/autorun'
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
Autoproj.root_dir = File.join(__dir__,"workspace")
$autoprojadaptor = Apaka::Packaging::PackageInfoAsk.new(:detect, Hash.new())

def autoprojadaptor
    $autoprojadaptor
end

Apaka::Packaging.root_dir = autoprojadaptor.root_dir

Apaka::Packaging::TargetPlatform.osdeps_release_tags= autoprojadaptor.osdeps_release_tags

class TestDebian < Minitest::Test

    attr_reader :packager

    def setup
        @packager = Apaka::Packaging::Debian.new
        @packager.rock_release_name = "master"
        @packager.build_dir = File.join(Autoproj.root_dir, "build/test-rock-packager")
        Dir.chdir(Autoproj.root_dir) do
            cmd = "RUBYLIB=#{File.join(__dir__,'..','lib')} PATH=#{File.join(__dir__,'..','bin')}:#{ENV['PATH']} deb_local --prepare"
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
           assert(packager.canonize(tin) == tout)
        end
    end

    def test_basename
        test_set = { "tools/metapackage" => "metapackage" }
        test_set = { "tools/orogen/metapackage" => "metapackage" }
        test_set.each do |tin,tout|
           assert(packager.basename(tin) == tout)
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
        if Apaka::Packaging::Config.packages_enforce_build.include?('gems')
            test_set["utilrb"] = ["rock-master-ruby-bundler", "rock-master-ruby-facets"]
        else
            test_set["utilrb"] = ["bundler", "ruby-facets"]
        end

        test_set["rtt"] = ["cmake","build-essential","omniidl","libomniorb4-dev","omniorb-nameserver",
                                "libboost-dev","libboost-graph-dev","libboost-program-options-dev",
                                "libboost-regex-dev","libboost-thread-dev","libboost-filesystem-dev",
                                "libboost-iostreams-dev","libboost-system-dev","libxml-xpath-perl"]

        test_set.each do |pkg_name, expected_deps|
            pkg = autoprojadaptor.package_by_name(pkg_name)
            pkginfo = autoprojadaptor.pkginfo_from_pkg(pkg)
            deps = packager.recursive_dependencies(pkginfo)
            deps.delete_if { |dep| dep == "ccache" }
            assert(deps.uniq.sort == expected_deps.uniq.sort, "Recursive dependencies for '#{pkg_name}': " \
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
                packager.convert_gems([ [gem, version] ], {:distribution => distribution,
                                                :patch_dir => File.join(Autoproj.root_dir, "deb_patches")
                                               })

                files = Dir.glob(File.join(packager.build_dir,'**','*.orig.tar.gz') )
                if files.empty?
                    raise RuntimeError, "Failed to generate orig.tar.gz"
                end
                current_sha256 = Digest::SHA256.file files.first
                if !sha256
                    sha256 = current_sha256
                else
                    assert(sha256 == current_sha256, "File for distribution: #{distribution} -- with sha256: #{sha256}")
                end

                # Cleanup file to avoid redunant information
                FileUtils.rm_rf packager.build_dir
            end
        end
    end

end

class TestTargetPlatform < Minitest::Test

    attr_reader :platforms

    def setup
        @platforms = Array.new
        @platforms << Apaka::Packaging::TargetPlatform.new("jessie","amd64")
        @platforms << Apaka::Packaging::TargetPlatform.new("trusty","amd64")
        @platforms << Apaka::Packaging::TargetPlatform.new("xenial","amd64")

        @rock_platforms = Array.new
        @rock_platforms << Apaka::Packaging::TargetPlatform.new("master","amd64")
        Dir.chdir(Autoproj.root_dir) do
            cmd = "RUBYLIB=#{File.join(__dir__,'..','lib')} PATH=#{File.join(__dir__,'..','bin')}:#{ENV['PATH']} deb_local --prepare"
            msg, status = Open3.capture2(cmd)
            if !status.success?
                raise RuntimeError, "Failed to prepare system for apaka -- #{msg}"
            end
        end
    end

    def test_distribution
        ["jessie","sid"].each do |name|
            assert(Apaka::Packaging::TargetPlatform::isDebian(name), "'#{name}' is debian distribution")
        end
        ["trusty","vivid","wily","xenial","yakkety"].each do |name|
            assert(Apaka::Packaging::TargetPlatform::isUbuntu(name), "'#{name}' is ubuntu distribution")
        end
    end

    def test_package_available
        enforce_build = Apaka::Packaging::Config.packages_enforce_build
        Apaka::Packaging::Config.packages_enforce_build = []
        ["cucumber","bundler","ruby-facets","cmake"].each do |pkg|
            platforms.each do |platform|
                assert( platform.contains(pkg), "'#{pkg} is available for #{platform}" )
            end
        end
        Apaka::Packaging::Config.packages_enforce_build = enforce_build
    end

    def test_package_unavailable
        ["ruby-cucumber"].each do |pkg|
            platforms.each do |platform|
                assert( !platform.contains(pkg), "'#{pkg}' is unavailable for #{platform}" )
            end
        end
    end

    def test_rock_package_available
        Dir.chdir(Autoproj.root_dir) do
            cmd = "RUBYLIB=#{File.join(__dir__,'..','lib')} PATH=#{File.join(__dir__,'..','bin')}:#{ENV['PATH']} deb_local --rebuild --release-name master base/cmake"
            msg, status = Open3.capture2(cmd)
        end
        ["rock-master-base-cmake"].each do |pkg|
            @rock_platforms.each do |platform|
                assert( platform.contains(pkg), "'#{pkg}' is available for #{platform}" )
            end
        end
    end
    def test_rock_package_unavailable
        ["rock-master-nopackage"].each do |pkg|
            @rock_platforms.each do |platform|
                assert( !platform.contains(pkg), "'#{pkg}' is not available for #{platform}" )
            end
        end
    end
    def test_ruby_package_unavailable
        ["nonsense","concurrent-ruby"].each do |pkg|
            @platforms.each do |platform|
                assert( !platform.contains(pkg), "'#{pkg}' is not available for #{platform}")
            end
        end
    end

    def test_rock_all_parents
        assert( Apaka::Packaging::TargetPlatform.ancestors("transterra").include?("master"), "Ancestors of transterra bootstrap contains master" )
        assert( Apaka::Packaging::TargetPlatform.ancestors("master").empty?, "Ancestors of master release do not exist" )
    end

    def test_rock_parent_contains
        Dir.chdir(Autoproj.root_dir) do
            cmd = "RUBYLIB=#{File.join(__dir__,'..','lib')} PATH=#{File.join(__dir__,'..','bin')}:#{ENV['PATH']} deb_local --release-name master base/cmake"
            msg, status = Open3.capture2(cmd)
        end
        Apaka::Packaging::Config.rock_releases["transterra"] = { :depends_on => ["master"], :url => "" }
        transterra = Apaka::Packaging::TargetPlatform.new("transterra","amd64")
        ["rock-master-base-cmake"].each do |pkg|
            assert( transterra.ancestorContains(pkg), "'#{transterra} ancestor contains #{pkg}" )
        end
    end

    def test_rock_release_name
        d = Apaka::Packaging::Debian.new
        valid_names = ["master-18.01","master","master-18-01.1"]
        valid_names.each do |name|
            begin
                d.rock_release_name = name
                assert(true, "Valid release names #{valid_names.join(',')} detected")
            rescue ArgumentError => e
                assert(false, "Valid release names #{valid_names.join(',')} detected - #{e}")
            end
        end

        invalid_names = ["1-master","master_18.01"]
        invalid_names.each do |name|
            begin
                d.rock_release_name = name
	        assert(false, "Invalid release name #{name} is detected")
	    rescue ArgumentError => e
	        assert(true, "Invalid release name #{name} is detected - #{e}")
	    end
        end
    end

    def test_apt_show
        package_type = Apaka::Packaging::TargetPlatform.aptShow("yard","Section")
        expected_package_type = "universe/ruby"
        assert(expected_package_type == package_type , "Yard" \
               " correctly extracted section information: expected '#{expected_package_type}', was '" + package_type + "'")

        assert(Apaka::Packaging::TargetPlatform::isRuby("yard"), "Yard" \
               " correctly identified as ruby package")
    end
end
