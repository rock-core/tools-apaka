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
require_relative 'apaka/packaging/deb/package2deb'
require_relative 'apaka/packaging/deb/gem2deb'
require_relative 'apaka/packaging/gem/package2gem'
require_relative 'apaka/packaging/installer'
