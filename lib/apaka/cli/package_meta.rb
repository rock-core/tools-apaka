require_relative 'base'
require 'apaka/packaging/deb/gem2deb'

module Apaka
    module CLI
        class PackageMeta < Base
            def initialize
                super()
            end

            def prepare_meta_package(packager, selection)
                selection = prepare_selection(selection)
                meta_package =
                    selection[:pkginfos].collect {|pkginfo| pkginfo.name } +
                    selection[:gems].select do |gem, version|
                        native_name, is_osdeps = packager.dep_manager.native_dependency_name(pkg)
                        !is_osdeps
                    end
            end

            def validate_options(args, options)
                Base.activate_configuration(options)
                args, options = Base.validate_options(args, options)

                [:build_dir].each do |path_option|
                    Base.validate_path(options, path_option)
                end

                options[:architecture] = validate_architecture(options)
                options[:distribution] = validate_distribution(options)

                default_pkg_name = "full"
                if args.empty?
                    args = [ default_pkg_name ] 
                elsif args.size > 1
                    raise CLI::InvalidArguments, "Too many arguments: '#{args}' only one name for the meta package is allowed"
                end

                selection = {}
                if options[:dependencies] and options[:dependencies].size > 0
                    selection = prepare_selection(options[:dependencies])
                end
                package_name = args.first
                if package_info_ask.is_metapackage?(package_name)
                    Apaka::Packaging.info "#{package_name} is an autoproj" 
                        " meta package"
                    selection = prepare_selection([package_name])
                elsif package_info_ask.package(package_name)
                    raise CLI::InvalidArguments, "Your provided name ' #{package_name}' for the " \
                        "meta package refer to an already existing package"
                end
                selection[:meta] = Packaging::Deb.canonize(package_name)

                [selection, options]
            end

            def run(selection, options)
                @packager = Apaka::Packaging::Deb::Gem2Deb.new(options)
                @packager.build_dir = options[:build_dir] if options[:build_dir]

                dependencies = []
                if selection.has_key?(:pkginfos)
                    selection[:pkginfos].each do |pkginfo|
                        dependencies << @packager.debian_name(pkginfo.name)
                    end
                    selection[:gems].each do |gem, version|
                        dependencies << @packager.debian_ruby_name(pkginfo.name)
                    end
                else
                    dependencies = @packager.reprepro.list_registered(options[:release_name],
                                                                      options[:distribution],
                                                                      options[:architecture],
                                                                      exclude_meta: true)
                end

                @packager.package_meta(selection[:meta], dependencies, 
                                       version: options[:package_version],
                                       force_update: options[:rebuild],
                                       distribution: options[:distribution],
                                       architecture: options[:architecture])
               
                package_name = @packager.debian_meta_name(selection[:meta])

                [@packager, package_name]
            end

        end
    end
end
