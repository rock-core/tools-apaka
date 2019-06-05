require 'find'
require 'tmpdir'
require 'utilrb'
require 'timeout'
require 'time'
require 'open3'
require_relative 'debiancontrol'
require_relative 'packageinfo'
require_relative 'gem_dependencies'

module Apaka
    module Packaging
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
            TEMPLATES = File.expand_path(File.join("templates", "debian"), __dir__)
            TEMPLATES_META = File.expand_path(File.join("templates", "debian-meta"), __dir__)
            DEPWHITELIST = ["debhelper","gem2deb","ruby","ruby-rspec"]
            DEBHELPER_DEFAULT_COMPAT_LEVEL = 9

            attr_reader :existing_debian_directories

            # install directory if not given set to /opt/rock
            attr_accessor :rock_base_install_directory
            attr_reader :rock_release_name
            # The pkg prefix base name, e.g., rock in rock-ruby-master-18.01,
            attr_reader :pkg_prefix_base

            # List of alternative rake target names to clean a gem
            attr_accessor :gem_clean_alternatives
            # List of alternative rake target names to create a gem
            attr_accessor :gem_creation_alternatives
            # List of alternative rake and rdoc commands to generate a gems docs
            attr_accessor :gem_doc_alternatives

            # List of extra rock packages to depend on, by build type
            # For example, :orogen build_type requires orogen from rock.
            attr_accessor :rock_autobuild_deps

            attr_reader :rock_release_platform
            attr_reader :rock_release_hierarchy

            def initialize(options = Hash.new)
                super(options)

                @debian_version = Hash.new
                @rock_base_install_directory = "/opt/rock"
                @pkg_prefix_base = "rock"

                # Rake targets that will be used to clean and create
                # gems
                @gem_clean_alternatives = ['clean','dist:clean','clobber']
                @gem_creation_alternatives = ['gem','dist:gem','build']
                # Rake and rdoc commands to try to create documentation
                @gem_doc_alternatives = ['rake docs','rake dist:docs','rake doc','rake dist:doc', 'rdoc']
                @rock_autobuild_deps = { :orogen => [], :cmake => [], :autotools => [], :ruby => [], :archive_importer => [], :importer_package => [] }

                rock_release_name = "release-#{Time.now.strftime("%y.%m")}"
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

            # The debian name of a package -- either
            # rock[-<release-name>]-<canonized-package-name>
            # or for ruby packages
            # rock[-<release-name>]-ruby-<canonized-package-name>
            # and the release-name can be avoided by setting
            # with_rock_release_prefix to false
            #
            def debian_name(pkginfo, with_rock_release_prefix = true, release_name = nil)
                if pkginfo.kind_of?(String)
                    raise ArgumentError, "method debian_name expects a PackageInfo as argument, got: #{pkginfo.class} '#{pkginfo}'"
                end
                name = pkginfo.name

                if pkginfo.build_type == :ruby
                    if with_rock_release_prefix
                        rock_release_prefix(release_name) + "ruby-" + canonize(name)
                    else
                        pkg_prefix_base + "-ruby-" + canonize(name)
                    end
                else
                    if with_rock_release_prefix
                        rock_release_prefix(release_name) + canonize(name)
                    else
                        pkg_prefix_base + "-" + canonize(name)
                    end
                end
            end

            # The debian name of a meta package --
            # rock[-<release-name>]-<canonized-package-name>
            # and the release-name can be avoided by setting
            # with_rock_release_prefix to false
            #
            def debian_meta_name(name, with_rock_release_prefix = true)
                if with_rock_release_prefix
                    rock_release_prefix + canonize(name)
                else
                    pkg_prefix_base + "-" + canonize(name)
                end
            end

            # Get the current rock-release-based prefix for rock packages
            def rock_release_prefix(release_name = nil)
                release_name ||= rock_release_name
                pkg_prefix_base + "-#{release_name}-"
            end

            # Get the current rock-release-based prefix for rock-(ruby) packages
            def rock_ruby_release_prefix(release_name = nil)
                rock_release_prefix(release_name) + "ruby-"
            end

            # The debian name of a package
            # [rock-<release-name>-]ruby-<canonized-package-name>
            # and the release-name prefix can be avoided by setting
            # with_rock_release_prefix to false
            #
            def debian_ruby_name(name, with_rock_release_prefix = true, release_name = nil)
                if with_rock_release_prefix
                    rock_ruby_release_prefix(release_name) + canonize(name)
                else
                    "ruby-" + canonize(name)
                end
            end

            def debian_version(pkginfo, distribution, revision = "1")
                if !@debian_version.has_key?(pkginfo.name)
                    v = pkginfo.description_version
                    @debian_version[pkginfo.name] = v + "." + pkginfo.latest_commit_time.strftime("%Y%m%d") + "-" + revision
                    if distribution
                        @debian_version[pkginfo.name] += '~' + distribution
                    end
                end
                @debian_version[pkginfo.name]
            end

            def debian_plain_version(pkginfo)
                pkginfo.description_version + "." + pkginfo.latest_commit_time.strftime("%Y%m%d")
            end

            def versioned_name(pkginfo, distribution)
                debian_name(pkginfo) + "_" + debian_version(pkginfo, distribution)
            end

            def plain_versioned_name(pkginfo)
                debian_name(pkginfo) + "_" + debian_plain_version(pkginfo)
            end

            def plain_dir_name(pkginfo)
                plain_versioned_name(pkginfo)
            end

            def packaging_dir(pkginfo)
                pkg_name = pkginfo
                if !pkginfo.kind_of?(String)
                    pkg_name = debian_name(pkginfo)
                end
                File.join(@build_dir, pkg_name, target_platform.to_s.gsub("/","-"))
            end

            def rock_install_directory
                File.join(rock_base_install_directory, rock_release_name)
            end

            def rock_release_name=(name)
                if name !~ /^[a-zA-Z][a-zA-Z0-9\-\.]+$/
                    raise ArgumentError, "Debian: given release name '#{name}' has an " \
                                "invalid pattern.\nPlease start with single letter followed by " \
                                "alphanumeric characters and dash(-) and dot(.), e.g., my-release-18.01"
                end

                @rock_release_name = name
                @rock_release_platform = TargetPlatform.new(name, target_platform.architecture)
                @rock_release_hierarchy = [name]
                if Config.rock_releases.has_key?(name)
                    release_hierarchy = Config.rock_releases[name][:depends_on].select do |release_name|
                        TargetPlatform.isRock(release_name)
                    end
                    # Add the actual release name as first
                    @rock_release_hierarchy += release_hierarchy
                end
            end

            # Update the automatically generated osdeps list for a given
            # package
            def update_osdeps_lists(pkginfo, osdeps_files_dir)
                Packager.info "Update osdeps lists in #{osdeps_files_dir} for #{pkginfo}"
                if !File.exist?(osdeps_files_dir)
                    Packager.debug "Creating #{osdeps_files_dir}"
                    FileUtils.mkdir_p osdeps_files_dir
                else
                    Packager.debug "#{osdeps_files_dir} already exists"
                end

                Dir.chdir(osdeps_files_dir) do
                    Packaging::Config.active_configurations.each do |release,arch|
                        selected_platform = TargetPlatform.new(release, arch)
                        file = File.absolute_path("#{rock_release_name}-#{arch}.yml")
                        update_osdeps_list(pkginfo, file, selected_platform)
                    end
                end
            end

            def update_osdeps_list(pkginfo, file, selected_platform)
                Packager.info "Update osdeps list for: #{selected_platform} -- in file #{file}"

                list = Hash.new
                if File.exist? file
                    Packager.info("Packagelist #{file} already exists: reloading")
                    list = YAML.load_file(file)
                end

                pkg_name = nil
                dependency_debian_name = nil
                is_osdep = nil
                if pkginfo.is_a? String
                    # Handling of ruby and other gems
                    pkg_name = pkginfo
                    release_name, is_osdep = native_dependency_name(pkg_name, selected_platform)
                    Packager.debug "Native dependency of ruby package: '#{pkg_name}' -- #{release_name}, is available as osdep: #{is_osdep}"
                    dependency_debian_name = release_name
                else
                    pkg_name = pkginfo.name
                    # Handling of rock packages
                    dependency_debian_name = debian_name(pkginfo)
                end

                if !is_osdep
                    if !reprepro_has_package?(dependency_debian_name, rock_release_name,
                                              selected_platform.distribution_release_name,
                                              selected_platform.architecture)

                        Packager.warn "Package #{dependency_debian_name} is not available for #{selected_platform} in release #{rock_release_name} -- not added to osdeps file"
                        return
                    end
                else
                    Packager.info "Package #{dependency_debian_name} will be provided through an osdep for #{selected_platform}"
                end

                # Get the operating system label
                types, labels = Config.linux_distribution_releases[selected_platform.distribution_release_name]
                types_string = types.join(",")
                labels_string = labels.join(",")

                Packager.debug "Existing definition: #{list[pkg_name]}"
                pkg_definition = list[pkg_name] || Hash.new
                distributions = pkg_definition[types_string] || Hash.new
                distributions[labels_string] = dependency_debian_name
                pkg_definition[types_string] = distributions

                list[pkg_name] = pkg_definition
                Packager.debug "New definition: #{list[pkg_name]}"

                Packager.debug "Updating osdeps file: #{file} with #{pkg_name} -- #{pkg_definition}"
                File.open(file, 'w') {|f| f.write list.to_yaml }
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
                    system("dpkg-source", "--commit", ".", patch_name, :close_others => true)
                end
            end

            def filter_all_required_packages(packages)
                all_pkginfos = packages[:pkginfos]
                sorted_gem_list = packages[:gems]
                exact_version_list = packages[:gem_versions]

                # Filter all packages that are available
                if rock_release_name
                    all_pkginfos = all_pkginfos.select do |pkginfo|
                        pkg_name = debian_name(pkginfo, true || with_prefix)
                        !rock_release_platform.ancestorContains(pkg_name)
                    end

                    sorted_gem_list = sorted_gem_list.select do |gem|
                        with_prefix = true
                        pkg_ruby_name = debian_ruby_name(gem, !with_prefix)
                        pkg_prefixed_name = debian_ruby_name(gem, with_prefix)

                        !( rock_release_platform.ancestorContains(gem) ||
                          rock_release_platform.ancestorContains(pkg_ruby_name) ||
                          rock_release_platform.ancestorContains(pkg_prefixed_name))
                    end
                end
                {:pkginfos => all_pkginfos, :gems => sorted_gem_list, :gem_versions => exact_version_list, :extra_gems => packages[:extra_gems], :extra_osdeps => packages[:extra_osdeps] }
            end

            # Compute all recursive dependencies for a given package
            #
            # return the complete list of dependencies required for a package with the given name
            # During removal of @osdeps, @ruby_gems, it was assumed this
            # function is not supposed to affect those.
            def recursive_dependencies(pkginfo)

                all_required_pkginfos = pkginfo.required_rock_packages

                all_recursive_deps = {:rock => [], :osdeps => [], :nonnative => [], :extra_gems => []}
                all_required_pkginfos.each do |pkginfo|
                    pdep = filtered_dependencies(pkginfo)
                    pdep.keys.each do |k|
                        all_recursive_deps[k].concat pdep[k]
                    end
                end
                all_recursive_deps.each_value { |a| a.uniq! }

                if !all_recursive_deps[:nonnative].empty?
                    all_recursive_deps[:nonnative] = GemDependencies::resolve_all(all_recursive_deps[:nonnative])
                end
                recursive_deps = all_recursive_deps.values.flatten.uniq
            end

            # returns debian package names of dependencies
            def filtered_dependencies(pkginfo, with_rock_release_prefix = true)
                this_rock_release = TargetPlatform.new(rock_release_name, target_platform.architecture)

                deps_rock_pkginfos = pkginfo.dependencies[:rock_pkginfo].dup
                deps_osdeps_packages = pkginfo.dependencies[:osdeps].dup
                non_native_dependencies = pkginfo.dependencies[:nonnative].dup
                if target_platform.distribution_release_name
                    # CASTXML vs. GCCXML in typelib
                    if pkginfo.name =~ /typelib$/
                        # add/remove the optional dependencies on the
                        # rock-package depending on the target platform
                        # there are typelib versions with and without the
                        # optional depends. we know which platform requires
                        # a particular dependency.
                        deps_rock_pkginfos.delete_if do |pkginfo|
                            pkginfo.name == "castxml" || pkginfo.name == "gccxml"
                        end

                        if target_platform.contains("castxml")
                            deps_osdeps_packages.push("castxml")
                        elsif target_platform.contains("gccxml")
                            #todo: these need to checked on the other platforms
                            deps_osdeps_packages.push("gccxml")
                        else
                            raise ArgumentError, "TargetPlatform: #{target_platform} does neither support castxml nor gccml - cannot build typelib"
                        end
                    end

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
                        # os dependencies, otherwise it triggers further resolution of nonnative packages
                        # which cannot exist (in resolve_all)
                        if is_osdep || with_rock_release_prefix
                            deps_osdeps_packages << dep_name
                            nil
                        else
                            name
                        end
                    end.compact
                end

                deps_rock_packages = deps_rock_pkginfos.map do |pkginfo|
                    debian_name = debian_name(pkginfo, with_rock_release_prefix)
                    this_rock_release.packageReleaseName(debian_name)
                end.sort

                Packager.info "'#{pkginfo.name}' with (available) rock package dependencies: '#{deps_rock_packages}'"
                Packager.info "'#{pkginfo.name}' with (available) osdeps dependencies: '#{deps_osdeps_packages}'"

                # Return rock packages, osdeps and non native deps (here gems)
                {:rock => deps_rock_packages, :osdeps => deps_osdeps_packages, :nonnative => non_native_dependencies }
            end

            # Check if the plain package name exists in the target (ubuntu/debian) distribution or any ancestor (rock) distributions
            # and identify the correct package name
            # return [String,bool] Name of the dependency and whether this is an osdep dependency or not
            def native_dependency_name(name, selected_platform = nil)
                if !selected_platform
                    selected_platform = target_platform
                end

                # Identify this rock release and its ancestors
                this_rock_release = TargetPlatform.new(rock_release_name, selected_platform.architecture)

                if name.is_a? String
                    # Check for 'plain' name, the 'unprefixed' name and for the 'release' name
                    if this_rock_release.ancestorContains(name) ||
                       selected_platform.contains(name)
                        # direct name match always is an os dependency
                        # it can never be in a rock release
                        return [name, true]
                    end

                    # try debian naming scheme for ruby
                    if this_rock_release.ancestorContains("ruby-#{canonize(name)}") ||
                       selected_platform.contains("ruby-#{canonize(name)}")
                        return ["ruby-#{canonize(name)}", true]
                    end

                    # otherwise, ask for the ancestor that contains a rock ruby
                    # package
                    ancestor_release_name = this_rock_release.releasedInAncestor(
                        debian_ruby_name(name, true, this_rock_release.distribution_release_name)
                    )
                    if !ancestor_release_name.empty?
                        return [debian_ruby_name(name, true, ancestor_release_name), false]
                    end

                    # Return the 'release' name, since no other source provides this package
                    [debian_ruby_name(name, true), false]
                else
                    # ask for the ancestor that contains a rock ruby
                    # package
                    ancestor_release = this_rock_release.releasedInAncestor(
                        debian_name(name, true, this_rock_release.distribution_release_name)
                    )
                    if !ancestor_release.empty?
                        return [debian_name(name, true, ancestor_release_name), false]
                    end

                    # Return the 'release' name, since no other source provides this package
                    [debian_name(name, true), false]
                end
            end

            def generate_debian_dir(pkginfo, dir, options)
                options, unknown_options = Kernel.filter_options options,
                    :distribution => nil,
                    :override_existing => true,
                    :patch_dir => nil

                distribution = options[:distribution]
                Dir.chdir(dir) do
                    # Check if a debian directory exists
                    dirs = Dir.glob("debian")
                    if options[:override_existing]
                        dirs.each do |d|
                            Packager.info "Removing existing debian directory: #{d} -- in #{Dir.pwd}"
                            FileUtils.rm_rf d
                        end
                    end

                    dirs = Dir.glob("**/.*")
                    if options[:override_existing]
                        dirs.each do |d|
                            Packager.info "Removing existing hidden files: #{d} -- in #{Dir.pwd}"
                            FileUtils.rm_rf d
                        end
                    end
                end
                dir = File.join(dir, "debian")

                existing_debian_dir = File.join(pkginfo.srcdir,"debian")
                template_dir =
                    if File.directory?(existing_debian_dir)
                        existing_debian_dir
                    else
                        TEMPLATES
                    end

                FileUtils.mkdir_p dir
                package_info = pkginfo
                debian_name = debian_name(pkginfo)
                debian_version = debian_version(pkginfo, distribution)
                versioned_name = versioned_name(pkginfo, distribution)
                short_documentation = pkginfo.short_documentation
                documentation = pkginfo.documentation
                origin_information = pkginfo.origin_information

                deps = filtered_dependencies(pkginfo)
                #debian names of rock packages
                deps_rock_packages = deps[:rock]
                deps_osdeps_packages = deps[:osdeps]
                deps_nonnative_packages = deps[:nonnative].to_a.flatten.compact

                dependencies = (deps_rock_packages + deps_osdeps_packages + deps_nonnative_packages).flatten
                build_dependencies = dependencies.dup

                this_rock_release = TargetPlatform.new(rock_release_name, target_platform.architecture)
                @rock_autobuild_deps[pkginfo.build_type].each do |pkginfo|
                    name = debian_name(pkginfo)
                    build_dependencies << this_rock_release.packageReleaseName(name)
                end
                if pkginfo.build_type == :cmake
                    build_dependencies << "cmake"
                elsif pkginfo.build_type == :orogen
                    build_dependencies << "cmake"
                    orogen_command = pkginfo.orogen_command
                elsif pkginfo.build_type == :autotools
                    if pkginfo.using_libtool
                        build_dependencies << "libtool"
                    end
                    build_dependencies << "autotools-dev" # as autotools seems to be virtual...
                    build_dependencies << "autoconf"
                    build_dependencies << "automake"
                    build_dependencies << "dh-autoreconf"
                elsif pkginfo.build_type == :ruby
                    if pkginfo.name =~ /bundles/
                        build_dependencies << "cmake"
                    else
                        raise "debian/control: cannot handle ruby package"
                    end
                elsif pkginfo.build_type == :archive_importer || pkginfo.build_type == :importer_package
                    build_dependencies << "cmake"
                else
                    raise "debian/control: cannot handle package type #{pkginfo.build_type} for #{pkginfo.name}"
                end

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

                if options[:patch_dir] && File.exist?(options[:patch_dir])
                    whitelist = [ "debian/rules","debian/control","debian/install" ]
                    if patch_pkg_dir(pkginfo.name, options[:patch_dir], whitelist, pkginfo.srcdir)
                        Packager.warn "Overlay patch applied to debian folder of #{pkginfo.name}"
                    end
                end

                ########################
                # debian/compat
                ########################
		set_compat_level(DEBHELPER_DEFAULT_COMPAT_LEVEL, File.join(pkginfo.srcdir,"debian/compat"))
            end

            def generate_debian_dir_meta(name, depends, options)
                options, unknown_options = Kernel.filter_options options,
                    :distribution => nil

                distribution = options[:distribution]

                existing_debian_dir = File.join("#{name}-0.1","debian-meta")
                template_dir =
                    if File.directory?(existing_debian_dir)
                        existing_debian_dir
                    else
                        TEMPLATES_META
                    end

                dir = File.join("#{name}-0.1", "debian")
                FileUtils.mkdir_p dir
                debian_name = debian_meta_name(name)
                debian_version = "0.1"
                if distribution
                  debian_version += '~' + distribution
                end
#                versioned_name = versioned_name(pkg, distribution)

                with_rock_prefix = true
                deps_rock_packages = depends
                deps_osdeps_packages = []
                deps_nonnative_packages = []
                package = nil

                Packager.info "Required OS Deps: #{deps_osdeps_packages}"
                Packager.info "Required Nonnative Deps: #{deps_nonnative_packages}"

                Find.find(template_dir) do |path|
                    next if File.directory?(path)
                    template = ERB.new(File.read(path), nil, "%<>", path.gsub(/[^w]/, '_'))
                    begin
                        rendered = template.result(binding)
                    rescue
                        puts "Error in #{path}:"
                        raise
                    end

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
            def tar_gzip(archive, tarfile, pkg_time, distribution = nil)

                # Make sure no distribution information leaks into the package
                if distribution and archive =~ /~#{distribution}/
                    archive_plain_name = archive.gsub(/~#{distribution}/,"")
                    FileUtils.cp_r archive, archive_plain_name
                else
                    archive_plain_name = archive
                end


                Packager.info "Tar archive: #{archive_plain_name} into #{tarfile}"
                # Make sure that the tar files checksum remains the same by
                # overriding the modification timestamps in the tarball with
                # some external source timestamp and using gzip --no-name
                #
                # exclude hidden files an directories
                mtime = pkg_time.iso8601()
                # Exclude hidden files and directories at top level
                cmd_tar = "tar --mtime='#{mtime}' --format=gnu -c --exclude '.+' --exclude-backups --exclude-vcs --exclude #{archive_plain_name}/debian --exclude build #{archive_plain_name} | gzip --no-name > #{tarfile}"

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
            def package(pkginfo, options = Hash.new)
                options, unknown_options = Kernel.filter_options options,
                    :force_update => false,
                    :patch_dir => nil,
                    :distribution => nil, # allow to override global settings
                    :architecture => nil

                if options[:force_update]
                    dirname = packaging_dir(pkginfo)
                    if File.directory?(dirname)
                        Packager.info "Debian: rebuild requested -- removing #{dirname}"
                        FileUtils.rm_rf(dirname)
                    end
                end

                options[:distribution] ||= target_platform.distribution_release_name
                options[:architecture] ||= target_platform.architecture
                options[:packaging_dir] = packaging_dir(pkginfo)

                pkginfo = prepare_source_dir(pkginfo, options.merge(unknown_options))

                if pkginfo.build_type == :orogen || pkginfo.build_type == :cmake || pkginfo.build_type == :autotools
                    package_deb(pkginfo, options)
                elsif pkginfo.build_type == :ruby
                    # Import bundles since they do not need to be build and
                    # they do not follow the typical structure required for gem2deb
                    if pkginfo.name =~ /bundles/
                        package_importer(pkginfo, options)
                    else
                        package_ruby(pkginfo, options)
                    end
                elsif pkginfo.build_type == :archive_importer || pkginfo.build_type == :importer_package
                    package_importer(pkginfo, options)
                else
                    raise ArgumentError, "Debian: Unsupported package type #{pkginfo.build_type} for #{pkginfo.name}"
                end
            end

            # Package the given meta package
            # if an existing source directory is given this will be used
            # for packaging, otherwise the package will be bootstrapped
            def package_meta(name, depend, options = Hash.new)
                options, unknown_options = Kernel.filter_options options,
                    :force_update => false,
                    :distribution => nil, # allow to override global settings
                    :architecture => nil

                debian_pkg_name = debian_meta_name(name)

                if options[:force_update]
                    dirname = packaging_dir(debian_pkg_name)
                    if File.directory?(dirname)
                        Packager.info "Debian: rebuild requested -- removing #{dirname}"
                        FileUtils.rm_rf(dirname)
                    end
                end

                options[:distribution] ||= target_platform.distribution_release_name
                options[:architecture] ||= target_platform.architecture
                pkg_dir = packaging_dir(debian_pkg_name)
                options[:packaging_dir] = pkg_dir

                if not File.directory?(pkg_dir)
                    FileUtils.mkdir_p pkg_dir
                end

                package_deb_meta(name, depend, options)
            end

            # Create an deb package of an existing ruby package
            def package_ruby(pkginfo, options)
                Packager.info "Package Ruby: '#{pkginfo.name}' with options: #{options}"

                # update dependencies in any case, i.e. independant if package exists or not
                deps = pkginfo.dependencies
                Dir.chdir(pkginfo.srcdir) do
                    begin
                        logname = "package-ruby-#{pkginfo.name.sub("/","-")}" + "-" + Time.now.strftime("%Y%m%d-%H%M%S").to_s + ".log"
                        gem = FileList["pkg/*.gem"].first
                        if not gem
                            Packager.info "Debian: preparing gem generation in #{Dir.pwd}"

                            # Rake targets that should be tried for cleaning
                            gem_clean_success = false
                            @gem_clean_alternatives.each do |target|
                                if !system(pkginfo.env, "rake", target, [ :out, :err ] => File.join(log_dir, logname), :close_others => true)
                                    Packager.info "Debian: failed to clean package '#{pkginfo.name}' using target '#{target}'"
                                else
                                    Packager.info "Debian: succeeded to clean package '#{pkginfo.name}' using target '#{target}'"
                                    gem_clean_success = true
                                    break
                                end
                            end
                            if not gem_clean_success
                                Packager.warn "Debian: failed to cleanup ruby package '#{pkginfo.name}' -- continuing without cleanup"
                            end

                            Packager.info "Debian: ruby package Manifest.txt is being autogenerated"
                            Debian::generate_manifest_txt()

                            Packager.info "Debian: creating gem from package #{pkginfo.name} [#{File.join(log_dir, logname)}]"

                            if patch_pkg_dir(pkginfo.name, options[:patch_dir], ["*.gemspec", "Rakefile", "metadata.yml"])
                                Packager.info "Patched build files for ruby package before gem building: #{pkginfo.name}"
                            end

                            # Allowed gem creation alternatives
                            gem_creation_success = false

                            # Gemspec often use the 'git ls -z' listings, which
                            # might break if hidden files will be removed
                            # without commiting -- so temporarily add and revert
                            # again, to maintain the original commit id
                            # TBD: or leave the commit and list the last N commits in the changelog
                            Packager.info "Debian: temporarily commit changes in #{Dir.pwd}"
                            _,_,git_add_status = Open3.capture3("git add -A")
                            msg,git_commit_status = Open3.capture2("git commit -m 'Apaka: gem creation' --author 'Apaka Packager, <apaka@autocommit>'")
                            if !git_commit_status.success?
                                Packager.info "Debian: commit failed: #{msg}"
                            end
                            @gem_creation_alternatives.each do |target|
                                if !system(pkginfo.env, "rake", target, [ :out, :err ] => [ File.join(log_dir, logname), "a"], :close_others => true)
                                    Packager.info "Debian: failed to create gem using target '#{target}' -- #{pkginfo.env}"
                                else
                                    Packager.info "Debian: succeeded to create gem using target '#{target}'"
                                    gem_creation_success = true
                                    break
                                end
                            end
                            if git_commit_status.success?
                                Packager.info "Debian: git package status"
                                msg, git_revert = Open3.capture2("git reset --soft HEAD~1")
                                Packager.info "Debian: reversion of temporary commit failed"
                            end
                            if not gem_creation_success
                                raise RuntimeError, "Debian: failed to create gem from RubyPackage #{pkginfo.name}"
                            end
                        end

                        gem = FileList["pkg/*.gem"].first

                        # Make the naming of the gem consistent with the naming schema of
                        # rock packages
                        #
                        # Make sure the gem has the fullname, e.g.
                        # tools-metaruby instead of just metaruby
                        Packager.info "Debian: '#{pkginfo.name}' -- basename: #{basename(pkginfo.name)} will be canonized to: #{canonize(pkginfo.name)}"
                        gem_rename = gem.sub(basename(pkginfo.name), canonize(pkginfo.name))
                        if gem != gem_rename
                            Packager.info "Debian: renaming #{gem} to #{gem_rename}"
                        end

                        Packager.info "Debian: copy #{File.join(Dir.pwd, gem)} to #{packaging_dir(pkginfo)}"
                        gem_final_path = File.join(packaging_dir(pkginfo), File.basename(gem_rename))
                        FileUtils.cp gem, gem_final_path

                        # Prepare injection of dependencies through options
                        # provide package name to allow consistent patching schema
                        options[:deps] = deps
                        options[:local_pkg] = true
                        options[:package_name] = pkginfo.name
                        options[:latest_commit_time] = pkginfo.latest_commit_time
                        options[:recursive_deps] = recursive_dependencies(pkginfo)

                        convert_gem(gem_final_path, options)
                    rescue Exception => e
                        raise RuntimeError, "Debian: failed to create gem from RubyPackage #{pkginfo.name} -- #{e.message}\n#{e.backtrace.join("\n")}"
                    end
                end
            end

            def self.generate_manifest_txt(directory = Dir.pwd)
                manifest_file = "Manifest.txt"
                if File.exist?(manifest_file)
                    FileUtils.rm manifest_file
                end
                Dir.glob("**/**") do |file|
                    if File.file?(file)
                        IO::write(manifest_file, "#{file}\n", :mode => "a")
                    end
                end
            end

            def package_deb(pkginfo, options)
                Packager.info "Package Deb: '#{pkginfo.name}' with options: #{options}"

                options, unknown_options = Kernel.filter_options options,
                    :patch_dir => nil,
                    :distribution => nil,
                    :architecture => nil

                distribution = options[:distribution]

                Packager.info "Changing into packaging dir: #{packaging_dir(pkginfo)}"
                Dir.chdir(packaging_dir(pkginfo)) do
                    sources_name = plain_versioned_name(pkginfo)
                    # First, generate the source tarball
                    tarball = "#{sources_name}.orig.tar.gz"

                    if options[:patch_dir] && File.exist?(options[:patch_dir])
                        if patch_pkg_dir(pkginfo.name, options[:patch_dir], nil, pkginfo.srcdir)
                            Packager.warn "Overlay patch applied to #{pkginfo.name}"
                        end
                    end

                    # Check first if actual source contains newer information than existing
                    # orig.tar.gz -- only then we create a new debian package
                    package_with_update = false
                    if package_updated?(pkginfo)

                        Packager.warn "Package: #{pkginfo.name} requires update #{pkginfo.srcdir}"

                        if !tar_gzip(File.basename(pkginfo.srcdir), tarball, pkginfo.latest_commit_time, distribution)
                            raise RuntimeError, "Debian: #{pkginfo.name} failed to create archive"
                        end
                        package_with_update = true
                    end

                    dsc_files = reprepro_registered_files(versioned_name(pkginfo, distribution),
                                              rock_release_name,
                                              "*#{target_platform.distribution_release_name}.dsc")

                    if package_with_update || dsc_files.empty?
                        # Generate the debian directory
                        generate_debian_dir(pkginfo, pkginfo.srcdir, options)

                        # Run dpkg-source
                        # Use the new tar ball as source
                        if !system("dpkg-source", "-I", "-b", pkginfo.srcdir, :close_others => true)
                            Packager.warn "Package: #{pkginfo.name} failed to perform dpkg-source -- #{Dir.entries(pkginfo.srcdir)}"
                            raise RuntimeError, "Debian: #{pkginfo.name} failed to perform dpkg-source in #{pkginfo.srcdir}"
                        end
                        ["#{versioned_name(pkginfo, distribution)}.debian.tar.gz",
                         "#{plain_versioned_name(pkginfo)}.orig.tar.gz",
                         "#{versioned_name(pkginfo, distribution)}.dsc"]
                    else
                        Packager.info "Package: #{pkginfo.name} is up to date"
                    end
                    FileUtils.rm_rf( File.basename(pkginfo.srcdir) )
                end
            end

            def package_deb_meta(name, depend, options)
                Packager.info "Package Deb meta: '#{name}' with options: #{options}"

                options, unknown_options = Kernel.filter_options options,
                    :patch_dir => nil,
                    :distribution => nil,
                    :architecture => nil,
                    :packaging_dir => nil
                distribution = options[:distribution]

                Packager.info "Changing into packaging dir: #{options[:packaging_dir]}"
                #todo: no pkg.
                Dir.chdir(options[:packaging_dir]) do
                    # Generate the debian directory as a subdirectory of meta

                    generate_debian_dir_meta(name, depend, options)

                    # Run dpkg-source
                    # Use the new tar ball as source
                    if !system("dpkg-source", "-I", "-b", "#{name}-0.1", :close_others => true)
                        Packager.warn "Package: #{name} failed to perform dpkg-source -- #{Dir.entries("meta")}"
                        raise RuntimeError, "Debian: #{name} failed to perform dpkg-source in meta"
                    end
                    ["#{name}.debian.tar.gz",
                     "#{name}.orig.tar.gz",
                     "#{name}.dsc"]
                end
            end

            def package_importer(pkginfo, options)
                Packager.info "Using package_importer for #{pkginfo.name}"
                options, unknown_options = Kernel.filter_options options,
                    :distribution => nil,
                    :architecture => nil
                distribution = options[:distribution]

                Dir.chdir(packaging_dir(pkginfo)) do

                    dir_name = plain_versioned_name(pkginfo)
                    plain_dir_name = plain_versioned_name(pkginfo)
                    FileUtils.rm_rf File.join(pkginfo.srcdir, "debian")
                    FileUtils.rm_rf File.join(pkginfo.srcdir, "build")

                    # Generate a CMakeLists which installs every file
                    cmake = File.new(dir_name + "/CMakeLists.txt", "w+")
                    cmake.puts "cmake_minimum_required(VERSION 2.6)"
                    add_folder_to_cmake "#{Dir.pwd}/#{dir_name}", cmake, pkginfo.name
                    cmake.close

                    # First, generate the source tarball
                    sources_name = plain_versioned_name(pkginfo)
                    tarball = "#{plain_dir_name}.orig.tar.gz"

                    # Check first if actual source contains newer information than existing
                    # orig.tar.gz -- only then we create a new debian package
                    package_with_update = false
                    if package_updated?(pkginfo)

                        Packager.warn "Package: #{pkginfo.name} requires update #{pkginfo.srcdir}"

                        source_package_dir = File.basename(pkginfo.srcdir)
                        if !tar_gzip(source_package_dir, tarball, pkginfo.latest_commit_time)
                            raise RuntimeError, "Package: failed to tar directory #{source_package_dir}"
                        end
                        package_with_update = true
                    end

                    dsc_files = reprepro_registered_files(versioned_name(pkginfo, distribution),
                                              rock_release_name,
                                              "*#{target_platform.distribution_release_name}.dsc")

                    if package_with_update || dsc_files.empty?
                        # Generate the debian directory
                        generate_debian_dir(pkginfo, pkginfo.srcdir, options)

                        # Commit local changes, e.g. check for
                        # control/urdfdom as an example
                        dpkg_commit_changes("local_build_changes", pkginfo.srcdir)

                        # Run dpkg-source
                        # Use the new tar ball as source
                        Packager.info `dpkg-source -I -b #{pkginfo.srcdir}`
                        if !system("dpkg-source", "-I", "-b", pkginfo.srcdir, :close_others => true)
                            Packager.warn "Package: #{pkginfo.name} failed to perform dpkg-source: entries #{Dir.entries(pkginfo.srcdir)}"
                            raise RuntimeError, "Debian: #{pkginfo.name} failed to perform dpkg-source in #{pkginfo.srcdir}"
                        end
                        ["#{versioned_name(pkginfo, distribution)}.debian.tar.gz",
                         "#{plain_versioned_name(pkginfo)}.orig.tar.gz",
                         "#{versioned_name(pkginfo, distribution)}.dsc"]
                    else
                        Packager.info "Package: #{pkginfo.name} is up to date"
                    end
                end
            end

            def build_local_gem(gem_name, options)
                gem_version = nil
                debian_package_name = rock_ruby_release_prefix + gem_name

                # Find gem version
                Find.find(File.join(build_dir,debian_package_name,"/")).each do |file|
                    if FileTest.directory?(file)
                        if File.basename(file)[0] == ?.
                            Find.prune
                        end
                    end
                    if file.end_with? ".gem"
                        gem_version = File.basename(file).sub(gem_name + '-', '').sub('.gem', '')
                        break
                    end
                end

                versioned_build_dir = debian_package_name + '-' + gem_version
                deb_filename = "#{versioned_build_dir}.deb"
                build_local(gem_name, debian_package_name, versioned_build_dir, deb_filename, options)
            end

            def build_local_package(pkginfo, options)
                #pkg_name is only used for progress messages
                pkg_name = pkginfo.name
                versioned_build_dir = plain_versioned_name(pkginfo)
                deb_filename = "#{plain_versioned_name(pkginfo)}_ARCHITECTURE.deb"

                options[:parallel_build_level] = pkginfo.parallel_build_level
                build_local(pkg_name, debian_name(pkginfo), versioned_build_dir, deb_filename, options)
            end

            # Build package locally
            # return path to locally build file
            def build_local(pkg_name, debian_pkg_name, versioned_build_dir, deb_filename, options)
                options, unknown_options = Kernel.filter_options options,
                    :distributions => nil,
                    :parallel_build_level => nil
                filepath = build_dir
                # cd package_name
                # tar -xf package_name_0.0.debian.tar.gz
                # tar -xf package_name_0.0.orig.tar.gz
                # mv debian/ package_name_0.0/
                # cd package_name_0.0/
                # debuild -us -uc
                # #to install
                # cd ..
                # sudo dpkg -i package_name_0.0.deb
                Packager.info "Building #{pkg_name} locally with arguments: pkg_name #{pkg_name}," \
                    " debian_pkg_name #{debian_pkg_name}," \
                    " versioned_build_dir #{versioned_build_dir}" \
                    " deb_filename #{deb_filename}" \
                    " options #{options}"

                begin
                    FileUtils.chdir File.join(build_dir, debian_pkg_name, target_platform.to_s.gsub("/","-")) do
                        if File.exist? "debian"
                            FileUtils.rm_rf "debian"
                        end
                        if File.exist? versioned_build_dir
                            FileUtils.rm_rf versioned_build_dir
                        end
                        FileUtils.mkdir versioned_build_dir

                        debian_tar_gz = Dir.glob("*.debian.tar.gz")
                        debian_tar_gz.concat Dir.glob("*.debian.tar.xz")
                        if debian_tar_gz.empty?
                            raise RuntimeError, "#{self} could not find file: *.debian.tar.gz in #{Dir.pwd}"
                        else
                            debian_tar_gz = debian_tar_gz.first
                            cmd = ["tar", "-xf", debian_tar_gz]
                            if !system(*cmd, :close_others => true)
                                 raise RuntimeError, "Packager: '#{cmd.join(" ")}' failed"
                            end
                        end

                        orig_tar_gz = Dir.glob("*.orig.tar.gz")
                        if orig_tar_gz.empty?
                            raise RuntimeError, "#{self} could not find file: *.orig.tar.gz in #{Dir.pwd}"
                        else
                            orig_tar_gz = orig_tar_gz.first
                            cmd = ["tar"]
                            cmd << "-x" << "--strip-components=1" <<
                                "-C" << versioned_build_dir <<
                                "-f" << orig_tar_gz
                            if !system(*cmd, :close_others => true)
                                 raise RuntimeError, "Packager: '#{cmd.join(" ")}' failed"
                            end
                        end

                        FileUtils.mv 'debian', versioned_build_dir + '/'
                        FileUtils.chdir versioned_build_dir do
                            cmd = ["debuild",  "-us", "-uc"]
                            if options[:parallel_build_level]
                                cmd << "-j#{options[:parallel_build_level]}"
                            end
                            if !system(*cmd, :close_others => true)
                                raise RuntimeError, "Packager: '#{cmd}' failed"
                            end
                        end

                        filepath = Dir.glob("*.deb")
                        if filepath.size < 1
                            raise RuntimeError, "No debian file generated in #{Dir.pwd}"
                        elsif filepath.size > 1
                            raise RuntimeError, "More than one debian file available in #{Dir.pwd}: #{filepath}"
                        else
                            filepath = filepath.first
                        end
                    end
                rescue Exception => e
                    msg = "Package #{pkg_name} has not been packaged -- #{e}"
                    Packager.error msg
                    raise RuntimeError, msg
                end
                filepath
            end

            def install_debfile(deb_filename)
                cmd = ["sudo", "dpkg", "-i", deb_filename]
                Packager.info "Installing package via: '#{cmd.join(" ")}'"
                if !system(*cmd, :close_others => true)
                    Packager.warn "Executing '#{cmd.join(" ")}' failed -- trying to fix installation"
                    cmd = ["sudo", "apt-get", "install", "-y", "-f"]
                    if !system(*cmd, :close_others => true)
                        raise RuntimeError, "Executing '#{cmd.join(" ")}' failed"
                    end
                end
            end

            # Install package
            def install(pkg_name, options)
                begin
                    pkg_build_dir = packaging_dir(pkg_name)
                    filepath = Dir.glob("#{pkg_build_dir}/*.deb")
                    if filepath.size < 1
                        raise RuntimeError, "No debian file found for #{pkg_name} in #{pkg_build_dir}: #{filepath}"
                    elsif filepath.size > 1
                        raise RuntimeError, "More than one debian file available in #{pkg_build_dir}: #{filepath}"
                    else
                        filepath = filepath.first
                        Packager.info "Found package: #{filepath}"
                    end
                    install_debfile(filepath)
                rescue Exception => e
                    raise RuntimeError, "Installation of package '#{pkg_name} failed -- #{e}"
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
            def package_updated?(pkginfo)
                # append underscore to make sure version definition follows
                registered_orig_tar_gz = reprepro_registered_files(debian_name(pkginfo) + "_",
                                             rock_release_name,
                                             "*.orig.tar.gz")
                if registered_orig_tar_gz.empty?
                    Packager.info "Apaka::Packaging::Debian::package_updated?: ro existing orig.tar.gz found in reprepro"
                else
                    Packager.info "Apaka::Packaging::Debian::package_updated?: existing orig.tar.gz found in reprepro: #{registered_orig_tar_gz}"
                    FileUtils.cp registered_orig_tar_gz.first, Dir.pwd
                end

                # Find an existing orig.tar.gz in the build directory
                # ignoring the current version-timestamp
                orig_file_name = Dir.glob("#{debian_name(pkginfo)}*.orig.tar.gz")
                if orig_file_name.empty?
                    Packager.info "No filename found for #{debian_name(pkginfo)} (existing files: #{Dir.entries('.')} -- package requires update (regeneration of orig.tar.gz)"
                    return true
                elsif orig_file_name.size > 1
                    Packager.warn "Multiple version of package #{debian_name(pkginfo)} in #{Dir.pwd} -- you have to fix this first"
                else
                    orig_file_name = orig_file_name.first
                end

                # Create a local copy/backup of the current orig.tar.gz in .obs_package
                # and extract it there -- compare the actual source package
                FileUtils.cp(orig_file_name, local_tmp_dir)
                Dir.chdir(local_tmp_dir) do
                    system("tar", "xzf", orig_file_name, :close_others => true)
                    base_name = orig_file_name.sub(".orig.tar.gz","")
                    Dir.chdir(base_name) do
                        diff_name = File.join(local_tmp_dir, "#{orig_file_name}.diff")
                        system("diff", "-urN", "--exclude", ".*", "--exclude", "CVS", "--exclude", "debian", "--exclude", "build", pkginfo.srcdir, ".", :out  => diff_name)
                        Packager.info "Package: '#{pkginfo.name}' checking diff file '#{diff_name}'"
                        if File.open(diff_name).lines.any?
                            return true
                        end
                    end
                end
                return false
            end

            # Prepare the build directory, i.e. cleanup and obsolete file
            def prepare
                if not File.exist?(build_dir)
                    FileUtils.mkdir_p build_dir
                end
                cleanup
            end

            # Cleanup an existing local tmp folder in the build dir
            def cleanup
                tmpdir = File.join(build_dir,local_tmp_dir)
                if File.exist?(tmpdir)
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
                Packager.info "Convert gems: #{gems} with options #{options.reject { |k,v| k==:deps }}"
                if gems.empty?
                    return
                end

                options, unknown_options = Kernel.filter_options options,
                    :force_update => false,
                    :patch_dir => nil,
                    :local_pkg => false,
                    :distribution => target_platform.distribution_release_name,
                    :architecture => target_platform.architecture

                if unknown_options.size > 0
                    Packager.warn "Apaka::Packaging Unknown options provided to convert gems: #{unknown_options}"
                end

                # We use gem2deb for the job of converting the gems
                # However, since we require some gems to be patched we split the process into the
                # individual step
                # This allows to add an overlay (patch) to be added to the final directory -- which
                # requires to be commited via dpkg-source --commit
                gems.each do |gem_name, version|
                    gem_dir_name = debian_ruby_name(gem_name)

                    packaging_dirname = packaging_dir(gem_dir_name)
                    if options[:force_update]
                        if File.directory?(packaging_dirname)
                            Packager.info "Debian Gem: rebuild requested -- removing #{packaging_dirname}"
                            FileUtils.rm_rf(packaging_dirname)
                        end
                    end

                    # Assuming if the .gem file has been download we do not need to update
                    gem_globname = "#{packaging_dirname}/#{gem_name}*.gem"
                    if options[:force_update] or Dir.glob(gem_globname).empty?
                        Packager.debug "Converting gem: '#{gem_name}' to debian source package"
                        if !File.directory?( packaging_dirname )
                            FileUtils.mkdir_p packaging_dirname
                        end

                        Dir.chdir(packaging_dirname) do
                            gem_from_cache = false
                            if patch_dir = options[:patch_dir]
                                gem_dir = File.join(patch_dir, "gems", gem_name)
                                if File.directory?(gem_dir)
                                    gem = Dir.glob("#{gem_dir}/*.gem")
                                    if !gem.empty?
                                        gem_from_cache = true
                                        Packager.info "Using gem from cache: copying #{gem.first} to #{Dir.pwd}"
                                        selected_gem = nil
                                        if version
                                            regexp = Regexp.new(version)
                                            gem.each do |gem_name|
                                                if regexp.match(gem_name)
                                                    selected_gem = gem_name
                                                    break
                                                end
                                            end
                                        else
                                            selected_gem = gem.first
                                            Packager.info "Using gem from cache: #{selected_gem} since no version requirement is given (available: #{gem})"
                                        end
                                        if !selected_gem
                                            Packager.warn "Gem(s) in cache does not match the expected version: #{version}"
                                            raise RuntimeError, "Failed to find gem for '#{gem_name}' with version '#{version}' in cache: #{File.absolute_path(gem_dir)}"
                                        end
                                        FileUtils.cp selected_gem, "."
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
                                        pid = Process.spawn("gem", "fetch", gem_name, "--version", version, :close_others => true)
                                        #output = `gem fetch #{gem_name} --version '#{version}'`
                                    else
                                        pid = Process.spawn("gem", "fetch", gem_name, :close_others => true)
                                        #output = `gem fetch #{gem_name}`
                                    end
                                    begin
                                        Timeout.timeout(60) do
                                            Packager.info 'waiting for gem fetch to end'
                                            Process.wait(pid)
                                            Packager.info 'gem fetch seems successful'
                                            error = false
                                        end
                                    rescue Timeout::Error
                                        Packager.warn 'gem fetch not finished in time, killing it'
                                        Process.kill('TERM', pid)
                                        error = true
                                    end
                                    retry_count += 1
                                    break if not error or retry_count > max_retry
                                end
                            end
                        end
                        gem_file_name = Dir.glob(gem_globname).first
                        if !gem_file_name
                            raise ArgumentError, "Could not retrieve a gem '#{gem_name}', version '#{version}' and options '#{options.reject { |k,v| k==:deps }}'"
                        end
                        convert_gem(gem_file_name, options)
                    else
                        Packager.info "gem: #{gem_name} up to date"
                    end
                end
            end

            # Patch a package (in the current working directory) using overlays found in the global_patch_dir
            # Patches are searched for by the package name and the gem name
            # Returns true if patches have been applied
            def patch_pkg_dir(package_name, global_patch_dir, whitelist = nil, pkg_dir = Dir.pwd)
                if global_patch_dir
                    if !package_name
                        raise ArgumentError, "DebianPackager::patch_pkg_dir: package name is required, but was nil"
                    end
                    pkg_patch_dir = File.join(global_patch_dir, package_name)
                    if File.exist?(pkg_patch_dir)
                        return patch_directory(pkg_dir, pkg_patch_dir, whitelist)
                    end
                end
            end

            # Prepare a patch file by dynamically replacing the following
            # placeholder with the actual values
            # @ROCK_INSTALL_DIR@
            # @ROCK_RELEASE_NAME@
            # with the autogenerated one
            def prepare_patch_file(file)
                if File.file?(file)
                    filetype = `file -b --mime-type #{file} | cut -d/ -f1`.strip
                    if filetype == "text"
                        system("sed", "-i", "s#\@ROCK_INSTALL_DIR\@##{rock_install_directory}#g", file, :close_others => true)
                        system("sed", "-i", "s#\@ROCK_RELEASE_NAME\@##{rock_release_name}#g", file, :close_others => true)
                    end
                end
            end

            # Patch a target directory with the content in patch_dir
            # a whitelist allows to patch only particular files, but by default all files can be patched
            def patch_directory(target_dir, patch_dir, whitelist = nil)
                 if File.directory?(patch_dir)
                     Packager.warn "Applying overlay (patch) from: #{patch_dir} to #{target_dir}, whitelist: #{whitelist}"
                     if !whitelist
                         Dir.mktmpdir do |dir|
                             FileUtils.cp_r("#{patch_dir}/.", "#{dir}/.")
                             Dir.glob("#{dir}/**/*").each do |file|
                                 prepare_patch_file(file)
                             end
                             FileUtils.cp_r("#{dir}/.","#{target_dir}/.")
                         end
                     else
                        require 'tempfile'
                        whitelist.each do |pattern|
                            files = Dir["#{patch_dir}/#{pattern}"]
                            files.each do |f|
                                if File.exist?(f)
                                    tmpfile = Tempfile.new(File.basename(f))
                                    FileUtils.cp_r(f, tmpfile)
                                    prepare_patch_file(tmpfile.path)
                                    target_file = File.join(target_dir,File.basename(f))
                                    FileUtils.cp_r(tmpfile, target_file)
                                    Packager.warn "Patch target (#{target_file}) with #{tmpfile.path}"
                                end
                            end
                        end
                     end

                     # We need to commit if original files have been modified
                     # so add a commit
                     orig_files = Dir["#{patch_dir}/**"].reject { |f| f["#{patch_dir}/debian/"] }
                     return orig_files.size > 0
                 else
                     Packager.warn "No patch dir: #{patch_dir}"
                     return false
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
            #        :deps => {:rock_pkginfo => [], :osdeps => [], :nonnative => []},
            #        :distribution =>  nil
            #        :architecture => nil
            #        :local_package => false
            #
            def convert_gem(gem_path, options = Hash.new)
                Packager.info "Convert gem: '#{gem_path}' with options: #{options.reject { |k,v| k==:deps }}"

                options, unknown_options = Kernel.filter_options options,
                    :patch_dir => nil,
                    :deps => {:rock_pkginfo => [], :osdeps => [], :nonnative => []},
                    :distribution => target_platform.distribution_release_name,
                    :architecture => target_platform.architecture,
                    :local_pkg => false,
                    :package_name => nil,
                    :recursive_deps => nil,
                    :latest_commit_time => nil

                pkg_commit_time = options[:latest_commit_time]

                if !gem_path
                    raise ArgumentError, "Debian.convert_gem: no #{gem_path} given"
                end

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
                    # Step 0: check if the gem has already been registered, e.g. as result of building for 
                    # another architecture
                    ############
                    # append underscore to make sure version definition follows
                    registered_orig_tar_gz = reprepro_registered_files(debian_ruby_name(gem_base_name) + "_",
                                             rock_release_name,
                                             "*.orig.tar.gz")
                    if registered_orig_tar_gz.empty?
                        Packager.info "Apaka::Packaging::Debian::convert_gem: no existing orig.tar.gz found in reprepro"
                    else
                        Packager.info "Apaka::Packaging::Debian::convert_gem: existing orig.tar.gz found: #{registered_orig_tar_gz}"
                        FileUtils.cp registered_orig_tar_gz.first, "#{gem_versioned_name}.tar.gz"
                    end

                    ############
                    # Step 1: calling gem2tgz - if orig.tar.gz is not available
                    ############
                    if !File.exist?("#{gem_versioned_name}.tar.gz")
                        Packager.info "Converting gem: #{gem_versioned_name} in #{Dir.pwd}"
                        # Convert .gem to .tar.gz
                        cmd = ["gem2tgz", gem_file_name]
                        if not system(*cmd, :close_others => true)
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
                            system("tar", "xzf", gem_tar_gz, :close_others => true)
                            FileUtils.rm gem_tar_gz

                            # Check if we need to convert the name
                            if gem_tar_gz != "#{gem_versioned_name}.tar.gz"
                                tmp_source_dir = gem_tar_gz.gsub(/.tar.gz/,"")
                                FileUtils.mv tmp_source_dir, gem_versioned_name
                            end
                            Packager.info "Converted: #{Dir.glob("**")}"

                            # Check if patching is needed
                            # To allow patching we need to split `gem2deb -S #{gem_name}`
                            # into its substeps
                            #
                            Dir.chdir(gem_versioned_name) do
                                package_name = options[:package_name] || gem_base_name
                                patch_pkg_dir(package_name, options[:patch_dir], ["*.gemspec", "Rakefile", "metadata.yml"])
                            end

                            # https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=725348
                            checksums_file="checksums.yaml.gz"
                            files = Dir.glob("*/#{checksums_file}")
                            if not files.empty?
                                checksums_file = files.first
                            end

                            if File.exist? checksums_file
                                Packager.info "Pre-packaging cleanup: removing #{checksums_file}"
                                FileUtils.rm checksums_file
                            else
                                Packager.info "Pre-packaging cleannup: no #{checksums_file} found"
                            end


                            tgz_date = nil

                            if pkg_commit_time
                                tgz_date = pkg_commit_time
                            else
                                # Prefer metadata.yml over gemspec since it gives a more reliable timestamp
                                ['*.gemspec', 'metadata.yml'].each do |file|
                                    Dir.chdir(gem_versioned_name) do
                                        files = Dir.glob("#{file}")
                                        if not files.empty?
                                            if files.first =~ /yml/
                                                spec = YAML.load_file(files.first)
                                            else
                                                spec = Gem::Specification::load(files.first)
                                            end
                                        else
                                            Packager.info "Gem conversion: file #{file} does not exist"
                                            next
                                        end

                                        #todo: not reliable. need sth better.
                                        if spec
                                            Packager.info "Loaded gemspec: #{spec}"
                                            if spec.date
                                                if !tgz_date || spec.date < tgz_date
                                                    tgz_date = spec.date
                                                    Packager.info "#{files.first} has associated time: using #{tgz_date} as timestamp"
                                                end
                                                Packager.info "#{files.first} has associated time, but too recent, thus staying with #{tgz_date} as timestamp"
                                            else
                                                Packager.warn "#{files.first} has no associated time: using current time for packaging"
                                            end
                                        else
                                            Packager.warn "#{files.first} is not a spec file"
                                        end
                                    end
                                end
                            end
                            if !tgz_date
                                tgz_date = Time.now
                                Packager.warn "Gem conversion: could not extract time for gem: using current time: #{tgz_date}"
                            else
                                Packager.info "Gem conversion: successfully extracted time for gem: using: #{tgz_date}"
                                files = Dir.glob("#{gem_versioned_name}/metadata.yml")
                                if not files.empty?
                                    spec = YAML.load_file(files.first)
                                    spec.date = tgz_date
                                    File.open(files.first, "w") do |file|
                                        Packager.info "Gem conversion: updating metadata.yml timestamp"
                                        file.write spec.to_yaml
                                    end
                                end
                            end

                            # Repackage
                            source_dir = gem_versioned_name
                            if !tar_gzip(source_dir, "#{gem_versioned_name}.tar.gz", tgz_date)
                                raise RuntimeError, "Failed to reformat original #{gem_versioned_name}.tar.gz for gem"
                            end
                            FileUtils.rm_rf source_dir
                            Packager.info "Converted: #{Dir.glob("**")}"
                        end
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
                    cmd = ["dh-make-ruby"]
                    cmd << "--ruby-versions" << "all" <<
                        "#{gem_versioned_name}.tar.gz" <<
                        "-p" << "#{rock_ruby_release_prefix}#{gem_base_name}"
                    Packager.info "calling: #{cmd.join(" ")}"
                    if !system(*cmd, :close_others => true)
                         Packager.warn "calling: #{cmd.join(" ")} failed"
                         raise RuntimeError, "Failed to call #{cmd.join(" ")}"
                    end

                    debian_ruby_name = debian_ruby_name(gem_versioned_name)# + '~' + distribution
                    debian_ruby_unversioned_name = debian_ruby_name.gsub(/-[0-9\.]*(\.rc[0-9]+)?$/,"")
                    Packager.info "Debian ruby name: #{debian_ruby_name} -- directory #{Dir.glob("**")}"
                    Packager.info "Debian ruby unversioned name: #{debian_ruby_unversioned_name}"

                    # Check if patching is needed
                    # To allow patching we need to split `gem2deb -S #{gem_name}`
                    # into its substeps
                    #
                    Dir.chdir(debian_ruby_name) do
                        package_name = options[:package_name] || gem_base_name
                        if patch_pkg_dir(package_name, options[:patch_dir])
                            dpkg_commit_changes("deb_autopackaging_overlay")
                            # the above may fail when we patched debian/control
                            # this is going to be fixed next
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

                        debcontrol = DebianControl.parse(File.open("debian/control"))

                        # Filter ruby versions out -- we assume chroot has installed all
                        # ruby versions
                        all_deps = options[:deps][:osdeps].select do |name|
                            name !~ /^ruby[0-9][0-9.]*/
                        end

                        options[:deps][:rock_pkginfo].each do |pkginfo|
                            depname, is_osdep = native_dependency_name(pkginfo)
                            all_deps << depname
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
                            depname, is_osdep = native_dependency_name(k)
                            all_deps << depname
                        end
                        deps = all_deps.uniq

                        if options.has_key?(:recursive_deps)
                            recursive_deps = options[:recursive_deps]
                        else
                            recursive_deps = nil
                        end

                        # Fix the name, in case we had to patch
                        debcontrol.source["Source"] = debian_ruby_unversioned_name
                        debcontrol.packages.each do |pkg|
                            pkg["Package"] = debian_ruby_unversioned_name
                        end

                        # parse and filter dependencies
                        debcontrol.packages.each do |pkg|
                            if pkg.has_key?("Depends")
                                depends = pkg["Depends"].split(/,\s*/).map { |e| e.strip }
                                depends.each do |dep|
                                    if dep =~ /^ruby-(\S+)/
                                        pkg_name = $1
                                        release_name, is_osdep = native_dependency_name(pkg_name)
                                        Packager.debug "Native dependency of ruby package: '#{pkg_name}' -- #{release_name}, is available as osdep: #{is_osdep}"
                                        dep.replace(release_name)
                                    end
                                    if !recursive_deps.nil?
                                        dep =~ /^(\S+)/
                                        t = $1
                                        if !recursive_deps.include?(t) && !DEPWHITELIST.include?(t) && t !~ /^\${/
                                            Packager.error "Dependency #{t} required by debian/control but not by rock. Check manifest."
                                        end
                                        dep.clear
                                    end
                                end
                            else
                                depends = Array.new
                            end
                            depends.concat deps
                            depends.delete("")
                            pkg["Depends"] = depends.uniq.join(", ") unless depends.empty?
                            Packager.info "Depends: #{debian_ruby_name}: injecting dependencies: '#{pkg["Depends"]}'"
                        end

                        # parse and filter build dependencies
                        if debcontrol.source.has_key?("Build-Depends")
                            build_depends = debcontrol.source["Build-Depends"].split(/,\s*/).map { |e| e.strip }
                            build_depends.each do |bdep|
                                if bdep =~ /^ruby-(\S+)/
                                    pkg_name = $1
                                    release_name, is_osdep = native_dependency_name(pkg_name)
                                    Packager.debug "Native dependency of ruby package: '#{pkg_name}' -- #{release_name}, is available as osdep: #{is_osdep}"
                                    bdep.replace(release_name)
                                end
                                if !recursive_deps.nil?
                                    bdep =~ /^(\S+)/
                                    t = $1
                                    if !recursive_deps.include?(t) && !DEPWHITELIST.include?(t) && t !~ /^\${/
                                        Packager.error "Dependency #{t} required by debian/control but not by rock. Check manifest."
                                        bdep.clear
                                        ## todo: problem here: bdep (or dep above) does not necessarily reference an actual object, or (as is the case with metaruby=>tools/metaruby) reference a similarly named object.
                                        ## in addition, metaruby is a metapackage, pulling tools/metaruby
                                    end
                                end
                            end
                        else
                            build_depends = Array.new
                        end

                        # Add dh-autoreconf to build dependency
                        deps << "dh-autoreconf"
                        build_depends.concat(deps)
                        #`sed -i "s#^\\(^Build-Depends: .*\\)#\\1, #{deps.join(", ")},#" debian/control`

                        debcontrol.source["Build-Depends"] = build_depends.uniq.join(", ")
                        File.write("debian/control", DebianControl::generate(debcontrol))
                        dpkg_commit_changes("deb_extra_dependencies")

                        Packager.info "Relaxing version requirement for: debhelper and gem2deb"
                        # Relaxing the required gem2deb version to allow for for multiplatform support
                        #`sed -i "s#^\\(^Build-Depends: .*\\)gem2deb (>= [0-9\.~]\\+)\\(, .*\\)#\\1 gem2deb\\2#g" debian/control`
                        #`sed -i "s#^\\(^Build-Depends: .*\\)debhelper (>= [0-9\.~]\\+)\\(, .*\\)#\\1 debhelper\\2#g" debian/control`
                        build_depends.each do |bdep|
                            bdep.replace("gem2deb") if bdep =~ /gem2deb.+/
                            bdep.replace("debhelper") if bdep =~ /debhelper.+/
                        end
                        debcontrol.source["Build-Depends"] = build_depends.uniq.join(", ")
                        Packager.info "Build-Depends: #{debian_ruby_name}: injecting dependencies: '#{debcontrol.source["Build-Depends"]}'"

                        File.write("debian/control", DebianControl::generate(debcontrol))
                        dpkg_commit_changes("relax_version_requirements")

                        Packager.info "Change to 'any' architecture"
                        #`sed -i "s#Architecture: all#Architecture: any#" debian/control`
                        debcontrol.packages.each do |pkg|
                          pkg["Architecture"] = "any"
                        end
                        File.write("debian/control", DebianControl::generate(debcontrol))
                        dpkg_commit_changes("any-architecture")

                        #-- e.g. for overlays use the original name in the control file
                        # which will be overwritten here
                        Packager.info "Adapt original package name if it exists"
                        original_name = debian_ruby_name(gem_base_name, false)
                        release_name = debian_ruby_name(gem_base_name, true)
                        # Avoid replacing parts of the release name, when it is already adapted
                        # rock-master-ruby-facets with ruby-facets
                        system("sed", "-i", "s##{release_name}##{original_name}#g", "debian/*", :close_others => true)
                        # Inject the true name
                        system("sed", "-i", "s##{original_name}##{release_name}#g", "debian/*", :close_others => true)
                        dpkg_commit_changes("adapt_original_package_name")

                        ################
                        # debian/package.postinst
                        ################
                        if File.exist?("debian/package.postinst")
                            FileUtils.mv "debian/package.postinst", "debian/#{debian_ruby_unversioned_name}.postinst"
                            dpkg_commit_changes("add_postinst_script")
                        end

                        ################
                        # debian/install
                        ################
                        if File.exist?("debian/install")
                            system("sed", "-i", "s#/usr##{rock_install_directory}#g", "debian/install")
                            dpkg_commit_changes("install_to_rock_specific_directory")
                            # the above may fail when we patched debian/control
                        end

                        ################
                        # debian/rules
                        ################

                        # Injecting environment setup in debian/rules
                        # packages like orocos.rb will require locally installed packages

                        Packager.info "#{debian_ruby_name}: injecting environment variables into debian/rules"
                        Packager.debug "Allow custom rock name and installation path: #{rock_install_directory}"
                        Packager.debug "Enable custom rock name and custom installation path"

                        system("sed", "-i", "1 a env_setup += RUBY_CMAKE_INSTALL_PREFIX=#{File.join("debian",debian_ruby_unversioned_name, rock_install_directory)}", "debian/rules", :close_others => true)
                        envsh = Regexp.escape(env_setup())
                        system("sed", "-i", "1 a #{envsh}", "debian/rules", :close_others => true)
                        ruby_arch_env = ruby_arch_setup(true)
                        system("sed", "-i", "1 a #{ruby_arch_env}", "debian/rules", :close_others => true)
                        system("sed", "-i", "1 a export DH_RUBY_INSTALL_PREFIX=#{rock_install_directory}", "debian/rules", :close_others => true)
                        system("sed", "-i", "s#\\(dh \\)#\\$(env_setup) \\1#", "debian/rules", :close_others => true)

                        # Ignore all ruby test results when the binary package is build (on the build server)
                        # via:
                        # dpkg-buildpackage -us -uc
                        #
                        # Thus uncommented line of
                        # export DH_RUBY_IGNORE_TESTS=all
                        Packager.debug "Disabling tests including ruby test result evaluation"
                        system("sed", "-i", "s/#\\(export DH_RUBY_IGNORE_TESTS=all\\)/\\1/", "debian/rules", :close_others => true)
                        # Add DEB_BUILD_OPTIONS=nocheck
                        # https://www.debian.org/doc/debian-policy/ch-source.html
                        system("sed", "-i", "1 a export DEB_BUILD_OPTIONS=nocheck", "debian/rules", :close_others => true)
                        dpkg_commit_changes("disable_tests")


                        ["debian","pkgconfig"].each do |subdir|
                            Dir.glob("#{subdir}/*").each do |file|
                                system("sed", "-i", "s#\@ROCK_INSTALL_DIR\@##{rock_install_directory}#g", file, :close_others => true)
                                dpkg_commit_changes("adapt_rock_install_dir")
                            end
                        end

                        # Documentation generation
                        #
                        # by default dh_ruby only installs files it finds in
                        # the source tar (bin/ and lib/), but we can add our
                        # own through dh_ruby.rake or dh_ruby.mk
                        # dh_ruby.rake / dh_ruby.mk called like this:
                        # <cmd> clean                 # clean
                        # <cmd>                       # build
                        # <cmd> install DESTDIR=<dir> # install
                        # This all is described in detail in "man dh_ruby"

                        dh_ruby_mk = <<-END
rock_doc_install_dir=#{rock_install_directory}/share/doc/#{debian_ruby_name}

build:
	-#{@gem_doc_alternatives.join(" || ")}

clean:
#	-rm -rf doc

install:
	mkdir -p $(DESTDIR)/$(rock_doc_install_dir)
	-cp -r doc $(DESTDIR)/$(rock_doc_install_dir)
END
                        File.write("debian/dh_ruby.mk", dh_ruby_mk)

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

                        ########################
                        # debian/compat
                        ########################
                        set_compat_level(DEBHELPER_DEFAULT_COMPAT_LEVEL, "debian/compat")
                    end


                    # Build only a debian source package -- do not compile binary package
                    Packager.info "Building debian source package: #{debian_ruby_name}"
                    result = `dpkg-source -I -b #{debian_ruby_name}`
                    Packager.info "Resulting debian files: #{Dir.glob("**")} in #{Dir.pwd}"
                end
            end #end def

            def self.installable_ruby_versions
                version_file = File.join(local_tmp_dir,"ruby_versions")
                system("apt-cache search ruby | grep -e '^ruby[0-9][0-9.]*-dev' | cut -d' ' -f1 > #{version_file}", :close_others => true)
                ruby_versions = []
                File.open(version_file,"r") do |file|
                    ruby_versions = file.read.split("\n")
                end
                ruby_versions = ruby_versions.collect do |version|
                    version.gsub(/-dev/,"")
                end
                ruby_versions
            end

            # Compute the ruby arch setup
            # - for passing through sed escaping is required
            # - for using with file rendering no escaping is required
            def ruby_arch_setup(do_escape = false)
                Packager.info "Creating ruby env setup"
                if do_escape
                    setup = Regexp.escape("arch=$(shell gcc -print-multiarch)\n")
                    # Extract the default ruby version to build for on that platform
                    # this assumes a proper setup of /usr/bin/ruby
                    setup += Regexp.escape("ruby_ver=$(shell ruby --version)\n")
                    setup += Regexp.escape("ruby_arch_dir=$(shell ruby -r rbconfig -e ") + "\\\"print RbConfig::CONFIG[\'archdir\']\\\")" + Regexp.escape("\n")
                    setup += Regexp.escape("ruby_libdir=$(shell ruby -r rbconfig -e ") + "\\\"print RbConfig::CONFIG[\'rubylibdir\']\\\")" + Regexp.escape("\n")

                    setup += Regexp.escape("rockruby_archdir=$(subst /usr,,$(ruby_arch_dir))\n")
                    setup += Regexp.escape("rockruby_libdir=$(subst /usr,,$(ruby_libdir))\n")
                else
                    setup = "arch=$(shell gcc -print-multiarch)\n"
                    # Extract the default ruby version to build for on that platform
                    # this assumes a proper setup of /usr/bin/ruby
                    setup += "ruby_ver=$(shell ruby --version)\n"
                    setup += "ruby_arch_dir=$(shell ruby -r rbconfig -e \"print RbConfig::CONFIG[\'archdir\']\")\n"
                    setup += "ruby_libdir=$(shell ruby -r rbconfig -e \"print RbConfig::CONFIG[\'rubylibdir\']\")\n"

                    setup += "rockruby_archdir=$(subst /usr,,$(ruby_arch_dir))\n"
                    setup += "rockruby_libdir=$(subst /usr,,$(ruby_libdir))\n"
                end
                Packager.info "Setup is: #{setup}"
                setup
            end

            def env_setup
                Packager.info "Creating envsh"
                path_env            = "PATH="
                rubylib_env         = "RUBYLIB="
                pkgconfig_env       = "PKG_CONFIG_PATH="
                rock_dir_env        = "Rock_DIR="
                ld_library_path_env = "LD_LIBRARY_PATH="
                cmake_prefix_path   = "CMAKE_PREFIX_PATH="
                orogen_plugin_path  = "OROGEN_PLUGIN_PATH="
                rock_library_dirs = ""
                envsh = ""

                rock_release_hierarchy.each do |release_name|
                    install_dir = File.join(rock_base_install_directory, release_name)
                    install_dir_varname = "#{release_name.gsub(/\./,'').gsub(/-/,'')}_install_dir"
                    install_dir_var ="$(#{install_dir_varname})"
                    envsh += "#{install_dir_varname} = #{install_dir}\n"

                    path_env    += "#{File.join(install_dir_var, "bin")}:"

                    # Update execution path for orogen, so that it picks up ruby-facets (since we don't put much effort into standardizing facets it installs in
                    # vendor_ruby/standard and vendory_ruby/core) -- from Ubuntu 13.04 ruby-facets will be properly packaged
                    rubylib_env += "#{File.join(install_dir_var, "$(rockruby_libdir)")}:"
                    rubylib_env += "#{File.join(install_dir_var, "$(rockruby_archdir)")}:"
                    rubylib_env += "#{File.join(install_dir_var, "lib/ruby/vendor_ruby/standard")}:"
                    rubylib_env += "#{File.join(install_dir_var, "lib/ruby/vendor_ruby/core")}:"
                    rubylib_env += "#{File.join(install_dir_var, "lib/ruby/vendor_ruby")}:"

                    pkgconfig_env += "#{File.join(install_dir_var,"lib/pkgconfig")}:"
                    pkgconfig_env += "#{File.join(install_dir_var,"lib/$(arch)/pkgconfig")}:"
                    rock_dir_env += "#{File.join(install_dir_var, "share/rock/cmake")}:"
                    ld_library_path_env += "#{File.join(install_dir_var,"lib")}:#{File.join(install_dir_var,"lib/$(arch)")}:"
                    cmake_prefix_path += "#{install_dir_var}:"
                    orogen_plugin_path += "#{File.join(install_dir_var,"share/orogen/plugins")}:"
                    rock_library_dirs += "#{File.join(install_dir_var,"lib")}:#{File.join(install_dir_var,"lib/$(arch)")}:"
                end

                pkgconfig_env       += "/usr/share/pkgconfig:/usr/lib/$(arch)/pkgconfig:"

                path_env            += "$(PATH)"
                rubylib_env         += "$(RUBYLIB)"
                pkgconfig_env       += "$(PKG_CONFIG_PATH)"
                rock_dir_env        += "$(Rock_DIR)"
                ld_library_path_env += "$(LD_LIBRARY_PATH)"
                cmake_prefix_path   += "$(CMAKE_PREFIX_PATH)"
                orogen_plugin_path  += "$(OROGEN_PLUGIN_PATH)"

                envsh +=  "env_setup =  #{path_env}\n"
                envsh += "env_setup += #{rubylib_env}\n"
                envsh += "env_setup += #{pkgconfig_env}\n"
                envsh += "env_setup += #{rock_dir_env}\n"
                envsh += "env_setup += #{ld_library_path_env}\n"
                envsh += "env_setup += #{cmake_prefix_path}\n"
                envsh += "env_setup += #{orogen_plugin_path}\n"

                typelib_cxx_loader = nil
                if target_platform.contains("castxml")
                    typelib_cxx_loader = "castxml"
                elsif target_platform.contains("gccxml")
                    typelib_cxx_loader = "gccxml"
                else
                    raise ArgumentError, "TargetPlatform: #{target_platform} does neither support castxml nor gccml - cannot build typelib"
                end
                if typelib_cxx_loader
                    envsh += "export TYPELIB_CXX_LOADER=#{typelib_cxx_loader}\n"
                end
                envsh += "export DEB_CPPFLAGS_APPEND=-std=c++11\n"
                envsh += "export npm_config_cache=/tmp/npm\n"
                envsh += "rock_library_dirs=#{rock_library_dirs}\n"
                envsh += "rock_install_dir=#{rock_install_directory}"
                envsh
            end

            def set_compat_level(compatlevel = DEBHELPER_DEFAULT_COMPAT_LEVEL, compatfile = "debian/compat")
                if !File.exist?(compatfile)
                    raise ArgumentError, "Apaka::Packaging::Debian::set_compat_level: could not find file '#{compatfile}', working directory is: '#{Dir.pwd}'"
                end
                existing_compatlevel = `cat #{compatfile}`.strip
                Packager.info "Setting debian compat level to: #{compatlevel} (previous setting was #{existing_compatlevel})"
                `echo #{compatlevel} > #{compatfile}`
            end
        end #end Debian
    end
end

