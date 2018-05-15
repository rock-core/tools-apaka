# coding: utf-8
require 'rbconfig'

lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'apaka/version'

Gem::Specification.new do |s|
    s.name = "apaka"
    s.version = Apaka::VERSION
    s.authors = ["Thomas Roehr", "Pierre Willenbrock", "Sylvain Joyeux"]
    s.email = "thomas.roehr@dfki.de"
    s.summary = "Automated package creating based on autoproj"
    s.description = "autoproj is a manager for sets of software packages. It allows the user to import and build packages from source. apaka build upon autoproj's functionality and enables the creation of packages: currently only Debian package are supported"
    s.homepage = "http://github.com/rock-core/apapa"
    s.licenses = ["BSD"]

    s.required_ruby_version = '>= 2.1.0'
    s.bindir = 'bin'
    s.executables = ['deb_local','deb_package']
    s.require_paths = ["lib"]
    s.extensions = []
    s.files         = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test)/}) }

    s.add_runtime_dependency "bundler"
    s.add_runtime_dependency "autoproj", ">= 1.14.0"
    s.add_development_dependency "minitest", "~> 5.0", ">= 5.0"
end
