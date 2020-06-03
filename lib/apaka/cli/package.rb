require_relative 'base'
require 'apaka/packaging/config'

module Apaka
    module CLI
        class Package < Base
            # The packager to use
            attr_reader :packager

            def initialize
                super()
            end

            def activate_distribution(distribution)
                operating_system = []
                preferred_ruby_version = nil
                if Apaka::Packaging::Config.linux_distribution_releases.has_key?(distribution)
                    operating_system = Apaka::Packaging::Config.linux_distribution_releases[ distribution ]
                else
                    raise CLI::InvalidArguments, "Custom setting of operating system to: #{distribution} is not supported"
                end

                if Apaka::Packaging::Config.preferred_ruby_version.has_key?(distribution)
                    preferred_ruby_version = Apaka::Packaging::Config.preferred_ruby_version[ distribution ]
                end

                if !operating_system.empty?
                    package_info_ask.osdeps_operating_system = operating_system
                    Apaka::Packaging.info "Custom setting of operating system to: #{operating_system}"
                    if preferred_ruby_version
                        package_info_ask.osdeps_set_alias(preferred_ruby_version,"ruby")
                        Apaka::Packaging.info "Setting preferred ruby version: #{preferred_ruby_version}"
                    end
                end
            end

            def validate_options(args, options)
                Base.activate_configuration(options)

                args, options = Base.validate_options(args, options)
                [:dest_dir, :base_dir, :patch_dir, :config_file, :pkg_set_dir].each do |path_option|
                    Base.validate_path(options, path_option)
                end

                options[:architecture] = validate_architecture(options)
                options[:distribution] = validate_distribution(options)

                selected_packages = args
                if selected_packages.size > 1 && options[:version]
                    raise InvalidArguments, "Cannot use version option with multiple packages as argument"
                end

                selection = prepare_selection(selected_packages, no_deps: options[:no_deps])
                return selection, options
            end

            # Run the packaging with options
            #
            # @param selection [Hash] Hash { :pkginfos => .., :gems => ..., :meta_packages => .... } as returned
            #   from Base.prepare_selection
            # @param options [Hash]
            def run(selection, options)
                acquire_lock

                packaging_results = []

                Autobuild.do_update = true

                @packager = Apaka::Packaging::Deb::Package2Deb.new(options)
                @packager.build_dir = options[:build_dir] if options[:build_dir]

                # workaround for orogen
                @packager.rock_autobuild_deps[:orogen] = [ package_info_ask.pkginfo_by_name("orogen") ]
                if ancestor_blacklist = options[:ancestor_blacklist]
                    Apaka::Packaging::TargetPlatform::ancestor_blacklist = ancestor_blacklist.map do |pkg_name|
                        pkginfo = package_info_ask.pkginfo_by_name(pkg_name)
                        @packager.debian_name(pkginfo, false)
                    end.to_set
                end

                packages, extra_gems = @packager.package_selection(selection[:pkginfos],
                                                                  force_update: options[:rebuild],
                                                                  patch_dir: options[:patch_dir],
                                                                  package_set_dir: options[:package_set_dir],
                                                                  use_remote_repository: options[:use_remote_repository])
                packaging_results << [ @packager, packages]

                if !options[:no_deps]
                    extra_gems.each do |name, version|
                        existing_version = selection[:gems][name]
                        selection[:gems][name] = existing_version || version
                    end
                end

                @gem2deb_packager = Apaka::Packaging::Deb::Gem2Deb.new(options)
                @gem2deb_packager.build_dir = options[:build_dir] if options[:build_dir]
                gems = @gem2deb_packager.package_gems(selection[:gems], force_update: options[:rebuild], patch_dir: options[:patch_dir])

                packaging_results << [ @gem2deb_packager, gems ]

                sync_packages = packages + gems
                if options[:dest_dir]
                    sync_packages.each do |debian_pkg_name|
                        # sync the directory in build/debian and the target directory based on an existing
                        # files pattern

                        files = []
                        @packager.file_suffix_patterns.map do |p|
                            # Finding files that exist in the source directory
                            # needs to handle ruby-hoe_0.20130113/*.dsc vs. ruby-hoe-yard_0.20130113/*.dsc
                            # and ruby-hoe/_service
                            glob_exp = File.join(@packager.build_dir,debian_pkg_name,"*#{p}")
                            files += Dir.glob(glob_exp)
                        end
                        files = files.flatten.uniq
                        dest_dir = File.join(options[:dest_dir], debian_pkg_name)

                        FileUtils.mkdir_p dest_dir
                        FileUtils.cp files, dest_dir
                    end
                end
                @gem2deb_packager.cleanup

                packaging_results
            end

#            def build_local
#                begin
#                    selected_gems.each do |gem_name, gem_version|
#                        pkg = package_info_ask.package(gem_name)
#                        options =  {:distributions => o_distributions, :verbose => Autobuild.verbose}
#                        if pkg && pkg.autobuild
#                            options[:parallel_build_level] = pkg.autobuild.parallel_build_level
#                        end
#                        filepath = packager.build_local_gem gem_name, options 
#                        puts "Debian package created for gem '#{gem_name}': " + filepath
#                        if o_dest_dir
#                            puts "Copying debian package to destination folder: #{dest_dir}"
#                            FileUtils.mkdir_p dest_dir
#                            FileUtils.cp filepath, dest_dir
#                        end
#                    end
#
#                    selection.each_with_index do |pkg_name, i|
#                        if pkg = package_info_ask.package(pkg_name)
#                            pkg = pkg.autobuild
#                        else
#                            Apaka::Packaging.warn "Package: #{pkg_name} is not a known rock package (but maybe a ruby gem?)"
#                            next
#                        end
#
#                        pkginfo = package_info_ask.pkginfo_from_pkg(pkg)
#                        filepath = packager.build_local_package pkginfo, :distributions => o_distributions, :verbose => Autobuild.verbose
#                        puts "Debian package created for package '#{pkg}': #{filepath}"
#                        if o_dest_dir
#                            puts "Copying debian package to destination folder: #{dest_dir}"
#                            FileUtils.mkdir_p dest_dir
#                            FileUtils.cp filepath, dest_dir
#                        end
#                    end
#                rescue Exception => e
#                    Apaka::Packaging.warn "Local build failed: #{e}"
#                    puts e.backtrace
#                    exit 10
#                end
#            end
        end
    end
end
