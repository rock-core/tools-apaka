require_relative 'test_helper'
require_relative '../lib/apaka'

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
            cmd = "RUBYLIB=#{File.join(__dir__,'..','lib')} PATH=#{File.join(__dir__,'..','bin')}:#{ENV['PATH']} apaka prepare"
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
        cmd = "sudo mount -t proc /proc/ /mnt"
        msg, status = Open3.capture2e(cmd)
        if status.success?
            cmd = "sudo umount /mnt"
            msg, status = Open3.capture2e(cmd)

            Dir.chdir(Autoproj.root_dir) do
                cmd = "RUBYLIB=#{File.join(__dir__,'..','lib')} PATH=#{File.join(__dir__,'..','bin')}:#{ENV['PATH']} apaka build --rebuild --release-name master base/cmake"
                msg, status = Open3.capture2(cmd)
                if not status.success?
                    raise RuntimeError, "Failed to build base/cmake -- #{msg}"
                end
            end
            ["rock-master-base-cmake"].each do |pkg|
                @rock_platforms.each do |platform|
                    assert( platform.contains(pkg), "'#{pkg}' is available for #{platform}" )
                end
            end
        else
            puts "Disabling test #test_rock_package_available since current "\
                "setup does not support mounting of /proc filesystem. " \
                "If you a running inside a docker use with --priviledge"
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
            cmd = "RUBYLIB=#{File.join(__dir__,'..','lib')} PATH=#{File.join(__dir__,'..','bin')}:#{ENV['PATH']} apaka build --release-name master base/cmake"
            msg, status = Open3.capture2(cmd)
        end
        Apaka::Packaging::Config.rock_releases["transterra"] = { :depends_on => ["master"], :url => "" }
        transterra = Apaka::Packaging::TargetPlatform.new("transterra","amd64")
        ["rock-master-base-cmake"].each do |pkg|
            assert( transterra.ancestorContains(pkg), "'#{transterra} ancestor contains #{pkg}" )
        end
    end

    def test_rock_release_name
        d = Apaka::Packaging::Deb::Package2Deb.new
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
