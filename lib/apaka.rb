require 'autoproj'

if Gem::Version.new(Autoproj::VERSION) >= Gem::Version.new("2.0.0")
    require 'apaka/packaging/autoproj2adaptor'
else
    require 'apaka/packaging/autoproj1adaptor'
end

require_relative 'apaka/packaging/jenkins'
require_relative 'apaka/packaging/config'
require_relative 'apaka/packaging/obs'
require_relative 'apaka/packaging/packager'
require_relative 'apaka/packaging/target_platform'
require_relative 'apaka/packaging/debian'
require_relative 'apaka/packaging/installer'
