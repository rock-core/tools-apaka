require 'rock/packaging/packageinfoask'

module Autoproj
    module Packaging
        class Autoproj1Adaptor < PackageInfoAsk

            attr_accessor :package_set_order

            def self.which
                :autoproj_v1
            end

            def self.probe
                #theoretically, we could check for every thing we use in
                #autoproj, but this should suffice for now.
                defined? Autoproj::CmdLine.initialize_root_directory()
            rescue
                false
            end

            def initialize(options)
            end
        end #class Autoproj
    end #module Packaging
end #module Autoproj

