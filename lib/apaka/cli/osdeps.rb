require_relative 'base'
require 'apaka/packaging/deb/osdeps'
require 'apaka/packaging/deb/package2deb'

module Apaka
    module CLI
        class Osdeps < Base
            def validate_options(args, options)
                Base.activate_configuration(options)

                [:dest_dir].each do |path_option|
                    Base.create_dir(options, path_option)
                end

                selected_packages = args
                selection = prepare_selection(selected_packages, no_deps: options[:no_deps])
                return selection, options
            end

            def run(selection, options)
                packager = Apaka::Packaging::Deb::Package2Deb.new(options)
                selection[:pkginfos].each do |pkginfo|
                    Apaka::Packaging::Deb::Osdeps.update_osdeps_lists(packager,
                                                                  pkginfo,
                                                                  options[:dest_dir])
                end

                selection[:gems].each do |gem, version|
                    Apaka::Packaging::Deb::Osdeps.update_osdeps_lists(packager,
                                                                  gem,
                                                                  options[:dest_dir])
                end
            end
        end
    end
end

