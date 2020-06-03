require_relative 'base'
require_relative 'package_meta'
require_relative 'build'

module Apaka
    module CLI
        class BuildMeta < Base
            def initialize
                super()

                @package_meta = Apaka::CLI::PackageMeta.new
                @build = Apaka::CLI::Build.new
            end

            def validate_options(args, options)
                selection, options = @package_meta.validate_options(args, options)
                [selection, options]
            end

            def run(selection, options)
                packager, debian_pkg_name = @package_meta.run(selection, options)
                @build.build(packager, debian_pkg_name, options)
                @build.install(packager, debian_pkg_name, options) if options[:install]
            end
        end
    end
end
