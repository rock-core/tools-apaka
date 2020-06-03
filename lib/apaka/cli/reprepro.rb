require_relative 'base'
require_relative 'package'

require 'apaka/packaging/deb/package2deb'

module Apaka
    module CLI
        class Reprepro < Base
            def initialize
                super()
            end

            def validate_options(args, options)
                Base.activate_configuration(options)

                args, options = Base.validate_options(args, options)
                [:dest_dir, :base_dir, :patch_dir, :config_file, :log_dir].each do |path_option|
                    Base.validate_path(options, path_option)
                end

                options[:architecture] = validate_architecture(options)
                options[:distribution] = validate_distribution(options)
                options[:release_name] ||= Packaging.default_release_name

                return args, options
            end

            def run(args, options)
                selected_packages = args

                packager = Apaka::Packaging::Deb::Package2Deb.new(options)
                if options[:register]
                    selected_packages.each do |pkg_name_expression|
                        packager.reprepro.register_debian_package(pkg_name_expression,
                                                           options[:release_name],
                                                           options[:distribution])
                    end
                end

                if options[:deregister]
                    selected_packages.each do |pkg_name_expression|
                        packager.reprepro.deregister_debian_package(pkg_name_expression,
                                                           options[:release_name],
                                                           options[:distribution])
                    end
                end

            end
        end
    end
end
