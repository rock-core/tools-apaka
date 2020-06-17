require 'tty/color'
require 'autoproj/cli'
require 'apaka'

module Apaka
    module CLI
        class Base
            attr_reader :lock_file
            attr_reader :active_platform
            attr_reader :package_info_ask

            def initialize
                @package_info_ask = Apaka::Packaging::PackageInfoAsk.new(:detect, Hash.new())
                Apaka::Packaging::TargetPlatform.osdeps_release_tags = package_info_ask.osdeps_release_tags
                @active_platform = Apaka::Packaging::TargetPlatform.autodetect_target_platform
                @lock_file = File.open("/tmp/apaka-package.lock",File::CREAT)
            end

            def acquire_lock
                # Prevent deb_package from parallel execution since autoproj configuration loading
                # does not account for parallelism
                Apaka::Packaging.debug "deb_package: waiting for execution lock"
                lock_time = Time.now
                lock_file.flock(File::LOCK_EX)
                lock_wait_time_in_s = Time.now - lock_time
                Apaka::Packaging.debug "deb_package: execution lock acquired after #{lock_wait_time_in_s} seconds"
            end

            def validate_options(args, options)
                self.class.validate_options(args, options)
            end

            def self.validate_path(options, option_name)
                if path = options[option_name]
                    if !File.exist?(path)
                        raise InvalidArguments, "Given path for #{option_name} does not exist: #{path}"
                    else
                        options[option_name] = File.expand_path(path)
                    end
                end
            end

            def validate_architecture(options)
                if arch = options[:architecture]
                    if !Apaka::Packaging::Config.architectures.include?(arch)
                        raise InvalidArguments, "Architecture #{arch} is not found in configuration"
                    end
                    return arch
                end
                active_platform.architecture
            end

            def self.validate_architectures(options)
                if archs = options[:architectures]
                    archs.each do |arch|

                        if !Apaka::Packaging::Config.architectures.include?(arch)
                            raise InvalidArguments, "Architecture #{arch} is not found in configuration"
                        end
                    end
                end
            end

            def validate_distribution(options, default: nil)
                if dist = options[:distribution]
                    if !Apaka::Packaging::Config.active_distributions.include?(dist)
                        raise InvalidArguments, "Distribution #{dist} is not found in configuration"
                    end
                    return dist
                end
                active_platform.distribution_release_name
            end


            def self.validate_distributions(options)
                if dists = options[:distributions]
                    dists.each do |dist|
                        if !Apaka::Packaging::Config.active_distributions.include?(dist)
                            raise InvalidArguments, "Distribution #{dist} is not found in configuration"
                        end
                    end
                end
            end

            # Activate the configuration if a configuration file is provided
            def self.activate_configuration(options)
                if config = options[:config_file]
                    if File.exists?(config)
                        Apaka::Packaging::Config.reload_config(config, options[:release_name])
                    end
                end
            end

            def self.create_dir(options, option_name)
                if path = options[option_name]
                    if !File.directory?(path)
                        FileUtils.mkdir_p path
                    end
                end
            end

            # Handling selection to split between 'normal' packages and gems,
            # also handle special packages which have been moved in the layout, in case the user is
            # using the 'moved' package name
            # return [Hash] { pkginfos: [], gems: { gem_name => gem_version, ...] }
            def prepare_selection(selection, no_deps: false)
                Autoproj.manifest.moved_packages.each do |original_name, moved_name|
                    if selection.include?(moved_name)
                        selection.delete(moved_name)
                        selection << original_name
                        Apaka::Packaging.info "Identified package '#{moved_name}' as moved package, hence using its original name '#{original_name}'"
                    end
                end

                selected_gems = []
                selected_packages = selection.select do |name|
                    if pkg = package_info_ask.package(name)
                        Apaka::Packaging.debug "Package: #{name} is a known rock package"
                        true
                    elsif package_info_ask.is_metapackage?(name)
                        Apaka::Packaging.debug "Package: #{name} is a known rock meta package"
                        #we want the dependencies(which it will resolve to)
                        true
                    elsif Apaka::Packaging::GemDependencies::is_gem?(name)
                        Apaka::Packaging.debug "Package: #{name} is a gem"
                        selected_gems << [name, nil]
                        false
                    else
                        true
                    end
                end

                meta_packages = {}

                # If no package has been selected then the full manifest is used
                selection = package_info_ask.autoproj_init_and_load(selected_packages)
                selection = package_info_ask.resolve_user_selection_packages(selection)
                # Make sure that when we request a package build we only get this one,
                # and not the pattern matched to other packages, e.g. for orogen
                selection = selection.select do |pkg_name, i|
                    if selected_packages.empty? or selected_packages.include?(pkg_name)
                        if package_info_ask.is_metapackage?(pkg_name)
                            meta_packages[pkg_name] = package_info_ask.resolve_user_selection_packages([pkg_name])
                        end

                        Apaka::Packaging.info "Package: #{pkg_name} is in selection"
                        true
                    else
                        false
                    end
                end

                # Compute dependencies for a given selection
                package_info_ask.package_set_order = ["orocos.toolchain","rock.core","rock"]
                all_packages = package_info_ask.all_required_packages selection, selected_gems, no_deps: no_deps

                selected_names = all_packages[:pkginfos].collect do |pkg|
                    pkg.name
                end

                gems = {}
                all_packages[:gems].each_with_index do |val, index|
                    gems[val] = all_packages[:gem_versions][val]
                    selected_names << val
                end

                Apaka::Packaging.info "Selection: #{selected_names}"

                {pkginfos: all_packages[:pkginfos], gems: gems, meta_packages: meta_packages}
            end

            def self.validate_options(args, options)
                options, remaining = filter_options options,
                    silent: false,
                    verbose: false,
                    debug: false,
                    color: TTY::Color.color?,
                    progress: TTY::Color.color?

                Autoproj.silent = options[:silent]
                Autobuild.color = options[:color]
                Autobuild.progress_display_enabled = options[:progress]

                if options[:verbose]
                    Autoproj.verbose  = true
                    Autobuild.verbose = true
                    Autobuild.debug = false
                end

                if options[:debug]
                    Autoproj.verbose  = true
                    Autobuild.verbose = true
                    Autobuild.debug = true
                end

                return args, remaining.to_sym_keys
            end

        end
    end
end
