require 'tty/color'
require 'autoproj/cli'
require 'apaka'

module Apaka
    module CLI
        class Base
            attr_reader :active_platform
            attr_reader :package_info_ask

            def initialize
                @package_info_ask = Apaka::Packaging::PackageInfoAsk.new(:detect, Hash.new())
                Apaka::Packaging::TargetPlatform.osdeps_release_tags = package_info_ask.osdeps_release_tags
                @active_platform = Apaka::Packaging::TargetPlatform.autodetect_target_platform
            end

            def validate_options(args, options)
                self.class.validate_options(args, options)
            end

            def self.validate_path(options, option_name)
                if path = options[option_name]
                    if !File.exist?(path)
                        raise InvalidArguments, "Given path for #{option_name} does not exist: #{path}"
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

            def self.validate_options(args, options)
                options, remaining = filter_options options,
                    silent: false,
                    verbose: false,
                    debug: false,
                    color: TTY::Color.color?,
                    progress: TTY::Color.color?,
                    parallel: nil

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

                if level = options[:parallel]
                end

                return args, remaining.to_sym_keys
            end

        end
    end
end
