require 'rock/packaging/packager'

module Autoproj
    module Packaging
        class TargetPlatform
            attr_reader :distribution_release_name
            attr_reader :architecture

            # Initialize the target platform
            def initialize(distribution_release_name, architecture)
                if distribution_release_name
                    @distribution_release_name = distribution_release_name.downcase
                else
                    @distribution_release_name = nil
                end
                @architecture = architecture || "amd64"
            end

            def ==(other)
                if other.kind_of?(TargetPlatform)
                    return distribution_release_name == other.distribution_release_name &&
                        architecture == other.architecture
                end
                false
            end

            def eql?(other)
                self == other
            end

            def hash
                [ distribution_release_name, architecture ].hash
            end

            def to_s
                "#{distribution_release_name}/#{architecture}"
            end

            # Autodetect the currently active architecture using 'dpkg'
            def self.autodetect_dpkg_architecture
                "#{`dpkg --print-architecture`}".strip
            end

            # Autodetect the target platform (distribution release and architecture)
            def self.autodetect_target_platform
                TargetPlatform.new(autodetect_linux_distribution_release, 
                                   autodetect_dpkg_architecture)
            end

            def self.osdeps_release_tags
                @osdeps_release_tags
            end

            def self.osdeps_release_tags= (tags)
                @osdeps_release_tags = tags
            end
            
            # Autodetect the linux distribution release
            # require the general allow identification tag to be present in the
            # configuration file
            def self.autodetect_linux_distribution_release
                release = nil
                osdeps_release_tags.each do |tag|
                    if Config.linux_distribution_releases.include?(tag)
                        return tag
                    end
                end
                raise RuntimeError, "#{self} Failed to autodetect linux distribution release"
            end

            # Check if the given name refers to an existing
            # Ubuntu release
            # New releases have to be added to the default configuration
            def self.isUbuntu(release_name)
                release_name = release_name.downcase
                if Packaging::Config.ubuntu_releases.keys.include?(release_name)
                    return true
                end
                false
            end

            # Check if the given name refers to an existing
            # Debian release
            # New releases have to be added to the default configuration
            def self.isDebian(release_name)
                release_name = release_name.downcase
                if Packaging::Config.debian_releases.keys.include?(release_name)
                    return true
                end
                false
            end

            def self.isRock(release_name)
                release_name = release_name.downcase
                if Packaging::Config.rock_releases.keys.include?(release_name)
                    return true
                end
                false
            end

            def ancestors
                TargetPlatform::ancestors(distribution_release_name)
            end

            def self.ancestors(release_name)
                if TargetPlatform::isRock(release_name)
                    ancestors_list = Array.new
                    Packaging::Config.rock_releases[release_name][:depends_on].each do |ancestor_release|
                        ancestors_list << ancestor_release
                    end
                    all_ancestors = ancestors_list
                    ancestors_list.each do |p|
                        all_ancestors = all_ancestors + ancestors(p)
                    end
                    all_ancestors.uniq
                else
                    []
                end
            end

            # For Rock release this allow to check whether a ancestor given by the 
            # depends_on option for a release already contains the package
            # package Autobuild::Package
            def ancestorContains(package_name, cache_results = true)
                !releasedInAncestor(package_name, cache_results).empty?
            end

            def releasedInAncestor(package_name, cache_results = true)
                TargetPlatform.ancestors(distribution_release_name).each do |ancestor_release_name|
                    pkg_name = package_name.gsub(distribution_release_name, ancestor_release_name)
                    platform = TargetPlatform.new(ancestor_release_name, architecture)
                    if platform.contains(pkg_name)
                        return ancestor_release_name
                    else
                        Autoproj::Packaging::info "#{self} ancestor #{platform} does not contain #{pkg_name}"
                    end
                end
                return ""
            end

            def packageReleaseName(package_name, cache_results = true)
                ancestor_release_name = releasedInAncestor(package_name, cache_results)
                if ancestor_release_name.empty?
                    return package_name
                end
                return package_name.gsub(distribution_release_name, ancestor_release_name)
            end

            def cacheFilename(package, release_name, architecture)
                File.join(Autoproj::Packaging.cache_dir,"deb_package-availability-#{package}-in-#{release_name}-#{architecture}")
            end

            # Use dcontrol in order to check if the debian distribution contains
            # a given package for this architecture
            def debianContains(package, cache_results = true)
                if ["armhf"].include?(architecture)
                    raise RuntimeError, "TargetPlatfrom::debianContains: dcontrol does not support architecture: #{architecture}"
                end
                if !system("which" "dcontrol", [ :out, :err]  => "/dev/null", :close_others => true)
                    raise RuntimeError, "TargetPlatform::debianContains: requires 'devscripts' to be installed for dcontrol"
                end

                if !File.exist?(Autoproj::Packaging.cache_dir)
                    FileUtils.mkdir_p Autoproj::Packaging.cache_dir
                end
                outfile = cacheFilename(package, distribution_release_name, architecture)
                if !File.exists?(outfile)
                    cmd = ["dcontrol"]
                    cmd << "#{package}@#{architecture}/#{distribution_release_name}"
                    Autoproj::Packaging.info "TargetPlatform::debianContains: #{cmd.join(" ")} &> #{outfile}"
                    if !system(*cmd, [:out, :err] => outfile, :close_others => true)
                        return false
                    end
                end

                if system("grep", "-i", "^Version:", :in => outfile, [:out, :err] => "/dev/null", :close_others => true)
                    return true
                end
                return false
            end

            # Check if the given release contains
            # a package of the given name
            #
            # This method relies on the launchpad website for Ubuntu packages
            # and the packages.debian.org/source website for Debian packages
            def contains(package, cache_results = true)
                # handle corner cases, e.g. rgl
                if Packaging::Config.packages_enforce_build.include?(package)
                    Autoproj::Packaging.info "Distribution::contains returns false -- since configuration set to forced manual build #{package}"
                    return false
                end
                release_name = distribution_release_name
                urls = Array.new
                ubuntu="https://launchpad.net/ubuntu/"
                debian="https://packages.debian.org/"
                if TargetPlatform::isUbuntu(release_name)
                    urls << File.join(ubuntu,release_name,architecture,package)
                    # Retrieve the latest status and check on "superseeded or deleted" vs. "published"
                elsif TargetPlatform::isDebian(release_name)
                    begin
                        return debianContains(package, true)
                    rescue Exception => e
                        Autoproj::Packaging.warn "#{e} -- falling back to http query-based package verification"
                        urls << File.join(debian,release_name,architecture,package,"download")
                    end
                elsif TargetPlatform::isRock(release_name)
                    urls << File.join(Packaging::Config.rock_releases[release_name][:url],"pool","main","r",package)
                else
                    raise ArgumentError, "Unknown distribution #{release_name}"
                end

                outfile = nil
                errorfile = nil
                result = true

                if !File.exist?(Autoproj::Packaging.cache_dir)
                    FileUtils.mkdir_p Autoproj::Packaging.cache_dir
                end

                urls.each do |url|
                    puts "URL: #{url}"
                    result = false
                    # Store files in cache directory -- to better control
                    # persistance
                    outfile = cacheFilename(package, distribution_release_name, architecture)
                    errorfile="#{outfile}.error"
                    if cache_results && (File.exists?(outfile) || File.exists?(errorfile))
                        # query already done sometime before
                    else
                        cmd = ["wget"]
                        cmd << "-O" << outfile << "-o" << errorfile << url
                        Autoproj::Packaging.info "TargetPlatform::contains: query with #{cmd.join(" ")}"
                        system(*cmd, :close_others => true)
                    end

                    if TargetPlatform::isUbuntu(release_name)
                        # -A1 -> 1 line after the match
                        # -m1 -> first match: we assume that the first date refers to the latest entry
                        # grep 'published': only published will be available otherwise there might be deleted,superseded
                        if system("grep -i -A1 -m1 -e '[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}' #{outfile} | grep -i 'published' > /dev/null 2>&1", :close_others => true)
                            result = true
                        end
                    elsif TargetPlatform::isDebian(release_name)
                        # If file contains a response, then check for
                        # 'No such package'
                        if !system("grep", "-i", "No such package", :in => outfile, [:out, :err] => "/dev/null", :close_others => true) && system("grep", "-i", "[a-zA-z]", :in => outfile, [:out, :err] => "/dev/null", :close_others => true)
                            result = true
                        end
                    elsif TargetPlatform::isRock(release_name)
                        if !system("grep", "-i", " 404", :in => errorfile, [:out, :err] => "/dev/null", :close_others => true)
                            result = true
                        end
                    end
                    if result
                        break
                    end
                end


                # Leave files as cache
                [outfile, errorfile].each do |file|
                    if file && File.exists?(file)
                        if !cache_results
                            FileUtils.rm(file)
                        else
                            begin
                                # allow all users to read and write file
                                FileUtils.chmod 0666, file
                            rescue
                                Autoproj::Packaging.info "TargetPlatform::contains could not change permissions for #{file}"
                            end
                        end
                    end
                end

                if result
                    Autoproj::Packaging.info "TargetPlatform #{to_s} contains #{package}"
                else
                    Autoproj::Packaging.info "TargetPlatform #{to_s} does not contain #{package}"
                end
                result
            end
        end # TargetPlatform
    end # Packaging
end # Autoproj

