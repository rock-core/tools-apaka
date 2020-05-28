require_relative 'base'

module Apaka
    module CLI
        class Osdeps < Base
            def validate_options(args, options)
                Base.active_configuration(options)

                [:dest_dir].each do |path_option|
                    Base.create_dir(options, path_option)
                end
                return args, options
            end

            def run(args, options)

            end
        end
    end
end

