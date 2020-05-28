require_relative 'base'

module Apaka
    module CLI
        class Config < Base
            def validate_options(args, options)
                Base.activate_configuration(options)
                return args, options
            end

            def run(args, options)
                if options[:show]
                    puts Apaka::Packaging::Config.to_s
                end
            end
        end
    end
end
