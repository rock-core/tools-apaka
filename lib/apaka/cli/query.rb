require_relative 'base'
require 'apaka/packaging/target_platform'

module Apaka
    module CLI
        class Query < Base
            def require_distribution
                if !(dists = options[:distributions]) || dists.empty?
                    raise InvalidArguments, "No distribution provided"
                end
            end
            def require_arch
                if !(archs = options[:architectures]) || archs.empty?
                    raise InvalidArguments, "No architecture provided"
                end
            end

            def validate_options(args, options)
                Base.activate_configuration(options)
                Base.validate_architectures(options)

                return args, options
            end

            def run(args, options)
                package_name = args
                if options[:activation_status]
                    require_distribution()
                    require_arch()

                    options[:distributions].each do |dist|
                        options[:architectures].each do |arch|
                            if Apaka::Packaging::Config.is_active?(dist, arch)
                                puts "#{dist}/#{arch}\tactive"
                            else
                                puts "#{dist}/#{arch}\t not active"
                            end
                        end
                    end
                end

                if options[:exists]
                    require_distribution()
                    require_arch()

                    options[:distributions].each do |dist|
                        options[:architectures].each do |arch|
                            target_platform = Apaka::Packaging::TargetPlatform.new(dist, arch)
                            if target_platform.contains(dist, package_name)
                                puts "Package #{package_name} exists in distribution #{dist}"
                            else
                                puts "Package #{package_name} does not exist in distribution #{dist}"
                            end
                        end
                    end
                end

                if options[:current_os]
                    os = package_info_ask.osdeps_operating_system
                    puts "Current operating system:"
                    if os
                        puts "    type: #{os[0].join(",")}"
                        puts "    labels: #{os[1].join(",")}"
                    end
                end
            end
        end
    end
end
