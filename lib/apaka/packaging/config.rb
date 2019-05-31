require 'singleton'
require 'yaml'

module Apaka
    module Packaging

        # Example yaml configuration file
        #
        #---
        ## what distributions are available
        ## type: refers to autoproj type that is searched for in the osdeps file
        ## labels: refers to autoproj labels that are searched for in the
        ## osdeps files
        #distributions:
        #    precise:
        #        type: ubuntu,debian
        #        labels: 12.04,12.04.4,lts,precise,pangolin,default
        #        ruby: ruby19
        #    trusty:
        #        type: ubuntu, debian
        #        labels: 14.04,14.04.2,lts,trusty,tahr,default
        #        ruby: ruby20
        #    vivid:
        #        type: ubuntu,debian
        #        labels: 15.04,lts,vivid,vervet,default
        #        ruby: ruby21
        #    wily:
        #        type: ubuntu,debian
        #        labels: 15.10,wily,werewolf,default
        #    xenial:
        #        type: ubuntu,debian
        #        labels: 16.04,lts,xenial,xerus,default
        #        ruby: ruby23
        #    yakkety:
        #        type: ubuntu,debian
        #        labels: 16.10,yakkety,yak,default
        #    squeeze:
        #        type: debian
        #        labels: 6.0,squeeze,default
        #    wheezy:
        #        type: debian
        #        labels: 7.8,wheezy,default
        #    jessie:
        #        type: debian
        #        labels: 8.1,jessie,default
        #        ruby: 23
        #    sid:
        #        type: debian
        #        labels: 9.0,sid,default
        ## what distribution should be build with which architecture
        #architectures:
        #    amd64: trusty,xenial
        #    #amd64: trusty,xenial,jessie
        #    #i386:  trusty,xenial,jessie
        #    #armel: jessie
        #    #armhf: jessie
        #packages:
        #    optional: llvm,clang
        #    enforce_build: rgl
        #rock_releases:
        #    master:
        #        url: http://rimres-gcs2-u/rock-releases/master-16.06
        #    transterra:
        #        url: http://rimres-gcs2-u/rock-releases/transterra-16.06
        #        depends_on: master, trusty
        #
        # The configuration can be extended/overridden via the environmental variable
        # ROCK_DEB_RELEASE_HIERARCHY using the pattern <release-name-0>:<url-0>;<release-name-1>:<url-1>;
        #     export ROCK_DEB_RELEASE_HIERARCHY="master-18.01:http://rock-releases/master-18.01;dependant-18.01:http://rock-releases/dependant-18.01;"
        #
        class Config
            include Singleton

            attr_accessor :config_file
            attr_accessor :current_release_name

            attr_reader :linux_distribution_releases
            attr_reader :preferred_ruby_version
            attr_reader :ubuntu_releases
            attr_reader :debian_releases
            attr_reader :rock_releases

            attr_reader :architectures

            attr_reader :packages_optional
            attr_accessor :packages_enforce_build


            def reload_config(file, current_release_name = nil)
                if !file
                    file = File.join(File.expand_path(File.dirname(__FILE__)), 'deb_package-default.yml')
                elsif !File.exist?(file)
                    raise ArgumentError, "Apaka::Packaging::Config.reload_config: #{file} does not exist"
                end
                configuration = YAML.load_file(file)
                @config_file = File.absolute_path(file)
                @current_release_name = current_release_name

                @linux_distribution_releases = Hash.new
                @preferred_ruby_version = Hash.new
                @rock_releases = Hash.new

                configuration["distributions"] ||= Hash.new
                configuration["architectures"] ||= Hash.new
                configuration["packages"] ||= Hash.new
                configuration["rock_releases"] ||= Hash.new

                configuration["distributions"].each do |key, values|
                    types  = values["type"].gsub(' ','').split(",")
                    labels = values["labels"].gsub(' ','').split(",")
                    if values.has_key?("ruby_version")
                        ruby_version = values["ruby_version"]
                        @preferred_ruby_version[key] = ruby_version
                    end
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
                @packages_optional = configuration["packages"]["optional"] || ""
                if @packages_optional
                    @packages_optional = @packages_optional.split(",")
                end
                @packages_enforce_build = configuration["packages"]["enforce_build"] || ""
                if @packages_enforce_build
                    @packages_enforce_build = @packages_enforce_build.split(",")
                end


                configuration["rock_releases"].each do |key, values|
                    options = Hash.new
                    options[:url] = Config::resolve_localhost( values["url"].strip )
                    if values["depends_on"]
                        options[:depends_on] = values["depends_on"].gsub(' ','').split(",")
                    else
                        options[:depends_on] = Array.new
                    end
                    @rock_releases[key] = options
                end

                update_hierarchy_from_env

                self
            end

            def initialize
                reload_config(config_file)
            end

            def self.resolve_localhost(url)
                hostname = `hostname`.strip
                url.gsub("localhost",hostname)
            end

            # Extract hierarchy from the enviroment variable ROCK_DEB_RELEASE_HIERARCHY
            def self.hierarchy_from_env
                release_hierarchy = []
                if hierarchy = ENV['ROCK_DEB_RELEASE_HIERARCHY']
                    hierarchy.scan(/([^:]*):([^;]*);/).each do |tuple|
                         release_hierarchy << tuple
                    end
                end
                release_hierarchy
            end

            def update_hierarchy_from_env
                if hierarchy = ENV['ROCK_DEB_RELEASE_HIERARCHY']
                    Packager.warn "Apaka::Packaging::Configuration::reload_config: extending release hierarchy from env: ROCK_DEB_RELEASE_HIERARCHY" \
                        "    hierarchy: #{hierarchy}"

                    release_hierarchy = []
                    Config.hierarchy_from_env.each do |h_release_name, h_release_path|
                         @rock_releases[h_release_name] ||= Hash.new
                         @rock_releases[h_release_name][:url] = h_release_path
                         @rock_releases[h_release_name][:depends_on] = release_hierarchy.dup
                         release_hierarchy << h_release_name
                    end
                    if @current_release_name
                        Packager.warn "Apaka::Packaging::Configuration::reload_config: current release #{@current_release_name} depends on #{release_hierarchy}"
                        @rock_releases[@current_release_name] = Hash.new
                        @rock_releases[@current_release_name][:depends_on] = release_hierarchy
                    end
                end
            end

            def self.config_file
                instance.config_file
            end

            def self.reload_config(file, current_release_name = nil)
                instance.reload_config(file, current_release_name)
            end

            def self.linux_distribution_releases
                instance.linux_distribution_releases
            end

            def self.preferred_ruby_version
                instance.preferred_ruby_version
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

            def self.packages_optional
                instance.packages_optional
            end

            def self.packages_enforce_build
                instance.packages_enforce_build
            end

            def self.packages_enforce_build=(value)
                instance.packages_enforce_build=value
            end

            def self.active_distributions
                linux_distribution_releases.collect do |name,ids|
                    if build_for_distribution?(name)
                        name
                    end
                end.compact
            end

            def self.active_configurations
                configurations = []
                puts "Architectures: #{architectures}"
                puts "Active distr: #{active_distributions}"
                architectures.each do |arch, releases|
                    puts "Releases: #{releases}"
                    releases.each do |release|
                        if active_distributions.include?(release)
                            configurations << [release,arch]
                        end
                    end
                end
                configurations
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

            def self.release_url(release_name)
                if instance.rock_releases.has_key?(release_name)
                    instance.rock_releases[release_name][:url]
                end
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
                s += "    optional packages:\n"
                packages_optional.each do |pkg_name|
                    s += "        #{pkg_name}\n"
                end
                s += "    enforce build packages:\n"
                packages_enforce_build.each do |pkg_name|
                    s += "        #{pkg_name}\n"
                end

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
end # Apaka

