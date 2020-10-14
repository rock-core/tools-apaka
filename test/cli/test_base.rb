require_relative '../test_helper'
require 'apaka'

include Apaka
include Apaka::Packaging

class TestCLIBase < Minitest::Test

    def check_single_package(cli_base, name, number_of_packages, number_of_gems)
        selection = cli_base.prepare_selection([ name ])
        assert_equal(number_of_packages, selection[:pkginfos].size)
        assert_equal(number_of_gems, selection[:gems].size)
        pkginfo = selection[:pkginfos].first
        assert_equal(name, pkginfo.name)
    end

    def check_single_gem(cli_base, name, number_of_packages, number_of_gems)
        selection = cli_base.prepare_selection([ name ])
        assert_equal(number_of_packages, selection[:pkginfos].size)
        assert_equal(number_of_gems, selection[:gems].size)
        assert( selection[:gems].has_key?(name) )

        version = selection[:gems][name]
        assert(version != nil)
    end

    def test_prepare_selection
        cli_base = Apaka::CLI::Base.new

        check_single_package(cli_base, "base/cmake",1,0)
        check_single_package(cli_base, "rtt",1,0)
        check_single_gem(cli_base, "rice",0,1)
    end
end
