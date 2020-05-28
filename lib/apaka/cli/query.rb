require_relative 'base'
require 'apaka/packaging/target_platform'

module Apaka
    module CLI
        class Query < Base
            def validate_options(args, options)
                Base.activate_configuration(options)
                Base.validate_architectures(options)

                if !(dists = options[:distributions]) || dists.empty?
                    raise InvalidArguments, "No distribution provided"
                end
                if !(archs = options[:architectures]) || archs.empty?
                    raise InvalidArguments, "No architecture provided"
                end

                return args, options
            end

            def run(args, options)
                package_name = args
                if options[:activation_status]
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
            end
        end
    end
end
