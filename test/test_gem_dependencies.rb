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

    def test_installation_status
        installed, dependencies = Apaka::Packaging::GemDependencies.installation_status("autoproj")
        assert(installed)
        puts(dependencies)

        desc = Apaka::Packaging::GemDependencies.resolve_by_name("autoproj")
        puts(desc)
        assert(desc.include?(:deps))
    end
end
