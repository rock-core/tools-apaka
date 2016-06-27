require 'find'
require 'autoproj'
require 'autobuild'
require 'tmpdir'
require 'utilrb'
require 'timeout'
require 'set'
require 'yaml'
require 'singleton'
require 'rubygems/requirement'

module Autoproj
    module Packaging
        # Directory for temporary data to
        # validate obs_packages
        BUILD_DIR=File.join(Autoproj.root_dir, "build/rock-packager")
        LOG_DIR=File.join(BUILD_DIR, "logs")
        LOCAL_TMP = File.join(BUILD_DIR,".rock_packager")

        class Config
            include Singleton

            attr_accessor :config_file

            attr_reader :linux_distribution_releases
            attr_reader :ubuntu_releases
            attr_reader :debian_releases

            attr_reader :architectures

            attr_reader :packages_aliases
            attr_reader :packages_optional
            attr_reader :packages_enforce_build
            attr_reader :timestamp_format

            def reload_config(file)
                configuration = YAML.load_file(file)
                @config_file = File.absolute_path(file)
                @linux_distribution_releases = Hash.new

                configuration["distributions"] ||= Hash.new
                configuration["architectures"] ||= Hash.new
                configuration["packages"] ||= Hash.new

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
            end

            def initialize
                config_file = File.join(File.expand_path(File.dirname(__FILE__)), 'deb_package-default.yml')
                reload_config(config_file)
            end

            def self.config_file
                instance.config_file
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
                s += "    timestamp format: #{timestamp_format}"
                s
            end
        end # end Config

        class TargetPlatform
            attr_reader :distribution_release_name
            attr_reader :architecture

            def initialize(distribution_release_name, architecture)
                if distribution_release_name
                    @distribution_release_name = distribution_release_name.downcase
                else
                    @distribution_release_name = nil
                end
                @architecture = architecture || "amd64"
            end

            def to_s
                "#{distribution_release_name}/#{architecture}"
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

            # Check if the given release contains
            # a package of the given name
            #
            # This method relies on the launchpad website for Ubuntu packages
            # and the packages.debian.org/source website for Debian packages
            def contains(package, cache_results = true)
                # handle corner cases, e.g. rgl
                if Packaging::Config.packages_enforce_build.include?(package)
                    Packager.info "Distribution::contains returns false -- since configuration set to forced manual build #{package}"
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
                    urls << File.join(debian,release_name,architecture,package,"download")
                else
                    raise ArgumentError, "Unknown distribution #{release_name}"
                end

                outfile = nil
                errorfile = nil
                result = true

                urls.each do |url|
                    puts "URL: #{url}"
                    result = false
                    outfile="/tmp/deb_package-availability-#{package}-in-#{release_name}-#{architecture}"
                    errorfile="#{outfile}.error"
                    if cache_results && (File.exists?(outfile) || File.exists?(errorfile))
                        # query already done sometime before
                    else
                        cmd = "wget -O #{outfile} -o #{errorfile} #{url}"
                        Packager.info "TargetPlatform::contains: query with #{cmd}"
                        system(cmd)
                    end

                    if TargetPlatform::isUbuntu(release_name)
                        # -A1 -> 1 line after the match
                        # -m1 -> first match: we assume that the first date refers to the latest entry
                        # grep 'published': only published will be available otherwise there might be deleted,superseded
                        if system("grep -ir -A1 -m1 -e '[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}' #{outfile} | grep -i 'published' > /dev/null 2>&1")
                            result = true
                        end
                    elsif TargetPlatform::isDebian(release_name)
                        if !system("grep -ir \"No such package\" #{outfile} > /dev/null 2>&1")
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
                                Packager.info "TargetPlatform::contains could not change permissions for #{file}"
                            end
                        end
                    end
                end

                if result
                    Packager.info "TargetPlatform #{to_s} contains #{package}"
                else
                    Packager.info "TargetPlatform #{to_s} does not contain #{package}"
                end
                result
            end
        end

        class GemDependencies
            # Resolve the dependency of a gem using # `gem dependency #{gem_name}`
            # This will only work if the local installation is update to date
            # regarding the gems
            # return [:deps => , :version =>  ]
            def self.resolve_by_name(gem_name, version = nil, runtime_deps_only = true)
                if not gem_name.kind_of?(String)
                    raise ArgumentError, "GemDependencies::resolve_by_name expects string, but got #{gem_name.class} '#{gem_name}'"
                end
                version_requirements = Array.new
                if version
                    if version.kind_of?(Set)
                        version_requirements = version.to_a.compact
                    elsif version.kind_of?(String)
                        version_requirements = version.gsub(' ','').split(',')
                    else
                        version_requirements = version
                    end
                end
                gem_dependency_cmd = "gem dependency #{gem_name}"
                gem_dependency = `#{gem_dependency_cmd}`

                if $?.exitstatus != 0
                    raise ArgumentError, "Failed to resolve #{gem_name} via #{gem_dependency_cmd} -- pls install locally"
                end

                # Output of gem dependency is not providing more information
                # than for the specific gem found
                regexp = /(.*)\s\((.*)\)/
                found_gem = false
                current_version = nil
                versioned_gems = Array.new
                dependencies = Hash.new
                gem_dependency.split("\n").each do |line|
                    if match = /Gem #{gem_name}-([0-9].*)/.match(line)
                        # add after completion of the parsing
                        if current_version
                            versioned_gems << {:version => current_version, :deps => dependencies}
                            # Reset dependencies
                            dependencies = Hash.new
                            current_version = nil
                        end
                        current_version = match[1].strip
                        next
                    elsif match = /Gem/.match(line) # other package names
                        # We assume here that the first GEM entry found is related to the
                        # one we want, discarding the others
                        break
                    end

                    mg = regexp.match(line)
                    if mg
                        dep_gem_name = mg[1].strip
                        dep_gem_version = mg[2].strip
                        # Separate runtime dependencies from development dependencies
                        # Typically we are interested only in the runtime dependencies
                        # for the use case here (that why runtime_deps_only is true as default)
                        if runtime_deps_only && /development/.match(dep_gem_version)
                            next
                        end
                        # There can be multiple version requirement for a dependency,
                        # so we store them as an array
                        dependencies[dep_gem_name] = dep_gem_version.gsub(' ','').split(',')
                    end
                end
                # Finalize by adding the last one found (if there has been one)
                if current_version
                    versioned_gems << { :version => current_version, :deps => dependencies }
                end

                # pick last, i.e. highest version
                requirements = Array.new
                version_requirements.each do |requirement|
                    requirements << Gem::Version::Requirement.new(requirement)
                end
                versioned_gems = versioned_gems.select do |description|
                    do_select = true
                    requirements.each do |required_version|
                        available_version = Gem::Version.new(description[:version])
                        if !required_version.satisfied_by?(available_version)
                            do_select = false
                        end
                    end
                    do_select
                end
                if versioned_gems.empty?
                    raise RuntimeError, "GemDependencies::resolve_by_name failed to find a (locally installed) gem that satisfies the version requirements: #{version_requirements}"
                else
                    versioned_gems.last
                end
            end

            # Resolve all dependencies of a list of name or |name,version| tuples of gems
            # Returns[Hash] with keys as required gems and versioned dependencies
            # as values (a Ruby Set)
            def self.resolve_all(gems)
                Autoproj.info "Resolve all: #{gems}"

                dependencies = Hash.new
                handled_gems = Set.new

                if gems.kind_of?(String)
                    gems = [gems]
                end

                remaining_gems = Hash.new
                if gems.kind_of?(Array)
                    gems.collect do |value|
                        # only the gem name is given
                        if value.kind_of?(String)
                            name = value
                            version = nil
                        else
                            name, version = value
                        end

                        remaining_gems[name] ||= Array.new
                        remaining_gems[name] << version
                    end
                elsif gems.kind_of?(Hash)
                    remaining_gems = gems
                end

                Autoproj.info "Resolve remaining: #{remaining_gems}"

                while !remaining_gems.empty?
                    Autoproj.info "Resolve all: #{remaining_gems.to_a}"
                    remaining = Hash.new
                    remaining_gems.each do |gem_name, gem_versions|
                        deps = resolve_by_name(gem_name, gem_versions)[:deps]
                        handled_gems << gem_name

                        dependencies[gem_name] = Hash.new
                        deps.each do |gem_dep_name, gem_dep_version|
                            dependencies[gem_name][gem_dep_name] ||= Array.new
                            dependencies[gem_name][gem_dep_name] += gem_dep_version

                            if !handled_gems.include?(gem_dep_name)
                                remaining[gem_dep_name] ||= Array.new
                                remaining[gem_dep_name] += gem_dep_version
                            end
                        end
                    end
                    remaining_gems.select! { |g| !handled_gems.include?(g) }
                    remaining.each do |name, versions|
                        remaining_gems[name] ||= Array.new
                        remaining_gems[name] = (remaining_gems[name] + versions).uniq
                    end
                end
                dependencies
            end

            # Sort gems based on their interdependencies
            # Dependencies is a hash where the key is the gem and
            # the value is the set of versioned dependencies
            def self.sort_by_dependency(dependencies = Hash.new)
                ordered_gem_list = Array.new
                while true
                    if dependencies.empty?
                        break
                    end

                    handled_packages = Array.new

                    # Take all gems which are either standalone, or
                    # whose dependencies have already been processed
                    dependencies.each do |gem_name, gem_dependencies|
                        if gem_dependencies.empty?
                            handled_packages << gem_name
                            ordered_gem_list << gem_name
                        end
                    end

                    # Remove handled packages from the list of dependencies
                    handled_packages.each do |gem_name|
                        dependencies.delete(gem_name)
                    end

                    # Remove the handled packages from the dependency lists
                    # of all other packages
                    dependencies_refreshed = Hash.new
                    dependencies.each do |gem_name, gem_dependencies|
                        gem_dependencies.reject! { |x, version| handled_packages.include? x }
                        dependencies_refreshed[gem_name] = gem_dependencies
                    end
                    dependencies = dependencies_refreshed

                    if handled_packages.empty? && !dependencies.empty?
                        raise ArgumentError, "Unhandled dependencies of gem: #{dependencies}"
                    end
                end
                ordered_gem_list
            end

            # Sorted list of dependencies
            def self.sorted_gem_list(gems)
                dependencies = resolve_all(gems)
                sort_by_dependency(dependencies)
            end

            def self.gem_exact_versions(gems)
                gem_exact_version = Hash.new
                gems.each do |gem_name, version_requirements|
                    gem_exact_version[gem_name] = resolve_by_name(gem_name, version_requirements)[:version]
                end
                gem_exact_version
            end

            # Check is the given name refers to an existing gem
            # uses 'gem fetch' for testing
            def self.isGem(gem_name)
                if gem_name =~ /\//
                    Autoproj.info "GemDependencies: invalid name -- cannot be a gem"
                    return false
                end
                # Check if this is a gem or not
                Dir.chdir("/tmp") do
                    outfile = "/tmp/gem-fetch-#{gem_name}"
                    if not File.exists?(outfile)
                        if !system("gem fetch #{gem_name} > #{outfile}")
                            return false
                        end
                    end
                    if !system("grep -ir ERROR #{outfile} > /dev/null 2>&1")
                        Autoproj.info "GemDependencies: #{gem_name} is a ruby gem"
                        return true
                    end
                end
                return false
            end
        end

        class Packager
            extend Logger::Root("Packager", Logger::INFO)

            attr_accessor :build_dir
            attr_accessor :log_dir
            attr_accessor :local_tmp_dir

            def initialize
                @build_dir = BUILD_DIR
                @log_dir = LOG_DIR
                @local_tmp_dir = LOCAL_TMP
            end

            # Check that the list of distributions contains at maximum one entry
            # raises ArgumentError if that number is exceeded
            def max_one_distribution(distributions)
                distribution = nil
                if !distributions.kind_of?(Array)
                    raise ArgumentError, "max_one_distribution: expecting Array as argument, but got: #{distributions}"
                end

                if distributions.size > 1
                    raise ArgumentError, "Unsupported requests. You provided more than one distribution where maximum one 1 allowed"
                elsif distributions.empty?
                    Packager.warn "You provided no distribution for debian package generation."
                else
                    distribution = distributions.first
                end
                distribution
            end

            def prepare_source_dir(pkg, options = Hash.new)
                options, unknown_options = Kernel.filter_options options,
                    :existing_source_dir => nil

                Packager.debug "Preparing source dir #{pkg.name}"
                if existing_source_dir = options[:existing_source_dir]
                    Packager.debug "Preparing source dir #{pkg.name} from existing: '#{existing_source_dir}'"
                    pkg_dir = File.join(@build_dir, debian_name(pkg))
                    if not File.directory?(pkg_dir)
                        FileUtils.mkdir_p pkg_dir
                    end

                    target_dir = File.join(pkg_dir, dir_name(pkg, target_platform.distribution_release_name))
                    FileUtils.cp_r existing_source_dir, target_dir

                    pkg.srcdir = target_dir
                else
                    Autoproj.manifest.load_package_manifest(pkg.name)

                    # Test whether there is a local
                    # version of the package to use.
                    # Only for Git-based repositories
                    # If it is not available import package
                    # from the original source
                    if pkg.importer.kind_of?(Autobuild::Git)
                        if not File.exists?(pkg.srcdir)
                            Packager.debug "Retrieving remote git repository of '#{pkg.name}'"
                            pkg.importer.import(pkg)
                        else
                            Packager.debug "Using locally available git repository of '#{pkg.name}'"
                        end
                        pkg.importer.repository = pkg.srcdir
                    end

                    pkg.srcdir = File.join(@build_dir, debian_name(pkg), plain_dir_name(pkg, target_platform.distribution_release_name))
                    begin
                        Packager.debug "Importing repository to #{pkg.srcdir}"
                        pkg.importer.import(pkg)
                    rescue Exception => e
                        if not e.message =~ /failed in patch phase/
                            raise
                        else
                            Packager.warn "Patching #{pkg.name} failed"
                        end
                    end

                    Dir.glob(File.join(pkg.srcdir, "*-stamp")) do |file|
                        FileUtils.rm_f file
                    end
                end
            end

            def self.obs_package_name(pkg)
                "rock-" + pkg.name.gsub(/[\/_]/, '-').downcase
            end
        end

        class OBS

            @@obs_cmd = "osc"

            def self.obs_cmd
                @@obs_cmd
            end

            # Update the open build local checkout
            # using a given checkout directory and the pkg name
            # use a specific file pattern to set allowed files
            # source directory
            # obs_dir target obs checkout directory
            # src_dir where the source dir is
            # pkg_name
            # allowed file patterns
            def self.update_dir(obs_dir, src_dir, pkg_obs_name, file_suffix_patterns = ".*", commit = true)
                pkg_obs_dir = File.join(obs_dir, pkg_obs_name)
                if !File.directory?(pkg_obs_dir)
                    FileUtils.mkdir_p pkg_obs_dir
                    system("#{obs_cmd} add #{pkg_obs_dir}")
                end

                # sync the directory in build/obs and the target directory based on an existing
                # files pattern
                files = []
                file_suffix_patterns.map do |p|
                    # Finding files that exist in the source directory
                    # needs to handle ruby-hoe_0.20130113/*.dsc vs. ruby-hoe-yard_0.20130113/*.dsc
                    # and ruby-hoe/_service
                    glob_exp = File.join(src_dir,pkg_obs_name,"*#{p}")
                    files += Dir.glob(glob_exp)
                end
                files = files.flatten.uniq
                Packager.debug "update directory: files in src #{files}"

                # prepare pattern for target directory
                expected_files = files.map do |f|
                    File.join(pkg_obs_dir, File.basename(f))
                end
                Packager.debug "target directory: expected files: #{expected_files}"

                existing_files = Dir.glob(File.join(pkg_obs_dir,"*"))
                Packager.debug "target directory: existing files: #{existing_files}"

                existing_files.each do |existing_path|
                    if not expected_files.include?(existing_path)
                        Packager.warn "OBS: deleting #{existing_path} -- not present in the current packaging"
                        FileUtils.rm_f existing_path
                        system("#{obs_cmd} rm #{existing_path}")
                    end
                end

                # Add the new unchanged files
                files.each do |path|
                    target_file = File.join(pkg_obs_dir, File.basename(path))
                    exists = File.exists?(target_file)
                    if exists
                        if File.read(path) == File.read(target_file)
                            Packager.info "OBS: #{target_file} is unchanged, skipping"
                        else
                            Packager.info "OBS: #{target_file} updated"
                            FileUtils.cp path, target_file
                        end
                    else
                        FileUtils.cp path, target_file
                        system("#{obs_cmd} add #{target_file}")
                    end
                end

                if commit
                    Packager.info "OBS: committing #{pkg_obs_dir}"
                    system("#{obs_cmd} ci #{pkg_obs_dir} -m \"autopackaged using autoproj-packaging tools\"")
                else
                    Packager.info "OBS: not commiting #{pkg_obs_dir}"
                end
            end

            # List the existing package in the projects
            # The list will contain only the name, suffix '.deb' has
            # been removed
            def self.list_packages(project, repository, architecture = "i586")
                result = %x[#{obs_cmd} ls -b -r #{repository} -a #{architecture} #{project}].split("\n")
                pkg_list = result.collect { |pkg| pkg.sub(/(_.*)?.deb/,"") }
                pkg_list
            end

            def self.resolve_dependencies(package_name)
                record = `apt-cache depends #{package_name}`.split("\n").map(&:strip)
                if $?.exitstatus != 0
                    raise
                end

                depends_on = []
                record.each do |line|
                    if line =~ /^\s*Depends:\s*[<]?([^>]*)[>]?/
                        depends_on << $1.strip
                    end
                end

                depends_on
            end
        end

        # Packaging details:
        # - one main temporary folder in use: <autoproj-root>/build/obs/
        # - in the temp folder we create one folder per package to handle the packaging
        #   this folder can be synced with the target folder of the local checkout of the OBS
        # - checking update currently on checks for changes on the source data (so if patches change it
        #   is not recognized)
        # - to facilitate patching etc. an 'overlay' directory is used which is just copied during the
        #   build process -- currently only for gem handling and injecting fixes
        #
        # Resources:
        # * http://www.debian.org/doc/manuals/maint-guide/dreq.en.html
        # * http://cdbs-doc.duckcorp.org/en/cdbs-doc.xhtml
        class Debian < Packager
            TEMPLATES = File.expand_path(File.join("templates", "debian"), File.dirname(__FILE__))

            # Package like tools/rtt etc. require a custom naming schema, i.e. the base name rtt should be used for tools/rtt
            attr_reader :package_aliases

            attr_reader :existing_debian_directories

            # List of gems, which need to be converted to debian packages
            attr_accessor :ruby_gems

            # List of rock gems, ruby_packages that have been converted to debian packages
            attr_accessor :ruby_rock_gems

            # List of osdeps, which are needed by the set of packages
            attr_accessor :osdeps

            # install directory if not given set to /opt/rock
            attr_accessor :rock_base_install_directory
            attr_accessor :rock_release_name

            # List of alternative rake target names to clean a gem
            attr_accessor :gem_clean_alternatives
            # List of alternative rake target names to create a gem
            attr_accessor :gem_creation_alternatives

            attr_reader :target_platform

            def initialize(existing_debian_directories, options = Hash.new)
                super()

                options, unknown_options = Kernel.filter_options options,
                    :distribution => nil,
                    :architecture => nil

                @existing_debian_directories = existing_debian_directories
                @ruby_gems = Array.new
                @ruby_rock_gems = Array.new
                @osdeps = Array.new
                @package_aliases = Hash.new
                @debian_version = Hash.new
                @rock_base_install_directory = "/opt/rock"
                @rock_release_name = Time.now.strftime("%Y%m%d")

                # Rake targets that will be used to clean and create
                # gems
                @gem_clean_alternatives = ['clean','dist:clean','clobber']
                @gem_creation_alternatives = ['gem','dist:gem','build']
                @target_platform = TargetPlatform.new(options[:distribution], options[:architecture])

                if not File.exists?(local_tmp_dir)
                    FileUtils.mkdir_p local_tmp_dir
                end

                if not File.exists?(log_dir)
                    FileUtils.mkdir_p log_dir
                end
            end

            # Canonize that name -- downcase and replace _ with -
            def canonize(name)
                name.gsub(/[\/_]/, '-').downcase
            end

            # Extract the base name from a path description
            # e.g. tools/metaruby => metaruby
            def basename(name)
                if name =~ /.*\/(.*)/
                    name = $1
                end
                name
            end

            # Add a package alias, e.g. for rtt --> tools/rtt
            def add_package_alias(pkg_name, pkg_alias)
                @package_aliases[pkg_name] = pkg_alias
            end

            # The debian name of a package -- either
            # rock[-<release-name>]-<canonized-package-name>
            # or for ruby packages
            # ruby[-<release-name>]-<canonized-package-name>
            # and the release-name can be avoided by setting
            # with_rock_release_prefix to false
            #
            def debian_name(pkg, with_rock_release_prefix = true)
                if pkg.kind_of?(String)
                    raise ArgumentError, "method debian_name expects a autobuild pkg as argument, got: #{pkg.class} '#{pkg}'"
                end
                name = pkg.name

                if @package_aliases.has_key?(name)
                    name = @package_aliases[name]
                end

                if pkg.kind_of?(Autobuild::Ruby)
                    debian_ruby_name(name, with_rock_release_prefix)
                else
                    if with_rock_release_prefix
                        rock_release_prefix + canonize(name)
                    else
                        "rock-" + canonize(name)
                    end
                end
            end

            # Get the current rock-release-based prefix for rock packages
            def rock_release_prefix
                "rock-#{rock_release_name}-"
            end

            # Get the current rock-release-based prefix for rock-(ruby) packages
            def rock_ruby_release_prefix
                rock_release_prefix + "ruby-"
            end

            def debian_ruby_name(name, with_rock_release_prefix = true)
                if with_rock_release_prefix
                    rock_ruby_release_prefix + canonize(name)
                else
                    "ruby-" + canonize(name)
                end
            end

            def debian_version(pkg, distribution, revision = "1")
#                if !@debian_version.has_key?(pkg.name)
                    #@debian_version[pkg.name] = (pkg.description.version || "0") + "." + Time.now.strftime("%Y%m%d%H%M") + "-" + revision
		    if pkg.description.nil?
                       v = "0"
		    else
                    	if !pkg.description.version
                           v = "0"
                        else
                           v = pkg.description.version
                        end
                    end 
                    @debian_version[pkg.name] = v + "." + Time.now.strftime("%Y%m%d") + "-" + revision
                    if distribution
                        @debian_version[pkg.name] += '~' + distribution
                    end
 #               end
                @debian_version[pkg.name]
            end

            # Plain version is the version string without the revision
            def debian_plain_version(pkg, distribution)
                if !@debian_version.has_key?(pkg.name)
                    # initialize version string
                    debian_version(pkg, distribution)
                end

                # remove the revision and the distribution
                # to get the plain version
                @debian_version[pkg.name].gsub(/[-~].*/,"")
            end

            def versioned_name(pkg, distribution)
                debian_name(pkg) + "_" + debian_version(pkg, distribution)
            end

            def plain_versioned_name(pkg, distribution)
                debian_name(pkg) + "_" + debian_plain_version(pkg, distribution)
            end

            def dir_name(pkg, distribution)
                versioned_name(pkg, distribution)
            end

            def plain_dir_name(pkg, distribution)
                plain_versioned_name(pkg, distribution)
            end

            def packaging_dir(pkg)
                File.join(@build_dir, debian_name(pkg))
            end

            def rock_install_directory
                File.join(rock_base_install_directory, rock_release_name)
            end

            def create_control_jobs(force)
                templates = Dir.glob "#{TEMPLATES}/../0_*.xml"
                templates.each do |template|
                    template = File.basename template, ".xml"
                    create_control_job template, force
                end
            end

            def create_control_job(name, force)
                if force
                    system("java -jar ~/jenkins-cli.jar -s http://localhost:8080/ update-job '#{name}' < #{TEMPLATES}/../#{name}.xml")
                else
                    system("java -jar ~/jenkins-cli.jar -s http://localhost:8080/ create-job '#{name}' < #{TEMPLATES}/../#{name}.xml")
                end

            end

            # Compute all required packages from a given selection
            # including the dependencies
            #
            # The order of the resulting package list is sorted
            # accounting for interdependencies among packages
            def all_required_rock_packages(selection)
                Packager.info ("#{selection.size} packages selected")
                Packager.debug "Selection: #{selection}}"
                orig_selection = selection.clone
                reverse_dependencies = Hash.new

                all_packages = Set.new
                all_packages.merge(selection)
                while true
                    all_packages_refresh = all_packages.dup
                    all_packages.each do |pkg_name|
                        if @package_aliases.has_key?(pkg_name)
                            pkg_name = @package_aliases[pkg_name]
                        end

                        #pkg = Autoproj.manifest.package(pkg_name).autobuild
                        pkg_manifest = Autoproj.manifest.load_package_manifest(pkg_name)
                        pkg = pkg_manifest.package

                        pkg.resolve_optional_dependencies
                        reverse_dependencies[pkg.name] = pkg.dependencies
                        Packager.info "deps: #{pkg.name} --> #{pkg.dependencies}"
                        all_packages_refresh.merge(pkg.dependencies)
                    end

                    if all_packages.size == all_packages_refresh.size
                        # nothing changed, so converged
                        break
                    else
                        all_packages = all_packages_refresh
                    end
                end
                Packager.info "all packages: #{all_packages.to_a}"
                Packager.info "reverse deps: #{reverse_dependencies}"

                all_required_packages = Array.new
                while true
                    if reverse_dependencies.empty?
                        break
                    end

                    handled_packages = Array.new
                    reverse_dependencies.each do |pkg_name,dependencies|
                        if dependencies.empty?
                            handled_packages << pkg_name
                            pkg = Autoproj.manifest.package(pkg_name).autobuild
                            all_required_packages << pkg
                        end
                    end

                    handled_packages.each do |pkg|
                        reverse_dependencies.delete(pkg)
                    end

                    reverse_dependencies_refreshed = Hash.new
                    reverse_dependencies.each do |pkg,dependencies|
                        dependencies.reject! { |x| handled_packages.include? x }
                        reverse_dependencies_refreshed[pkg] = dependencies
                    end
                    reverse_dependencies = reverse_dependencies_refreshed

                    Packager.debug "Handled: #{handled_packages}"
                    Packager.debug "Remaining: #{reverse_dependencies}"
                    if handled_packages.empty? && !reverse_dependencies.empty?
                        Packager.warn "Unhandled dependencies: #{reverse_dependencies}"
                    end
                end
                all_required_packages
            end

            def create_flow_job(name, selection, flavor, parallel_builds = false, force = false)
                flow = all_required_packages(selection)
                flow[:gems].each do |name|
                    if !flow[:gem_versions].has_key?(name)
                        flow[:gem_versions][name] = "noversion"
                    end
                end

                Packager.info "Creating flow of gems: #{flow[:gems]}"

                create_flow_job_xml(name, flow, flavor, false, force)
            end

            def create_flow_job_xml(name, flow, flavor, parallel = false, force = false)
                safe_level = nil
                trim_mode = "%<>"

                template = ERB.new(File.read(File.join(File.dirname(__FILE__), "templates", "jenkins-flow-job.xml")), safe_level, trim_mode)
                rendered = template.result(binding)
                Packager.info "Rendering file: #{File.join(Dir.pwd, name)}.xml"
                File.open("#{name}.xml", 'w') do |f|
                      f.write rendered
                end

                if force
                    Packager.info "Update job: #{name}"
                    system("java -jar ~/jenkins-cli.jar -s http://localhost:8080/ update-job '#{name}' < #{name}.xml")
                else
                    Packager.info "Create job: #{name}"
                    system("java -jar ~/jenkins-cli.jar -s http://localhost:8080/ create-job '#{name}' < #{name}.xml")
                end
            end

            def update_list(pkg, file)
                Autoproj.info("Update Packagelist #{file} with #{pkg}")
                if File.exist? file
                    list = YAML.load_file(file)
                else
                    FileUtils.mkdir_p(File.dirname(file)) unless File.exists?(File.dirname(file))
                    list = Hash.new
                end
                if pkg.is_a? String
                    list[pkg] = {"debian,ubuntu" => debian_ruby_name(pkg)}
                #    list.uniq!
                else
                    list[pkg.name] = {"debian,ubuntu" => debian_name(pkg)}
                #    list.uniq!
                end
                File.open(file, 'w') {|f| f.write list.to_yaml }
            end

            # Create a jenkins job for a rock package (which is not a ruby package)
            def create_package_job(pkg, options = Hash.new, force = false)
                options[:type] = :package
                # Use parameter for job
                # for destination and build directory
                options[:dir_name] = debian_name(pkg)
                # avoid the rock-release prefix for jobs
                with_rock_release_prefix = false
                options[:job_name] = debian_name(pkg, with_rock_release_prefix)
                options[:package_name] = pkg.name

                all_deps = dependencies(pkg)
                Packager.info "Dependencies of #{pkg.name}: rock: #{all_deps[:rock]}, osdeps: #{all_deps[:osdeps]}, nonnative: #{all_deps[:nonnative].to_a}"

                # Prepare upstream dependencies
                deps = all_deps[:rock].join(", ")
                if !deps.empty?
                    deps += ", "
                end
                options[:dependencies] = deps
                Packager.info "Create package job: #{options[:job_name]}, options #{options}"
                create_job(options[:job_name], options, force)
            end

            # Create a jenkins job for a ruby package
            def create_ruby_job(gem_name, options = Hash.new, force = false)
                options[:type] = :gem
                # for destination and build directory
                options[:dir_name] = debian_ruby_name(gem_name)
                options[:job_name] = gem_name
                options[:package_name] = gem_name
                Packager.info "Create ruby job: #{gem_name}, options #{options}"
                create_job(options[:job_name], options, force)
            end


            # Create a jenkins job
            def create_job(package_name, options = Hash.new, force = false)
                options[:architectures] ||= Packaging::Config.architectures.keys
                options[:distributions] ||= Packaging::Config.active_distributions
                options[:job_name] ||= package_name

                combinations = combination_filter(options[:architectures], options[:distributions], package_name, options[:type] == :gem)


                Packager.info "Creating jenkins-debian-glue job for #{package_name} with"
                Packager.info "         options: #{options}"
                Packager.info "         combination filter: #{combinations}"

                safe_level = nil
                trim_mode = "%<>"
                template = ERB.new(File.read(File.join(File.dirname(__FILE__), "templates", "jenkins-debian-glue-job.xml")), safe_level, trim_mode)
                rendered = template.result(binding)
                rendered_filename = File.join("/tmp","#{options[:job_name]}.xml")
                File.open(rendered_filename, 'w') do |f|
                      f.write rendered
                end

                update_or_create = "create-job"
                if force
                    update_or_create = "update-job"
                end
                if system("java -jar ~/jenkins-cli.jar -s http://localhost:8080/ #{update_or_create} '#{options[:job_name]}' < #{rendered_filename}")
                    Packager.info "job #{options[:job_name]}': #{update_or_create} from #{rendered_filename}"
                elsif force
                    if system("java -jar ~/jenkins-cli.jar -s http://localhost:8080/ create-job '#{options[:job_name]}' < #{rendered_filename}")
                        Packager.info "job #{options[:job_name]}': create-job from #{rendered_filename}"
                    end
                end
            end

            # Combination filter generates a filter for each job
            # The filter allows to prevent building of the package, when this
            # package is already part of the release of a distribution release, e.g.,
            # there is no need to repackage the ruby package 'bundler' if it already
            # exists in a specific release of Ubuntu or Debian
            def combination_filter(architectures, distributions, package_name, isGem)
                Packager.info "Filter combinations of: archs #{architectures} , dists: #{distributions},
                package: '#{package_name}', isGem: #{isGem}"
                whitelist = []
                Packaging::Config.architectures.each do |requested_architecture, allowed_distributions|
                    allowed_distributions.each do |release|
                        if not distributions.include?(release)
                            next
                        end
                        target_platform = TargetPlatform.new(release, requested_architecture)

                        if  (isGem && target_platform.contains(debian_ruby_name(package_name,false))) ||
                                target_platform.contains(package_name)
                            Packager.info "package: '#{package_name}' is part of the ubuntu release: '#{release}'"
                        else
                            whitelist << [release, requested_architecture]
                        end
                    end
                end

                ret = ""
                and_placeholder = " &amp;&amp; "
                architectures.each do |arch|
                    distributions.each do |dist|
                        if !whitelist.include? [dist, arch]
                            ret += "#{and_placeholder} !(distribution == '#{dist}' &amp;&amp; architecture == '#{arch}')"
                        end
                    end
                end

                # Cut the first and_placeholder away
                ret = ret[and_placeholder.size..-1]
            end

            def self.list_all_jobs
                jobs_file = "/tmp/jenkins-jobs"
                # java -jar /home/rimresadmin/jenkins-cli.jar -s http://localhost:8080 help
                cmd = "java -jar ~/jenkins-cli.jar -s http://localhost:8080/ list-jobs > #{jobs_file}"
                if !system(cmd)
                    raise RuntimeError, "Failed to list all jobs using: #{cmd}"
                end

                all_jobs = []
                File.open(jobs_file,"r") do |file|
                    all_jobs = file.read.split("\n")
                end
                all_jobs
            end

            def self.cleanup_all_jobs
                all_jobs = list_all_jobs
                max_count = all_jobs.size
                i = 1
                all_jobs.each do |job|
                    Packager.info "Cleanup job #{i}/#{max_count}"
                    cleanup_job job
                    i += 1
                end
            end

            def self.remove_all_jobs
                all_jobs = list_all_jobs.delete_if{|job| job.start_with? 'a_' or job.start_with? '0_'}
                max_count = all_jobs.size
                i = 1
                all_jobs.each do |job|
                    Packager.info "Remove job #{i}/#{max_count}"
                    remove_job job
                    i += 1
                end
            end

            def self.who_am_i
                cmd = "java -jar ~/jenkins-cli.jar -s http://localhost:8080/ who-am-i"
                if !system(cmd)
                    raise RuntimeError, "Failed to identify user: please register your public key in jenkins"
                end
            end

            # Cleanup job of a given name
            def self.cleanup_job(job_name)
                # java -jar /home/rimresadmin/jenkins-cli.jar -s http://localhost:8080 help delete-builds
                # java -jar jenkins-cli.jar delete-builds JOB RANGE
                # Delete build records of a specified job, possibly in a bulk.
                #   JOB   : Name of the job to build
                #   RANGE : Range of the build records to delete. 'N-M', 'N,M', or 'N'
                cmd = "java -jar ~/jenkins-cli.jar -s http://localhost:8080/ delete-builds '#{job_name}' '1-10000'"
                Packager.info "job '#{job_name}': cleanup with #{cmd}"
                if !system(cmd)
                    Packager.warn "job '#{job_name}': cleanup failed"
                end
            end

            # Remove job of a given name
            def self.remove_job(job_name)
                #java -jar /home/rimresadmin/jenkins-cli.jar -s http://localhost:8080 help delete-job
                #java -jar jenkins-cli.jar delete-job VAL ...
                #    Deletes job(s).
                #     VAL : Name of the job(s) to delete
                cmd = "java -jar ~/jenkins-cli.jar -s http://localhost:8080/ delete-job '#{job_name}'"
                Packager.info "job '#{job_name}': remove with #{cmd}"
                if !system(cmd)
                    Packager.warn "job '#{job_name}': remove failed"
                end
            end
            # Commit changes of a debian package using dpkg-source --commit
            # in a given directory (or the current one by default)
            def dpkg_commit_changes(patch_name, directory = Dir.pwd)
                Dir.chdir(directory) do
                    Packager.debug ("commit changes to debian pkg: #{patch_name}")
                    # Since dpkg-source will open an editor we have to
                    # take this approach to make it pass directly in an
                    # automated workflow
                    ENV['EDITOR'] = "/bin/true"
                    `dpkg-source --commit . #{patch_name}`
                end
            end

            # Get all required rubygem including the dependencies of ruby gems
            #
            # This requires the current installation to be complete since
            # `gem dependency <gem-name>` has been selected to provide the information
            def all_required_packages(selection, with_rock_release_prefix = false)
                all_packages = all_required_rock_packages(selection)
                rock_packages = all_packages.map{ |pkg| debian_name(pkg, with_rock_release_prefix) }

                gems = Array.new
                gem_versions = Hash.new

                # Make sure to account for extra packages
                @ruby_gems.each do |name, version|
                    gems << name
                    gem_versions[name] ||= Array.new
                    gem_versions[name] << version
                end

                all_packages.each do |pkg|
                    pkg = Autoproj.manifest.package(pkg.name).autobuild
                    deps = dependencies(pkg, with_rock_release_prefix)
                    deps[:nonnative].each do |dep, version|
                        gem_versions[dep] ||= Array.new
                        if version
                            gem_versions[dep] << version
                        end
                    end
                end

                gem_version_requirements = gem_versions.dup
                gem_dependencies = GemDependencies.resolve_all(gem_versions)
                gem_dependencies.each do |name, deps|
                    if deps
                        deps.each do |dep_name, dep_versions|
                            gem_version_requirements[dep_name] ||= Array.new
                            gem_version_requirements[dep_name] = (gem_version_requirements[dep_name] + dep_versions).uniq
                        end
                    end
                end
                exact_version_list = GemDependencies.gem_exact_versions(gem_version_requirements)
                sorted_gem_list = GemDependencies.sort_by_dependency(gem_dependencies).uniq

                {:packages => all_packages, :gems => sorted_gem_list, :gem_versions => exact_version_list }
            end

            # Compute dependencies of this package
            # Returns [:rock => rock_packages, :osdeps => osdeps_packages, :nonnative => nonnative_packages ]
            def dependencies(pkg, with_rock_release_prefix = true)
                # Reload pkg manifest to get all dependencies -- otherwise
                # the dependencies list might be incomplete
                # TODO: Check if this is a bug in autoproj
                pkg_manifest = Autoproj.manifest.load_package_manifest(pkg.name)
                pkg = pkg_manifest.package

                pkg.resolve_optional_dependencies
                deps_rock_packages = pkg.dependencies.map do |dep_name|
                    debian_name(Autoproj.manifest.package(dep_name).autobuild, with_rock_release_prefix)
                end.sort

                Packager.info "'#{pkg.name}' with rock package dependencies: '#{deps_rock_packages}' -- #{pkg.dependencies}"

                pkg_osdeps = Autoproj.osdeps.resolve_os_dependencies(pkg.os_packages)
                # There are limitations regarding handling packages with native dependencies
                #
                # Currently gems need to converted into debs using gem2deb
                # These deps dependencies are updated here before uploading a package
                #
                # Generation of the debian packages from the gems can be done in postprocessing step
                # i.e. see convert_gems

                deps_osdeps_packages = []
                native_package_manager = Autoproj.osdeps.os_package_handler
                _, native_pkg_list = pkg_osdeps.find { |handler, _| handler == native_package_manager }

                deps_osdeps_packages += native_pkg_list if native_pkg_list
                Packager.info "'#{pkg.name}' with osdeps dependencies: '#{deps_osdeps_packages}'"

                # Update global list
                @osdeps += deps_osdeps_packages

                non_native_handlers = pkg_osdeps.collect do |handler, pkg_list|
                    if handler != native_package_manager
                        [handler, pkg_list]
                    end
                end.compact

                non_native_dependencies = Set.new
                non_native_handlers.each do |pkg_handler, pkg_list|
                    # Convert native ruby gems package names to rock-xxx
                    if pkg_handler.kind_of?(Autoproj::PackageManagers::GemManager)
                        pkg_list.each do |name,version|
                            @ruby_gems << [name,version]
                            non_native_dependencies << [name, version]
                        end
                    else
                        raise ArgumentError, "cannot package #{pkg.name} as it has non-native dependencies (#{pkg_list}) -- #{pkg_handler.class} #{pkg_handler}"
                    end
                end
                Packager.info "#{pkg.name}' with non native dependencies: #{non_native_dependencies.to_a}"

                # Remove duplicates
                @osdeps.uniq!
                @ruby_gems.uniq!

                if target_platform.distribution_release_name
                    # CASTXML vs. GCCXML
                    if pkg.name =~ /typelib/ && !["xenial"].include?(target_platform.distribution_release_name)
                        # remove the optional dependency on the rock-package of for all other except for xenial
                        deps_rock_packages.delete(rock_release_prefix + "castxml")
                    end
                    Packager.info "'#{pkg.name}' with (available) rock package dependencies: '#{deps_rock_packages}' -- #{pkg.dependencies}"

                    # Filter out optional packages, e.g. llvm and clang for all platforms where not explicitly available
                    deps_osdeps_packages = deps_osdeps_packages.select do |name|
                        result = true
                        Packaging::Config.packages_optional.each do |pkg_name|
                            regex = Regexp.new(pkg_name)
                            if regex.match(name)
                                result = target_platform.contains(name)
                            end
                        end
                        result
                    end
                    Packager.info "'#{pkg.name}' with (available) osdeps dependencies: '#{deps_osdeps_packages}'"

                    # Filter ruby versions out -- we assume chroot has installed all
                    # ruby versions
                    #
                    # This is a workaround, since the information about required packages
                    # comes from the build server platform and might not correspond
                    # with the target platform
                    #
                    # Right approach: bootstrap within chroot and generate source packages
                    # in the chroot
                    #deps_osdeps_packages = deps[:osdeps].select do |name|
                    deps_osdeps_packages = deps_osdeps_packages.select do |name|
                        name !~ /^ruby[0-9][0-9.]*/
                    end

                    # Prefer package of the OS for gems if they are available there
                    #deps_nonnative_packages = deps[:nonnative].map do |name, version|
                    non_native_dependencies = non_native_dependencies.map do |name, version|
                        dep_name,is_osdep = native_dependency_name(name)
                        # if with_rock_release_prefix is given all packages 'have to be'
                        # os dependencies, otherwise it triggers further resolution of nonative packages
                        # which cannot exist (in resolve_all)
                        if is_osdep || with_rock_release_prefix
                            deps_osdeps_packages << dep_name
                            nil
                        else
                            dep_name
                        end
                    end.compact
                end

                # Return rock packages, osdeps and non native deps (here gems)
                {:rock => deps_rock_packages, :osdeps => deps_osdeps_packages, :nonnative => non_native_dependencies }
            end

            # Check if the plain package name exists in the given distribution
            # if that is the case use that one -- if not, then use the ruby name
            # since then is it is either part of the flow job
            # or an os dependency
            # return [String,bool] Name of the dependency and whether this is an os dependency or not
            def native_dependency_name(name)
                if target_platform.contains(name)
                    [name, true]
                elsif target_platform.contains(debian_ruby_name(name, false))
                    [debian_ruby_name(name, false), true]
                else
                    [debian_ruby_name(name, true), false]
                end
            end

            def generate_debian_dir(pkg, dir, options)
                options, unknown_options = Kernel.filter_options options,
                    :distribution => nil

                distribution = options[:distribution]

                existing_dir = File.join(existing_debian_directories, pkg.name)
                template_dir =
                    if File.directory?(existing_dir)
                        existing_dir
                    else
                        TEMPLATES
                    end

                dir = File.join(dir, "debian")
                FileUtils.mkdir_p dir
                package = pkg
                debian_name = debian_name(pkg)
                debian_version = debian_version(pkg, distribution)
                versioned_name = versioned_name(pkg, distribution)

                with_rock_prefix = true
                deps = dependencies(pkg, with_rock_prefix)
                deps_rock_packages = deps[:rock]
                deps_osdeps_packages = deps[:osdeps]
                deps_nonnative_packages = deps[:nonnative].to_a

                Packager.info "Required OS Deps: #{deps_osdeps_packages}"
                Packager.info "Required Nonnative Deps: #{deps_nonnative_packages}"

                Find.find(template_dir) do |path|
                    next if File.directory?(path)
                    template = ERB.new(File.read(path), nil, "%<>", path.gsub(/[^w]/, '_'))
                    rendered = template.result(binding)

                    target_path = File.join(dir, Pathname.new(path).relative_path_from(Pathname.new(template_dir)).to_s)
                    FileUtils.mkdir_p File.dirname(target_path)
                    File.open(target_path, "w") do |io|
                        io.write(rendered)
                    end
                end
            end

            # A tar gzip version that reproduces
            # same checksums on the same day when file content does not change
            #
            # Required to package orig.tar.gz
            def tar_gzip(archive, tarfile, distribution = nil)

                # Make sure no distribution information leaks into the package
                if distribution and archive =~ /~#{distribution}/
                    archive_plain_name = archive.gsub(/~#{distribution}/,"")
                    FileUtils.cp_r archive, archive_plain_name
                else
                    archive_plain_name = archive
                end


                Packager.info "Tar archive: #{archive_plain_name} into #{tarfile}"
                # Make sure that the tar files checksum remains the same, even when modification timestamp changes,
                # i.e. use gzip --no-name and set the initial date to the current day
                #
                # NOTE: What if building over midnight -- single point of failure
                mtime=`date +#{Packaging::Config.timestamp_format}`
                cmd_tar = "tar --mtime='#{mtime}' --format=gnu -c --exclude .git --exclude .svn --exclude CVS --exclude debian --exclude build #{archive_plain_name} | gzip --no-name > #{tarfile}"

                if system(cmd_tar)
                    Packager.info "Package: successfully created archive using command '#{cmd_tar}' -- pwd #{Dir.pwd} -- #{Dir.glob("**")}"
                    checksum = `sha256sum #{tarfile}`
                    Packager.info "Package: sha256sum: #{checksum}"
                    return true
                else
                    Packager.info "Package: failed to create archive using command '#{cmd_tar}' -- pwd #{Dir.pwd}"
                    return false
                end
            end

            # Package the given package
            # if an existing source directory is given this will be used
            # for packaging, otherwise the package will be bootstrapped
            def package(pkg, options = Hash.new)
                options, unknown_options = Kernel.filter_options options,
                    :force_update => false,
                    :existing_source_dir => nil,
                    :patch_dir => nil,
                    :package_set_dir => nil,
                    :distribution => nil, # allow to override global settings
                    :architecture => nil

                if options[:force_update]
                    dirname = File.join(build_dir, debian_name(pkg))
                    if File.directory?(dirname)
                        Packager.info "Debian: rebuild requested -- removing #{dirname}"
                        FileUtils.rm_rf(dirname)
                    end
                end

                options[:distribution] ||= target_platform.distribution_release_name
                options[:architecture] ||= target_platform.architecture

                prepare_source_dir(pkg, options)

                if pkg.kind_of?(Autobuild::CMake) || pkg.kind_of?(Autobuild::Autotools)
                    package_deb(pkg, options)
                elsif pkg.kind_of?(Autobuild::Ruby)
                    package_ruby(pkg, options)
                elsif pkg.importer.kind_of?(Autobuild::ArchiveImporter) || pkg.kind_of?(Autobuild::ImporterPackage)
                    package_importer(pkg, options)
                else
                    raise ArgumentError, "Debian: Unsupported package type #{pkg.class} for #{pkg.name}"
                end
                if !options[:package_set_dir].nil?
                    osdeps_file = YAML.load_file(options[:package_set_dir] + "rock-osdeps.osdeps")
                    osdeps_file[pkg.name] = {'debian,ubuntu' => debian_name(pkg)}
                    File.open(options[:package_set_dir] + "rock-osdeps.osdeps", 'w+') {|f| f.write(osdeps_file.to_yaml) }
                end
            end

            # Create an deb package of an existing ruby package
            def package_ruby(pkg, options)
                Packager.info "Package Ruby: '#{pkg.name}' with options: #{options}"
                # update dependencies in any case, i.e. independant if package exists or not
                deps = dependencies(pkg)
                Dir.chdir(pkg.srcdir) do
                    begin
                        logname = "obs-#{pkg.name.sub("/","-")}" + "-" + Time.now.strftime("%Y%m%d-%H%M%S").to_s + ".log"
                        gem = FileList["pkg/*.gem"].first
                        if not gem
                            Packager.info "Debian: preparing gem generation in #{Dir.pwd}"

                            # Rake targets that should be tried for cleaning
                            gem_clean_success = false
                            @gem_clean_alternatives.each do |target|
                                if !system("rake #{target} > #{File.join(log_dir, logname)} 2> #{File.join(log_dir, logname)}")
                                    Packager.info "Debian: failed to clean package '#{pkg.name}' using target '#{target}'"
                                else
                                    Packager.info "Debian: succeeded to clean package '#{pkg.name}' using target '#{target}'"
                                    gem_clean_success = true
                                    break
                                end
                            end
                            if not gem_clean_success
                                Packager.warn "Debian: failed to cleanup ruby package '#{pkg.name}' -- continuing without cleanup"
                            end

                            Packager.info "Debian: ruby package Manifest.txt is being autogenerated"
                            if !system('find . -type f | grep -v .git/ | grep -v build/ | grep -v tmp/ | sed \'s/\.\///\' > Manifest.txt')
                                raise "Debian: failed to create an up to date Manifest.txt"
                            end
                            Packager.info "Debian: creating gem from package #{pkg.name} [#{File.join(log_dir, logname)}]"

                            # Allowed gem creation alternatives
                            gem_creation_success = false
                            @gem_creation_alternatives.each do |target|
                                if !system("rake #{target} >> #{File.join(log_dir, logname)} 2>> #{File.join(log_dir, logname)}")
                                    Packager.info "Debian: failed to create gem using target '#{target}'"
                                else
                                    Packager.info "Debian: succeeded to create gem using target '#{target}'"
                                    gem_creation_success = true
                                    break
                                end
                            end
                            if not gem_creation_success
                                raise "Debian: failed to create gem from RubyPackage #{pkg.name}"
                            end
                        end

                        gem = FileList["pkg/*.gem"].first

                        # Make the naming of the gem consistent with the naming schema of
                        # rock packages
                        #
                        # Make sure the gem has the fullname, e.g.
                        # tools-metaruby instead of just metaruby
                        Packager.info "Debian: '#{pkg.name}' -- basename: #{basename(pkg.name)} will be canonized to: #{canonize(pkg.name)}"
                        gem_rename = gem.sub(basename(pkg.name), canonize(pkg.name))
                        if gem != gem_rename
                            Packager.info "Debian: renaming #{gem} to #{gem_rename}"
                        end

                        Packager.debug "Debian: copy #{gem} to #{packaging_dir(pkg)}"
                        gem_final_path = File.join(packaging_dir(pkg), File.basename(gem_rename))
                        FileUtils.cp gem, gem_final_path

                        # Prepare injection of dependencies
                        options[:deps] = deps
                        options[:local_pkg] = true
                        convert_gem(gem_final_path, options)
                        # register gem with the correct naming schema
                        # to make sure dependency naming and gem naming are consistent
                        @ruby_rock_gems << debian_name(pkg)
                    rescue Exception => e
                        raise "Debian: failed to create gem from RubyPackage #{pkg.name} -- #{e.message}\n#{e.backtrace.join("\n")}"
                    end
                end
            end

            def package_deb(pkg, options)
                Packager.info "Package Deb: '#{pkg.name}' with options: #{options}"

                options, unknown_options = Kernel.filter_options options,
                    :distribution => nil,
                    :architecture => nil
                distribution = options[:distribution]

                Packager.info "Changing into packaging dir: #{packaging_dir(pkg)}"
                Dir.chdir(packaging_dir(pkg)) do
                    FileUtils.rm_rf File.join(pkg.srcdir, "debian")
                    FileUtils.rm_rf File.join(pkg.srcdir, "build")

                    sources_name = plain_versioned_name(pkg, distribution)
                    # First, generate the source tarball
                    tarball = "#{sources_name}.orig.tar.gz"

                    # Check first if actual source contains newer information than existing
                    # orig.tar.gz -- only then we create a new debian package
                    if package_updated?(pkg)

                        Packager.warn "Package: #{pkg.name} requires update #{pkg.srcdir}"
                        if !tar_gzip(File.basename(pkg.srcdir), tarball, distribution)
                            raise RuntimeError, "Debian: #{pkg.name} failed to create archive"
                        end

                        # Generate the debian directory
                        generate_debian_dir(pkg, pkg.srcdir, options)

                        # Commit local changes, e.g. check for
                        # control/urdfdom as an example
                        dpkg_commit_changes("local_build_changes", pkg.srcdir)

                        # Run dpkg-source
                        # Use the new tar ball as source
                        if !system("dpkg-source", "-I", "-b", pkg.srcdir)
                            Packager.warn "Package: #{pkg.name} failed to perform dpkg-source -- #{Dir.entries(pkg.srcdir)}"
                            raise RuntimeError, "Debian: #{pkg.name} failed to perform dpkg-source in #{pkg.srcdir}"
                        end
                        ["#{versioned_name(pkg, distribution)}.debian.tar.gz",
                         "#{plain_versioned_name(pkg, distribution)}.orig.tar.gz",
                         "#{versioned_name(pkg, distribution)}.dsc"]
                    else
                        # just to update the required gem property
                        dependencies(pkg)
                        Packager.info "Package: #{pkg.name} is up to date"
                    end
                    FileUtils.rm_rf( File.basename(pkg.srcdir) )
                end
            end

            def package_importer(pkg, options)
                Packager.info "Using package_importer for #{pkg.name}"
                options, unknown_options = Kernel.filter_options options,
                    :distribution => nil,
                    :architecture => nil
                distribution = options[:distribution]

                Dir.chdir(packaging_dir(pkg)) do

                    dir_name = plain_versioned_name(pkg, distribution)
		    plain_dir_name = plain_versioned_name(pkg, distribution)
                    FileUtils.rm_rf File.join(pkg.srcdir, "debian")
                    FileUtils.rm_rf File.join(pkg.srcdir, "build")

                    # Generate a CMakeLists which installs every file
                    cmake = File.new(dir_name + "/CMakeLists.txt", "w+")
                    cmake.puts "cmake_minimum_required(VERSION 2.6)"
                    add_folder_to_cmake "#{Dir.pwd}/#{dir_name}", cmake, pkg.name
                    cmake.close

                    # First, generate the source tarball
                    sources_name = plain_versioned_name(pkg, distribution)
                    tarball = "#{plain_dir_name}.orig.tar.gz"

                    # Check first if actual source contains newer information than existing
                    # orig.tar.gz -- only then we create a new debian package
                    if package_updated?(pkg)

                        Packager.warn "Package: #{pkg.name} requires update #{pkg.srcdir}"

                        source_package_dir = File.basename(pkg.srcdir)
                        if !tar_gzip(source_package_dir, tarball)
                            raise RuntimeError, "Package: failed to tar directory #{source_package_dir}"
                        end

                        # Generate the debian directory
                        generate_debian_dir(pkg, pkg.srcdir, options)

                        # Commit local changes, e.g. check for
                        # control/urdfdom as an example
                        dpkg_commit_changes("local_build_changes", pkg.srcdir)

                        # Run dpkg-source
                        # Use the new tar ball as source
			puts `dpkg-source -I -b #{pkg.srcdir}`
                        if !system("dpkg-source", "-I", "-b", pkg.srcdir)
                            Packager.warn "Package: #{pkg.name} failed to perform dpkg-source: entries #{Dir.entries(pkg.srcdir)}"
                            raise RuntimeError, "Debian: #{pkg.name} failed to perform dpkg-source in #{pkg.srcdir}"
                        end
                        ["#{versioned_name(pkg, distribution)}.debian.tar.gz",
                         "#{plain_versioned_name(pkg, distribution)}.orig.tar.gz",
                         "#{versioned_name(pkg, distribution)}.dsc"]
                    else
                        # just to update the required gem property
                        dependencies(pkg)
                        Packager.info "Package: #{pkg.name} is up to date"
                    end
                end
            end

            def build_local(pkg, options)
		filepath = BUILD_DIR
		distribution = max_one_distribution(options[:distributions])
#		if !options[:rebuild]
#puts "try to skip #{pkg.name}"
#                   return if File.exist? File.join(BUILD_DIR, debian_name(pkg)) + '/' + "#{versioned_name(pkg, distribution)}_*.deb" 
#puts "not skipped"
# 		end
		
#		if options[:recursive]
#		    pkg.dependencies.each do |pkg_name|
#puts "DEPENDENCIES of #{pkg.name}"
#    		        if pkg = Autoproj.manifest.package(pkg_name)
#		            pkg = pkg.autobuild
#                            build_local pkg, (options)
#                        else
#                          puts "nix!" 
#                        end
#		    end
#		end
#		if !options[:rebuild]
#puts "try to skip #{pkg.name} after dependencies"
#                   return if File.exist? File.join(BUILD_DIR, debian_name(pkg)) + '/' + "#{versioned_name(pkg, distribution)}_*.deb" 
#puts "not skipped after dependencies"
# 		end

		    # cd package_name
		    # tar -xf package_name_0.0.debian.tar.gz
		    # tar -xf package_name_0.0.orig.tar.gz
		    # mv debian/ package_name_0.0/
		    # cd package_name_0.0/
		    # debuild -us -uc
		    # #to install
		    # cd ..
		    # sudo dpkg -i package_name_0.0.deb
			

			Packager.info "Building #{pkg.name} locally"
			begin
			    FileUtils.chdir File.join(BUILD_DIR, debian_name(pkg)) do 
				FileUtils.rm_rf "debian"
				FileUtils.rm_rf "#{plain_versioned_name(pkg, distribution)}"
				FileUtils.mkdir "#{plain_versioned_name(pkg, distribution)}"
				`tar -xf *.debian.tar.gz`
				`tar -x --strip-components=1 -C #{plain_versioned_name(pkg, distribution)} -f *.orig.tar.gz`
				FileUtils.mv 'debian', plain_versioned_name(pkg, distribution) + '/'
				FileUtils.chdir plain_versioned_name(pkg, distribution) do
				    `debuild -us -uc`
				end
				filepath = FileUtils.pwd + '/' + "#{versioned_name(pkg, FALSE)}_ARCHITECTURE.deb" 
			    end
			rescue Errno::ENOENT
			    Packager.error "Package #{pkg.name} seems not to be packaged, try adding --package and --recursive if #{pkg.name} is a dependency of your desired package"
			    return
			end
                filepath
                
            end

            def install( pkg, options)
		install_dependencies = options[:dependencies]
	#	operating_system = options[:operating_system]
		distribution = max_one_distribution(options[:distributions])
	#	distribution = operating_system[1][1]
		architecture = `uname -m`.strip
		case architecture
		    when 'x86_64'
			architecture = 'amd64'
		    when 'i686'
                        architecture = 'i386'
                    when 'armv7l'
                        atchitecture = 'armel'
                    else
                        Packager.error "Architecture not recognized"
			return
                end
		
                begin
                    #go through all deps
                    FileUtils.chdir File.join(BUILD_DIR, debian_name(pkg)) do
                        `sudo dpkg -i #{versioned_name(pkg, FALSE)}_#{architecture}.deb`
		    end
                rescue
			Packager.error "Installation failed"
                end
                
            end


            # For importer-packages we need to add every file in the deb-package, for that we "install" every file with CMake
            # This method adds an install-line of every file (including subdirectories) of a file into the given cmake-file
            def add_folder_to_cmake(base_dir, cmake, destination, folder = ".")
                Dir.foreach("#{base_dir}/#{folder}") do |file|
                    next if file.to_s == "." or file.to_s == ".." or file.to_s.start_with? "."
                    if File.directory? "#{base_dir}/#{folder}/#{file}"
                        # create the potentially empty folder. If the folder is not empty this is useless, but empty folders would not be generated
                        cmake.puts "install(DIRECTORY #{folder}/#{file} DESTINATION share/rock/#{destination}/#{folder} FILES_MATCHING PATTERN .* EXCLUDE)"
                        add_folder_to_cmake base_dir, cmake, destination, "#{folder}/#{file}"
                    else
                        cmake.puts "install(FILES #{folder}/#{file} DESTINATION share/rock/#{destination}/#{folder})"
                    end
                end
            end

            # We create a diff between the existing orig.tar.gz and the source directory
            # to identify if there have been any updates
            #
            # Using 'diff' allows us to apply this test to all kind of packages
            def package_updated?(pkg)
                # Find an existing orig.tar.gz in the build directory
                # ignoring the current version-timestamp
                orig_file_name = Dir.glob("#{debian_name(pkg)}*.orig.tar.gz")
                if orig_file_name.empty?
                    Packager.info "No filename found for #{debian_name(pkg)} -- package requires update #{Dir.entries('.')}"
                    return true
                elsif orig_file_name.size > 1
                    Packager.warn "Multiple version of package #{debian_name(pkg)} in #{Dir.pwd} -- you have to fix this first"
                else
                    orig_file_name = orig_file_name.first
                end

                # Create a local copy/backup of the current orig.tar.gz in .obs_package
                # and extract it there -- compare the actual source package
                FileUtils.cp(orig_file_name, local_tmp_dir)
                Dir.chdir(local_tmp_dir) do
                    `tar xzf #{orig_file_name}`
                    base_name = orig_file_name.sub(".orig.tar.gz","")
                    Dir.chdir(base_name) do
                        diff_name = File.join(local_tmp_dir, "#{orig_file_name}.diff")
                        `diff -urN --exclude .git --exclude .svn --exclude CVS --exclude debian --exclude build #{pkg.srcdir} . > #{diff_name}`
                        Packager.info "Package: '#{pkg.name}' checking diff file '#{diff_name}'"
                        if File.open(diff_name).lines.any?
                            return true
                        end
                    end
                end
                return false
            end

            # Prepare the build directory, i.e. cleanup and obsolete file
            def prepare
                if not File.exists?(build_dir)
                    FileUtils.mkdir_p build_dir
                end
                cleanup
            end

            # Cleanup an existing local tmp folder in the build dir
            def cleanup
                tmpdir = File.join(build_dir,local_tmp_dir)
                if File.exists?(tmpdir)
                    FileUtils.rm_rf(tmpdir)
                end
            end

            def file_suffix_patterns
                [".dsc", ".orig.tar.gz", ".debian.tar.gz", ".debian.tar.xz"]
            end

            def system(*args)
                Kernel.system(*args)
            end

            # Convert all gems that are required
            # by package build with the debian packager
            def convert_gems(gems, options = Hash.new)
                Packager.info "Convert gems: #{gems} with options #{options}"
                if gems.empty?
                    return
                end

                options, unknown_options = Kernel.filter_options options,
                    :force_update => false,
                    :patch_dir => nil,
                    :local_pkg => false,
                    :distribution => target_platform.distribution_release_name,
                    :architecture => target_platform.architecture

                distribution = options[:distribution]

                if unknown_options.size > 0
                    Packager.warn "Autoproj::Packaging Unknown options provided to convert gems: #{unknown_options}"
                end

                # We use gem2deb for the job of converting the gems
                # However, since we require some gems to be patched we split the process into the
                # individual step
                # This allows to add an overlay (patch) to be added to the final directory -- which
                # requires to be commited via dpkg-source --commit
                gems.each do |gem_name, version|
                    gem_dir_name = debian_ruby_name(gem_name)

                    if options[:force_update]
                        dirname = File.join(build_dir, gem_dir_name)
                        if File.directory?(dirname)
                            Packager.info "Debian Gem: rebuild requested -- removing #{dirname}"
                            FileUtils.rm_rf(dirname)
                        end
                    end

                    # Assuming if the .gem file has been download we do not need to update
                    if options[:force_update] or not Dir.glob("#{gem_dir_name}/#{gem_name}*.gem").size > 0
                        Packager.debug "Converting gem: '#{gem_name}' to debian source package"
                        if not File.directory?(gem_dir_name)
                            FileUtils.mkdir gem_dir_name
                        end

                        Dir.chdir(gem_dir_name) do
                            gem_from_cache = false
                            if patch_dir = options[:patch_dir]
                                gem_dir = File.join(patch_dir, "gems", gem_name)
                                if File.directory?(gem_dir)
                                    gem = Dir.glob("#{gem_dir}/*.gem")
                                    if !gem.empty?
                                        gem_from_cache = true
                                        Packager.info "Using gem from cache: copying #{gem.first} to #{Dir.pwd}"
                                        FileUtils.cp gem.first,"."
                                    end
                                end
                            end

                            if !gem_from_cache
                                error = true
				max_retry = 10
				retry_count = 1
                                loop do
                                    Packager.warn "[#{retry_count}/#{max_retry}] Retrying gem fetch #{gem_name}" if retry_count > 1
                                    if version
                                        pid = Process.spawn("gem fetch #{gem_name} --version '#{version}'")
                                        #output = `gem fetch #{gem_name} --version '#{version}'`
                                    else
                                        pid = Process.spawn("gem fetch #{gem_name}")
                                        #output = `gem fetch #{gem_name}`
                                    end
                                    begin
                                        Timeout.timeout(60) do
                                            puts 'waiting for gem fetch to end'
                                            Process.wait(pid)
                                            puts 'gem fetch seems successful'
                                            error = false
                                        end
                                    rescue Timeout::Error
                                        puts 'gem fetch not finished in time, killing it'
                                        Process.kill('TERM', pid)
                                        error = true
                                    end
                                    retry_count += 1
                                    break if not error or retry_count > max_retry
                                end
                            end
                        end
                        gem_file_name = Dir.glob("#{gem_dir_name}/#{gem_name}*.gem").first
                        convert_gem(gem_file_name, options)
                    else
                        Packager.info "gem: #{gem_name} up to date"
                    end
                end
            end

            # When providing the path to a gem file converts the gem into
            # a debian package (files will be residing in the same folder
            # as the gem)
            #
            # When provided a patch directory with the name of the gem,
            # e.g. hoe, nokogiri, utilrb
            # the corresponding files will be copy into the built package during
            # the gem building process
            #
            # default options
            #        :patch_dir => nil,
            #        :deps => {:rock => [], :osdeps => [], :nonnative => []},
            #        :distribution =>  nil
            #        :architecture => nil
            #        :local_package => false
            #
            def convert_gem(gem_path, options = Hash.new)
                Packager.info "Convert gem: '#{gem_path}' with options: #{options}"

                options, unknown_options = Kernel.filter_options options,
                    :patch_dir => nil,
                    :deps => {:rock => [], :osdeps => [], :nonnative => []},
                    :distribution => target_platform.distribution_release_name,
                    :architecture => target_platform.architecture,
                    :local_pkg => false

                distribution = options[:distribution]

                gem_base_name = ""
                Dir.chdir(File.dirname(gem_path)) do
                    gem_file_name = File.basename(gem_path)
                    gem_versioned_name = gem_file_name.sub("\.gem","")

                    # Dealing with _ in original file name, since gem2deb
                    # will debianize it
                    if gem_versioned_name =~ /(.*)(-[0-9]+\.[0-9\.-]*(-[0-9]+)*)/
                        gem_base_name = $1
                        version_suffix = gem_versioned_name.gsub(gem_base_name,"").gsub(/\.gem/,"")
                        gem_version = version_suffix.sub('-','')
                        Packager.info "gem basename: #{gem_base_name}"
                        Packager.info "gem version: #{gem_version}"
                        gem_versioned_name = gem_base_name.gsub("_","-") + version_suffix
                    else
                        raise ArgumentError, "Converting gem: unknown formatting: '#{gem_versioned_name}' -- cannot extract version"
                    end

                    ############
                    # Step 1: calling gem2tgz
                    ############
                    Packager.info "Converting gem: #{gem_versioned_name} in #{Dir.pwd}"
                    # Convert .gem to .tar.gz
                    cmd = "gem2tgz #{gem_file_name}"
                    if not system(cmd)
                        raise RuntimeError, "Converting gem: '#{gem_path}' failed -- gem2tgz failed"
                    else
                        # Unpack and repack the orig.tar.gz to
                        # (1) remove timestamps to create consistent checksums
                        # (2) remove gem2deb residues that should not be there, e.g. checksums.yaml.gz
                        # (3) guarantee consisted gem naming, e.g. ruby-concurrent turn in ruby-concurrent-0.7.2-x64-86-linux,
                        #     but we require ruby-concurrent-0.7.2
                        #
                        Packager.info "Successfully called: 'gem2tgz #{gem_file_name}' --> #{Dir.glob("**")}"
                        # Get the actual result of the conversion and unwrap
                        gem_tar_gz = Dir.glob("*.tar.gz").first
                        `tar xzf #{gem_tar_gz}`
                        FileUtils.rm gem_tar_gz

                        # Check if we need to convert the name
                        if gem_tar_gz != "#{gem_versioned_name}.tar.gz"
                            tmp_source_dir = gem_tar_gz.gsub(/.tar.gz/,"")
                            FileUtils.mv tmp_source_dir, gem_versioned_name
                        end
                        Packager.info "Converted: #{Dir.glob("**")}"

                        # https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=725348
                        checksums_file="checksums.yaml.gz"
                        files = Dir.glob("*/#{checksums_file}")
                        if not files.empty?
                            checksums_file = files.first
                        end

                        if File.exists? checksums_file
                            Packager.info "Pre-packaging cleanup: removing #{checksums_file}"
                            FileUtils.rm checksums_file
                        else
                            Packager.info "Pre-packaging cleannup: no #{checksums_file} found"
                        end

                        # Repackage
                        source_dir = gem_versioned_name
                        if !tar_gzip(source_dir, "#{gem_versioned_name}.tar.gz")
                            raise RuntimeError, "Failed to reformat original #{gem_versioned_name}.tar.gz for gem"
                        end
                        FileUtils.rm_rf source_dir
                        Packager.info "Converted: #{Dir.glob("**")}"
                    end


                    ############
                    # Step 2: calling dh-make-ruby
                    ############
                    # Create ruby-<name>-<version> folder including debian/ folder
                    # from .tar.gz
                    #`dh-make-ruby --ruby-versions "ruby1.9.1" #{gem_versioned_name}.tar.gz`
                    #
                    # By default generate for all ruby versions
                    # rename to the rock specific format: use option -p
                    cmd = "dh-make-ruby --ruby-versions \"all\" #{gem_versioned_name}.tar.gz -p #{rock_ruby_release_prefix}#{gem_base_name}"
                    Packager.info "calling: #{cmd}"
                    if !system(cmd)
                         Packager.warn "calling: dh-make-ruby #{gem_versioned_name}.tar.gz -p #{gem_base_name} failed"
                         raise RuntimeError, "Failed to call dh-make-ruby for #{gem_versioned_name}"
                    end

                    debian_ruby_name = debian_ruby_name(gem_versioned_name)# + '~' + distribution
                    Packager.info "Debian ruby name: #{debian_ruby_name} -- directory #{Dir.glob("**")}"


                    # Check if patching is needed
                    # To allow patching we need to split `gem2deb -S #{gem_name}`
                    # into its substeps
                    Dir.chdir(debian_ruby_name) do
                        # Only if a patch directory is given then update
                        if patch_dir = options[:patch_dir]
                            gem_name = ""
                            if gem_versioned_name =~ /(.*)[-_][0-9\.]*/
                                gem_name = $1
                            end

                            gem_patch_dir = File.join(patch_dir, gem_name)
                            if File.directory?(gem_patch_dir)
                                Packager.warn "Applying overlay (patch) to: gem '#{gem_name}'"
                                FileUtils.cp_r("#{gem_patch_dir}/.", ".")

                                # We need to commit if original files have been modified
                                # so add a commit
                                orig_files = Dir["#{gem_patch_dir}/**"].reject { |f| f["#{gem_patch_dir}/debian/"] }
                                if orig_files.size > 0
                                    dpkg_commit_changes("deb_autopackaging_overlay")
                                end
                            else
                                Packager.warn "No patch dir: #{gem_patch_dir}"
                            end
                        end

                        #####################
                        # pkgconfig/*.pc file
                        #####################
                        # allow usage of ${rock_install_dir} in pkgconfig files
                        pkgconfig_file = Dir.glob("pkgconfig/*.pc")
                        if !pkgconfig_file.empty?
                            pkgconfig_file = pkgconfig_file.first
                            `sed -i '1 i rock_install_dir=#{rock_install_directory}' #{pkgconfig_file}`
                            dpkg_commit_changes("update_pkgconfig_file")
                        end

                        ################
                        # debian/install
                        ################
                        if File.exists?("debian/install")
                            `sed -i "s#/usr##{rock_install_directory}#g" debian/install`
                            dpkg_commit_changes("install_to_rock_specific_directory")
                        end

                        ################
                        # debian/control
                        ################

                        # Injecting dependencies into debian/control
                        # Since we do not differentiate between build and runtime dependencies
                        # at Rock level -- we add them to both
                        #
                        # Enforces to have all dependencies available when building the packages
                        # at the build server

                        # Filter ruby versions out -- we assume chroot has installed all
                        # ruby versions
                        all_deps = options[:deps][:osdeps].select do |name|
                            name !~ /^ruby[0-9][0-9.]*/
                        end
                        options[:deps][:rock].each do |pkg|
                            all_deps << pkg
                        end

                        # Add actual gem dependencies
                        gem_deps = Hash.new
                        nonnative_packages = options[:deps][:nonnative]
                        if !nonnative_packages.empty?
                            gem_deps = GemDependencies::resolve_all(nonnative_packages)
                        elsif !options[:local_pkg]
                            gem_deps = GemDependencies::resolve_by_name(gem_base_name, gem_version)[:deps]
                        end

                        # Check if the plain package name exists in the given distribution
                        # if that is the case use that one -- if not, then use the ruby name
                        # since then is it is either part of the flow job
                        # or an os dependency
                        gem_deps = gem_deps.keys.each do |k|
                            depname, is_osdeps = native_dependency_name(k)
                            all_deps << depname
                        end
                        deps = all_deps.uniq

                        if not deps.empty?
                            Packager.info "#{debian_ruby_name}: injecting gem dependencies: #{deps.join(",")}"
                            `sed -i "s#^\\(^Depends: .*\\)#\\1, #{deps.join(", ")}#" debian/control`
                        end

                        # Add dh-autoreconf to build dependency
                        deps << "dh-autoreconf"
                        `sed -i "s#^\\(^Build-Depends: .*\\)#\\1, #{deps.join(", ")}#" debian/control`

                        dpkg_commit_changes("deb_extra_dependencies")

                        Packager.info "Relaxing version requirement for: debhelper and gem2deb"
                        # Relaxing the required gem2deb version to allow for for multiplatform support
                        `sed -i "s#^\\(^Build-Depends: .*\\)gem2deb (>= [0-9\.~]\\+)\\(, .*\\)#\\1 gem2deb\\2#g" debian/control`
                        `sed -i "s#^\\(^Build-Depends: .*\\)debhelper (>= [0-9\.~]\\+)\\(, .*\\)#\\1 debhelper\\2#g" debian/control`
                        dpkg_commit_changes("relax_version_requirements")

                        Packager.info "Change to 'any' architecture"
                        `sed -i "s#Architecture: all#Architecture: any#" debian/control`
                        dpkg_commit_changes("any-architecture")

                        #-- e.g. for overlays use the original name in the control file
                        # which will be overwritten here
                        Packager.info "Adapt original package name if it exists"
                        original_name = debian_ruby_name(gem_base_name, false)
                        release_name = debian_ruby_name(gem_base_name, true)
                        # Avoid replacing parts of the release name, when it is already adapted
                        # rock-master-ruby-facets with ruby-facets
                        `sed -i "s##{release_name}##{original_name}#g" debian/*`
                        # Inject the true name
                        `sed -i "s##{original_name}##{release_name}#g" debian/*`
                        dpkg_commit_changes("adapt_original_package_name")

                        ################
                        # debian/rules
                        ################

                        # Injecting environment setup in debian/rules
                        # packages like orocos.rb will require locally installed packages

                        Packager.info "#{debian_ruby_name}: injecting enviroment variables into debian/rules"
                        Packager.debug "Allow custom rock name and installation path: #{rock_install_directory}"
                        Packager.debug "Enable custom rock name and custom installation path"
                        `sed -i '1 a env_setup += PATH=$(rock_install_dir)/bin:$(PATH)' debian/rules`
                        `sed -i '1 a env_setup += RUBYLIB=$(rock_install_dir)/lib/ruby/vendor_ruby' debian/rules`
                        `sed -i '1 a env_setup += Rock_DIR=$(rock_install_dir)/share/rock/cmake RUBY_CMAKE_INSTALL_PREFIX=#{File.join("debian",release_name)}$(rock_install_dir)' debian/rules`
                        `sed -i '1 a env_setup += PKG_CONFIG_PATH=$(rock_install_dir)/lib/pkgconfig:$(PKG_CONFIG_PATH)' debian/rules`
                        `sed -i '1 a rock_install_dir = #{rock_install_directory}' debian/rules`
                        `sed -i '1 a export DH_RUBY_INSTALL_PREFIX=#{rock_install_directory}' debian/rules`
                        `sed -i '1 a env_setup += Rock_DIR=$(rock_install_dir)/share/rock/cmake RUBY_CMAKE_INSTALL_PREFIX=#{File.join("debian",debian_ruby_name.gsub(/-[0-9\.]*$/,""))}$(rock_install_dir)' debian/rules`
                        `sed -i "s#\\(dh \\)#\\$(env_setup) \\1#" debian/rules`

                        # Ignore all ruby test results when the binary package is build (on the build server)
                        # via:
                        # dpkg-buildpackage -us -uc
                        #
                        # Thus uncommented line of
                        # export DH_RUBY_IGNORE_TESTS=all
                        Packager.debug "Disabling tests including ruby test result evaluation"
                        `sed -i 's/#\\(export DH_RUBY_IGNORE_TESTS=all\\)/\\1/' debian/rules`
                        # Add DEB_BUILD_OPTIONS=nocheck
                        # https://www.debian.org/doc/debian-policy/ch-source.html
                        `sed -i '1 a export DEB_BUILD_OPTIONS=nocheck' debian/rules`
                        dpkg_commit_changes("disable_tests")

                        ###################
                        # debian/changelog
                        #################################
                        # Any change of the version in the changelog file will directly affect the
                        # naming of the *.debian.tar.gz and the *.dsc file
                        #
                        # Subsequently also the debian package will be (re)named according to this
                        # version string.
                        #
                        # When getting an error such as '"ruby-utilrb_3.0.0.rc1-1.dsc" is already registered with different checksums'
                        # then you probably miss the distribution information or it is not correctly injected
                        if distribution
                            # Changelog entry initially, e.g.,
                            # ruby-activesupport (4.2.3-1) UNRELEASED; urgency=medium
                            #
                            # after
                            # ruby-activesupport (4.2.3-1~trusty) UNRELEASED; urgency=medium
                            if `sed -i 's#\(\\(.*\\)\)#\(\\1~#{distribution}\)#' debian/changelog`
                                Packager.info "Injecting distribution info: '~#{distribution}' into debian/changelog"
                            else
                                raise RuntimeError, "Failed to inject distribution information into debian/changelog"
                            end

                            # Make timestamp constant
                            # https://www.debian.org/doc/debian-policy/ch-source.html
                            #
                            date=`date --rfc-2822 --date="00:00:01"`
                            date=date.strip
                            if `sed -i 's#\\(.*<.*>  \\)\\(.*\\)#\\1#{date}#' debian/changelog`
                                Packager.info "Injecting timestamp info: '#{date}' into debian/changelog"
                            else
                                raise RuntimeError, "Failed to inject timestamp information into debian/changelog"
                            end

                            #FileUtils.cp "debian/changelog","/tmp/test-changelog"
                        end
                    end


                    # Build only a debian source package -- do not compile binary package
                    Packager.info "Building debian source package: #{debian_ruby_name}"
                    result = `dpkg-source -I -b #{debian_ruby_name}`
                    Packager.info "Resulting debian files: #{Dir.glob("**")} in #{Dir.pwd}"
                end
            end #end def

            def self.installable_ruby_versions
                version_file = File.join(local_tmp_dir,"ruby_versions")
                systems("apt-cache search ruby | grep -e '^ruby[0-9][0-9.]*-dev' | cut -d' ' -f1 > #{version_file}")
                ruby_versions = []
                File.open(version_file,"r") do |file|
                    ruby_versions = file.read.split("\n")
                end
                ruby_versions = ruby_versions.collect do |version|
                    version.gsub(/-dev/,"")
                end
                ruby_versions
            end

        end #end Debian
    end
end

