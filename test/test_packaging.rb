require 'minitest/autorun'
require 'rock/packaging'

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
class TestDebian < Minitest::Test
    def test_release_name
        packager = Autoproj::Packaging::Debian.new
        packager.rock_release_name="master"
        assert(packager.rock_release_hierarchy == ["master"], "Rock release hierarchy should contain self")
    end
end

class TestTargetPlatform < Minitest::Test

    attr_reader :platforms

    def setup
        @platforms = Array.new
        @platforms << Autoproj::Packaging::TargetPlatform.new("jessie","amd64")
        @platforms << Autoproj::Packaging::TargetPlatform.new("trusty","amd64")
        @platforms << Autoproj::Packaging::TargetPlatform.new("xenial","amd64")

        @rock_platforms = Array.new
        @rock_platforms << Autoproj::Packaging::TargetPlatform.new("master","amd64")
    end

    def test_distribution
        ["jessie","sid"].each do |name|
            assert(Autoproj::Packaging::TargetPlatform::isDebian(name), "'#{name}' is debian distribution")
        end
        ["trusty","vivid","wily","xenial","yakkety"].each do |name|
            assert(Autoproj::Packaging::TargetPlatform::isUbuntu(name), "'#{name}' is ubuntu distribution")
        end
    end

    def test_package_available
        ["cucumber","bundler","ruby-facets","cmake"].each do |pkg|
            platforms.each do |platform|
                assert( platform.contains(pkg), "'#{pkg} is available for #{platform}" )
            end
        end
    end

    def test_package_unavailable
        ["ruby-cucumber"].each do |pkg|
            platforms.each do |platform|
                assert( !platform.contains(pkg), "'#{pkg}' is unavailable for #{platform}" )
            end
        end
    end

    def test_rock_package_available
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
        assert( Autoproj::Packaging::TargetPlatform.ancestors("transterra").include?("master"), "Ancestors of transterra boostrap contains master" )
        assert( Autoproj::Packaging::TargetPlatform.ancestors("master").empty?, "Ancestors of master release do not exist" )
    end

    def test_rock_parent_contains
        Autoproj::Packaging::Config.rock_releases["transterra"] = { :depends_on => ["master"], :url => "" }
        transterra = Autoproj::Packaging::TargetPlatform.new("transterra","amd64")
        ["rock-master-base-cmake"].each do |pkg|
            assert( transterra.ancestorContains(pkg), "'#{transterra} ancestor contains #{pkg}" )
        end
    end
end
