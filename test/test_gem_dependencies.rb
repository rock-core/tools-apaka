require 'minitest/autorun'
require_relative '../lib/apaka/packaging/gem_dependencies'
require 'date'


class TestGemDependencies < Minitest::Test
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
end
