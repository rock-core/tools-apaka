require 'singleton'
require 'yaml'

module Autoproj
    module Packaging
        class Config
            include Singleton

            attr_accessor :config_file

            attr_reader :linux_distribution_releases
            attr_reader :ubuntu_releases
            attr_reader :debian_releases
            attr_reader :rock_releases

            attr_reader :architectures

            attr_reader :packages_aliases
            attr_reader :packages_optional
            attr_reader :packages_enforce_build
            attr_reader :timestamp_format


            def reload_config(file)
                if !file
                    file = File.join(File.expand_path(File.dirname(__FILE__)), 'deb_package-default.yml')
                end
                configuration = YAML.load_file(file)
                @config_file = File.absolute_path(file)
                @linux_distribution_releases = Hash.new
                @rock_releases = Hash.new

                configuration["distributions"] ||= Hash.new
                configuration["architectures"] ||= Hash.new
                configuration["packages"] ||= Hash.new
                configuration["rock_releases"] ||= Hash.new

                configuration["distributions"].each do |key, values|
                    types  = values["type"].gsub(' ','').split(",")
                    labels = values["labels"].gsub(' ','').split(",")
                    @linux_distribution_releases[key] = [types,labels]
                end

                @ubuntu_releases = @linux_distribution_releases.select do |release, values|
                    values[0].include?("ubuntu")
                end
                @debian_releases = @linux_distribution_releases.select do |release, values|
                    types = values[0]
                    types.size == 1 && types.include?("debian")
                end

                @architectures = Hash.new
                architectures = configuration["architectures"] || Hash.new
                architectures.each do |arch,allowed_releases|
                    @architectures[arch] = allowed_releases.gsub(' ','').split(",")
                end
                @packages_aliases = configuration["packages"]["aliases"] || Hash.new
                @packages_optional = configuration["packages"]["optional"] || ""
                if @packages_optional
                    @packages_optional = @packages_optional.split(",")
                end
                @packages_enforce_build = configuration["packages"]["enforce_build"] || ""
                if @packages_enforce_build
                    @packages_enforce_build = @packages_enforce_build.split(",")
                end
                @timestamp_format = configuration["packages"]["timestamp_format"] || '%Y-%m-%d'


                configuration["rock_releases"].each do |key, values|
                    options = Hash.new
                    options[:url] = values["url"].strip
                    if values["depends_on"]
                        options[:depends_on] = values["depends_on"].gsub(' ','').split(",")
                    else
                        options[:depends_on] = Array.new
                    end
                    @rock_releases[key] = options
                end
            end

            def initialize
                reload_config(config_file)
            end

            def self.config_file
                instance.config_file
            end

            def self.reload_config(file)
                instance.reload_config(file)
            end

            def self.linux_distribution_releases
                instance.linux_distribution_releases
            end

            def self.ubuntu_releases
                instance.ubuntu_releases
            end

            def self.debian_releases
                instance.debian_releases
            end

            def self.architectures
                instance.architectures
            end

            def self.packages_aliases
                instance.packages_aliases
            end

            def self.packages_optional
                instance.packages_optional
            end

            def self.packages_enforce_build
                instance.packages_enforce_build
            end

            def self.timestamp_format
                instance.timestamp_format
            end

            def self.active_distributions
                linux_distribution_releases.collect do |name,ids|
                    if build_for_distribution?(name)
                        name
                    end
                end.compact
            end

            def self.build_for_distribution?(distribution_name)
                architectures.each do |arch, allowed_distributions|
                    if allowed_distributions.include?(distribution_name)
                        return true
                    end
                end
                return false
            end

            def self.rock_releases
                instance.rock_releases
            end


            def self.to_s
                s = "packager configuration file: #{config_file}\n"
                s += "linux distribution releases:\n"
                linux_distribution_releases.each do |key, values|
                    label = key + ":"
                    s += "    #{label.ljust(10,' ')}#{values}\n"
                end
                s += "\narchitectures:\n"
                architectures.each do |arch, distributions|
                    label = arch + ":"
                    s += "    #{label.ljust(10,' ')}#{distributions}\n"
                end
                s += "active linux distribution releases: #{active_distributions}\n"
                s+= "packages:\n"
                s += "    aliases:\n"
                packages_aliases.each do |pkg_name, a|
                    s += "        #{pkg_name} --> #{a}\n"
                end
                s += "    optional packages:\n"
                packages_optional.each do |pkg_name|
                    s += "        #{pkg_name}\n"
                end
                s += "    enforce build  packages:\n"
                packages_enforce_build.each do |pkg_name|
                    s += "        #{pkg_name}\n"
                end
                s += "    timestamp format: #{timestamp_format}\n"

                s += "rock releases:\n"
                rock_releases.each do |key, values|
                    labels = key + ":"
                    s += "    #{labels.ljust(10,' ')}\n"
                    values.each do |option, value|
                        s += "        #{option.to_s.ljust(15,' ')}#{value}\n"
                    end
                end
                s
            end
        end # end Config
    end # Packaging
end # Autoproj


