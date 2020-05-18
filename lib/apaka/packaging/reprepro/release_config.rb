module Apaka
    module Packaging
        module Reprepro
            class ReleaseConfig
                attr_accessor :codename
                attr_accessor :description
                attr_accessor :architectures
                attr_accessor :sign_with
                attr_accessor :components
                attr_accessor :udeb_components
                attr_accessor :tracking
                attr_accessor :contents

                def initialize(codename = nil)
                    @codename = codename
                end

                def to_s
                    s  = "Codename: #{codename}\n"
                    s += "Description: #{description}\n"
                    s += "Architectures: #{architectures.join(' ')}\n" if architectures
                    s += "SignWith: #{sign_with}\n" if sign_with
                    s += "Components: #{components}\n"
                    s += "UDebComponents: #{udeb_components}\n"
                    s += "Tracking: #{tracking}\n"
                    s += "Contents: #{contents}\n"
                    s
                end
            end
        end
    end
end

