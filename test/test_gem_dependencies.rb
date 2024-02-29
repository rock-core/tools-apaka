require 'minitest/autorun'
require_relative '../lib/apaka/packaging/gem_dependencies'
require 'date'


class TestGemDependencies < Minitest::Test
    def setup
        Apaka::Packaging::GemDependencies.gemfile = File.join(__dir__, "workspace", ".autoproj", "Gemfile")
    end

    def test_release_date
        date = Apaka::Packaging::GemDependencies.get_release_date("backports")
        assert(date)

        date = Apaka::Packaging::GemDependencies.get_release_date("backports", version = "3.15.0")
        timestamp = date.strftime("%Y%m%d")
        assert(timestamp = "20190515")
    end

    def test_is_gem
        assert(Apaka::Packaging::GemDependencies.is_gem?("facets"))
        assert(!Apaka::Packaging::GemDependencies.is_gem?("base/cmake"))
    end

    def test_resolve_all
        deps = Apaka::Packaging::GemDependencies.resolve_all([["rgl","0.5.10"]])
        dep_names = deps.collect {|x| x[0]}
        ["stream", "pairing_heap", "rexml"].each do |dep_name|
            assert dep_names.include?(dep_name), "Require #{dep_name} in dependencies: #{dep_names.sort}"
        end

        deps = Apaka::Packaging::GemDependencies.resolve_all([["rgl","0.5.7"]])
        dep_names = deps.collect {|x| x[0]}
        ["stream", "lazy_priority_queue"].each do |dep_name|
            assert dep_names.include?(dep_name), "Require #{dep_name} in dependencies: #{dep_names.sort}"
        end
    end

    def test_resolve_by_name
        deps = Apaka::Packaging::GemDependencies.resolve_by_name("rgl", version: "0.5.10")
        dep_names = deps.collect {|x| x[0]}
        ["stream", "pairing_heap", "rexml"].each do |dep_name|
            assert dep_names.include?(dep_name), "Require #{dep_name} in dependencies: #{dep_names.sort}"
        end
    end

end
