require 'find'
require 'tmpdir'
require 'utilrb'
require 'timeout'
require 'time'
require 'open3'
require 'erb'

require_relative '../debian_control'
require_relative '../debian_changelog'
require_relative '../packageinfo'
require_relative '../gem_dependencies'

require_relative 'env'
require_relative 'dependency_manager'

module Apaka
    module Packaging
        module Deb
            # Canonize that name -- downcase and replace _ with -
            def self.canonize(name)
                name.gsub(/[\/_]/, '-').downcase
            end

            class Package2Deb < Packager
                TEMPLATES = File.expand_path(File.join("..","templates", "debian"), __dir__)
                TEMPLATES_META = File.expand_path(File.join("..","templates", "debian-meta"), __dir__)
                DEPWHITELIST = ["debhelper","gem2deb","ruby","ruby-rspec"]
                DEBHELPER_DEFAULT_COMPAT_LEVEL = 9
                DEB_ARTIFACTS_SUFFIXES = [".dsc", ".orig.tar.gz", ".debian.tar.gz", ".debian.tar.xz"]

                DEFAULT_BUILD_DEPENDENCIES = []
                DEFAULT_RUNTIME_DEPENDENCIES = [ "ruby" ]

                attr_reader :existing_debian_directories

                # install directory if not given set to /opt/rock
                attr_accessor :rock_base_install_directory
                attr_reader :rock_release_name
                # The pkg prefix base name, e.g., rock in rock-ruby-master-18.01,
                attr_reader :pkg_prefix_base

                # List of extra rock packages to depend on, by build type
                # For example, :orogen build_type requires orogen from rock.
                attr_accessor :rock_autobuild_deps

                attr_reader :rock_release_platform
                attr_reader :rock_release_hierarchy

                attr_accessor :packager_lock

                attr_reader :env
                attr_reader :dep_manager

                def initialize(options = Hash.new)
                    super(options)

                    @packager_lock = Mutex.new

                    @debian_version = Hash.new
                    @rock_base_install_directory = Packaging::Config.base_install_prefix
                    @pkg_prefix_base = Packaging::Config.base_package_prefix

                    @rock_autobuild_deps = { :orogen => [], :cmake => [], :autotools => [], :ruby => [], :archive_importer => [], :importer_package => [] }

                    if options[:release_name]
                        self.rock_release_name = options[:release_name]
                    else
                        self.rock_release_name = Packaging.default_release_name
                    end
                    @reprepro.init_repository(rock_release_name, target_platform)

                    @current_pkg_info = nil

                    @env = Deb::Environment.new(self)
                    @dep_manager = Deb::DependencyManager.new(self)
                end

                # Get the current rock-release-based prefix for rock packages
                def rock_release_prefix(release_name = nil)
                    release_name ||= rock_release_name
                    if release_name
                        pkg_prefix_base + "-#{release_name}-"
                    else
                        pkg_prefix_base + "-"
                    end
                end

                # Get the current rock-release-based prefix for rock-(ruby) packages
                def rock_ruby_release_prefix(release_name = nil)
                    rock_release_prefix(release_name) + "ruby-"
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

                    debianize_name(name,
                                build_type: pkginfo.build_type,
                                with_rock_release_prefix: with_rock_release_prefix,
                                release_name: release_name)
                end

                # Create a debian package name from a given plain name according
                # to build type, release name and release_prefix setting
                def debianize_name(name, build_type: :cmake, with_rock_release_prefix: true, release_name: rock_release_name)
                    if build_type == :ruby
                        if with_rock_release_prefix
                            rock_release_prefix(release_name) + "ruby-" + Deb.canonize(name)
                        else
                            pkg_prefix_base + "-ruby-" + Deb.canonize(name)
                        end
                    else
                        if with_rock_release_prefix
                            rock_release_prefix(release_name) + Deb.canonize(name)
                        else
                            pkg_prefix_base + "-" + Deb.canonize(name)
                        end
                    end
                end

                # The debian name of a meta package --
                # rock[-<release-name>]-meta-<canonized-package-name>
                # and the release-name can be avoided by setting
                # with_rock_release_prefix to false
                #
                def debian_meta_name(name, with_rock_release_prefix = true)
                    if with_rock_release_prefix
                        rock_release_prefix + "meta-" + Deb.canonize(name)
                    else
                        pkg_prefix_base + "meta-" + Deb.canonize(name)
                    end
                end


                # The debian name of a package
                # [rock-<release-name>-]ruby-<canonized-package-name>
                # and the release-name prefix can be avoided by setting
                # with_rock_release_prefix to false
                #
                def debian_ruby_name(name, with_rock_release_prefix = true, release_name = nil)
                    if with_rock_release_prefix
                        rock_ruby_release_prefix(release_name) + Deb.canonize(name)
                    else
                        "ruby-" + Deb.canonize(name)
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
                    File.join(@build_dir, target_platform.to_s, pkg_name)
                end

                def rock_release_install_directory
                    File.join(rock_base_install_directory, rock_release_name)
                end

                def rock_install_directory(package_name: nil)
                    install_dir = rock_release_install_directory
                    if package_name
                        install_dir = File.join(install_dir, package_name)
                    elsif @current_pkg_info
                        install_dir = File.join(install_dir, debian_name(@current_pkg_info))
                    end
                    install_dir
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

                def patch_options
                    { install_dir: rock_install_directory(),
                      package_dir: rock_install_directory(),
                      release_name: rock_release_name,
                      release_dir: rock_release_install_directory()
                    }
                end

                # Commit changes of a debian package using dpkg-source --commit
                # in a given directory (or the current one by default)
                def dpkg_commit_changes(patch_name, directory = Dir.pwd,
                                        prefix: "apaka-",
                                        logfile: nil,
                                        include_removal: false
                                       )
                    Dir.chdir(directory) do
                        Packager.debug ("commit changes to debian pkg: #{patch_name}")
                        # Since dpkg-source will open an editor we have to
                        # take this approach to make it pass directly in an
                        # automated workflow
                        ENV['EDITOR'] = "/bin/true"
                        cmd = ["dpkg-source", "--commit"]
                        cmd << "--include-removal" if include_removal
                        cmd << "."
                        cmd << prefix + patch_name

                        if !system(*cmd,
                               [:out, :err] => redirection(logfile,"a"),
                               :close_others => true)
                            raise RuntimeError, "#{self.class}#{__method__}: failed to commit #{patch_name}"
                        end
                    end
                end

                # Generate the debian/ subfolder cindlugin control/rules/install
                # files to prepare the debian package build instructions
                def generate_debian_dir(pkginfo, dir, options)
                    options, unknown_options = Kernel.filter_options options,
                        :distribution => nil,
                        :override_existing => true,
                        :patch_dir => nil

                    distribution = options[:distribution]

                    # Prepare fields for template
                    package_info = pkginfo
                    debian_name = debian_name(pkginfo)
                    debian_version = debian_version(pkginfo, distribution)
                    versioned_name = versioned_name(pkginfo, distribution)
                    short_documentation = pkginfo.short_documentation
                    documentation = pkginfo.documentation
                    origin_information = pkginfo.origin_information
                    source_files = pkginfo.source_files

                    upstream_name = pkginfo.name
                    copyright = pkginfo.copyright
                    license = pkginfo.licenses

                    deps = @dep_manager.filtered_dependencies(pkginfo)
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

                    # To handle postinstall
                    DEFAULT_BUILD_DEPENDENCIES.each do |dep|
                        build_dependencies << dep
                    end

                    DEFAULT_RUNTIME_DEPENDENCIES.each do |dep|
                        dependencies << dep
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
                        if pkginfo.is_bundle?
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

                    dir = cleanup_existing_dir(dir, options)
                    existing_debian_dir = File.join(pkginfo.srcdir,"debian")
                    template_dir =
                        if File.directory?(existing_debian_dir)
                            existing_debian_dir
                        else
                            TEMPLATES
                        end
                    FileUtils.mkdir_p dir

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

                    if options[:patch_dir]
                        whitelist = [ "debian/rules","debian/control","debian/install" ]
                        if patch_pkg_dir(pkginfo.name, options[:patch_dir],
                                whitelist: whitelist,
                                pkg_dir: pkginfo.srcdir,
                                options: patch_options())
                            Packager.warn "Overlay patch applied to debian folder of #{pkginfo.name}"
                        end
                    end

                    ########################
                    # debian/compat
                    ########################
                    set_compat_level(DEBHELPER_DEFAULT_COMPAT_LEVEL, File.join(dir,"compat"))
                end

                # Generate the debian_dir for a meta package
                # i.e. representing a package set or a full release
                #
                # return [String] the main packages directory
                def generate_debian_dir_meta(name, depends, base_dir: Dir.pwd, version: "0.1", distribution: nil)
                    existing_debian_dir = File.join("#{name}-#{version}","debian-meta")
                    template_dir =
                        if File.directory?(existing_debian_dir)
                            existing_debian_dir
                        else
                            TEMPLATES_META
                        end

                    dir = File.join(base_dir, "debian")
                    FileUtils.mkdir_p dir
                    debian_name = debian_meta_name(name)
                    debian_version = "#{version}"
                    if distribution
                      debian_version += '~' + distribution
                    end

                    deps_rock_packages = depends
                    deps_osdeps_packages = []
                    deps_nonnative_packages = []

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

                    return dir
                end

                # A tar gzip version that reproduces
                # same checksums on the same day when file content does not change
                #
                # Required to package orig.tar.gz
                def tar_gzip(archive, tarfile, pkg_time, distribution = nil,
                            logfile: nil)

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

                    if system(cmd_tar, [:out,:err] => redirection(logfile, "a"))
                        Packager.info "Package: successfully created archive using command '#{cmd_tar}' -- pwd #{Dir.pwd} -- #{Dir.glob("**")}"
                        checksum = `sha256sum #{tarfile}`
                        Packager.info "Package: sha256sum: #{checksum}"
                        return true
                    else
                        Packager.info "Package: failed to create archive using command '#{cmd_tar}' -- pwd #{Dir.pwd}"
                        return false
                    end
                end

                # Package selection is a collection of pkginfo
                def package_selection(selection,
                                force_update: nil,
                                patch_dir: nil,
                                package_set_dir: nil,
                                use_remote_repository: false)
                    sync_packages = {}
                    selected_gems = []

                    selection.each_with_index do |pkginfo, i|
                        pkg_name = pkginfo.name
                        pkg = pkginfo.pkg

                        Autoproj.message "Packaging #{pkg_name} (#{i + 1}/#{selection.size})", :green
                        # Making sure all packages that require base/cmake due to using Rock CMake macros have
                        # a dependency on base/cmake
                        if File.file?(File.join(pkg.srcdir, "CMakeLists.txt"))
                            cmakelists_txt = File.read(File.join(pkg.srcdir, "CMakeLists.txt"))
                            if cmakelists_txt =~ /include\(Rock\)|Rock\.cmake/ || cmakelists_txt =~ /find_package\(Rock\)/
                                pkg.depends_on "base/cmake" unless pkg.name == "base/cmake"
                            end
                        end

                        begin
                            options = {:force_update => force_update, :patch_dir => patch_dir, :package_set_dir => package_set_dir}
                            if !use_remote_repository
                                options[:existing_source_dir] = pkg.srcdir
                            end
                            # just to update the required gem property
                            selected_gems.concat pkginfo.dependencies[:extra_gems]

                            # Perform the actual packaging
                            package(pkginfo, options)

                            sync_packages[pkg_name] = { :debian_name => debian_name(pkginfo),
                                                        :build_deps => build_dependencies(pkginfo),
                                                        :type => :package
                            }
                        rescue Interrupt
                            raise
                        rescue Exception => e
                            Apaka::Packaging.warn "failed to package #{pkg.name}: #{e.message} #{e.backtrace}"
                            next
                        end
                    end
                    [sync_packages, selected_gems.uniq]
                end

                # Package the given package unless already registerd in reprepro
                #
                # if an existing source directory is given this will be used
                # for packaging, otherwise the package will be bootstrapped
                def package(pkginfo, options = Hash.new)
                    options, unknown_options = Kernel.filter_options options,
                        :force_update => false,
                        :patch_dir => nil,
                        :distribution => nil, # allow to override global settings
                        :architecture => nil

                    options[:distribution] ||= target_platform.distribution_release_name
                    options[:architecture] ||= target_platform.architecture

                    debian_pkg_name = debian_name(pkginfo)

                    if options[:force_update]
                        dirname = packaging_dir(pkginfo)
                        if File.directory?(dirname)
                            Packager.info "Debian: rebuild requested -- removing #{dirname}"
                            FileUtils.rm_rf(dirname)
                        end
                    end

                    options[:packaging_dir] = packaging_dir(pkginfo)
                    options[:release_name] = rock_release_name

                    begin
                        # Set the current pkginfo to set the install directory
                        # correctly
                        # FIXME: needs to be refactored
                        #
                        @packager_lock.lock
                        @current_pkg_info = pkginfo

                        pkginfo = prepare_source_dir(pkginfo, options.merge(unknown_options))

                        if pkginfo.build_type == :orogen || pkginfo.build_type == :cmake || pkginfo.build_type == :autotools
                            package_default(pkginfo, options)
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
                    ensure
                        @current_pkg_info = nil
                        @packager_lock.unlock
                    end
                end

                # Package the given meta package
                # if an existing source directory is given this will be used
                # for packaging, otherwise the package will be bootstrapped
                def package_meta(name, depend,
                                 version: "0.1",
                                 force_update: false,
                                 distribution: nil,
                                 architecture: nil)

                    debian_pkg_name = debian_meta_name(name)

                    if force_update
                        dirname = packaging_dir(debian_pkg_name)
                        if File.directory?(dirname)
                            Packager.info "Debian: rebuild requested -- removing #{dirname}"
                            FileUtils.rm_rf(dirname)
                        end
                    end

                    distribution ||= target_platform.distribution_release_name
                    architecture ||= target_platform.architecture
                    packaging_dir = packaging_dir(debian_pkg_name)

                    if not File.directory?(packaging_dir)
                        FileUtils.mkdir_p packaging_dir
                    end

                    package_deb_meta(name, depend,
                                     version: version,
                                     distribution: distribution,
                                     packaging_dir: packaging_dir)
                end

                def package_ruby(pkginfo, options)
                    require_relative '../gem/package2gem'
                    package2gem = Apaka::Packaging::Gem::Package2Gem.new(options)
                    gem_path = package2gem.convert_package(pkginfo,
                                                           packaging_dir(pkginfo),
                                                           gem_name: Deb.canonize(pkginfo.name),
                                                           patch_dir: options[:patch_dir]
                                                          )

                    require_relative 'gem2deb'
                    gem2deb = Deb::Gem2Deb.new(options)
                    gem2deb.convert_package(gem_path, pkginfo, options)
                end

                # Update the debian directory with overlay and env.sh/env.yml
                # @return [Array] Array with three filenames: [ *.debian.tar.gz, *orig.tar.gz, *.dsc]
                def update_debian_dir(pkginfo, options)
                    # Generate the debian directory
                    generate_debian_dir(pkginfo, pkginfo.srcdir, options)

                    if options[:patch_dir] && File.exist?(options[:patch_dir])
                        if patch_pkg_dir(pkginfo.name, options[:patch_dir],
                                whitelist: nil,
                                pkg_dir: pkginfo.srcdir,
                                options: patch_options())
                            Packager.warn "Overlay patch applied to #{pkginfo.name}"
                        end
                        Dir.chdir(pkginfo.srcdir) do
                            process_apaka_control("apaka.control")
                        end
                    end

                    dpkg_commit_changes("overlay", pkginfo.srcdir,
                                        logfile: options[:logfile],
                                        include_removal: true)

                    envyml = File.join(pkginfo.srcdir, "env.yml")
                    Packager.warn("Preparing env.yml #{envyml}")
                    patch_yml = {}
                    if File.exists?(envyml)
                        patch_yml = YAML.load_file(envyml)
                    end

                    env_data = pkginfo.generate_env_data("APAKA__" + Packaging.as_var_name(pkginfo.name), rock_install_directory, base_data: patch_yml)
                    File.open(envyml, "w") do |file|
                        file.write(env_data.to_yaml)
                    end
                    dpkg_commit_changes("envyml", pkginfo.srcdir,
                                        logfile: options[:logfile])


                    envsh = File.join(pkginfo.srcdir, "env.sh")
                    Packager.warn("Preparing env.sh #{envsh}")
                    File.open(envsh, "w") do |file|
                        env_txt = pkginfo.envsh(env_data)
                        file.write(env_txt)
                    end
                    dpkg_commit_changes("envsh", pkginfo.srcdir,
                                        logfile: options[:logfile])


                    # Run dpkg-source
                    # Use the new tar ball as source
                    if !system("dpkg-source", "-I", "-b", pkginfo.srcdir,
                            [:out, :err] => redirection(options[:logfile],"a"),
                            :close_others => true)
                        Packager.warn "Package: #{pkginfo.name} failed to perform dpkg-source -- #{Dir.entries(pkginfo.srcdir)}"
                        raise RuntimeError, "Debian: #{pkginfo.name} failed to perform dpkg-source in #{pkginfo.srcdir}"
                    end
                    ["#{versioned_name(pkginfo, options[:distribution])}.debian.tar.gz",
                     "#{plain_versioned_name(pkginfo)}.orig.tar.gz",
                     "#{versioned_name(pkginfo, options[:distribution])}.dsc"]
                end

                def package_default(pkginfo, options)
                    Packager.info "Package Deb: '#{pkginfo.name}' with options: #{options}"

                    options, unknown_options = Kernel.filter_options options,
                        :patch_dir => nil,
                        :distribution => nil,
                        :architecture => nil,
                        :logfile => File.join(self.log_dir, "#{debian_name(pkginfo)}-apaka-package.log")

                    Autoproj.message "Perform packaging: including patching and running dpkg-source (see #{options[:logfile]})", :green

                    distribution = options[:distribution]

                    Packager.info "Changing into packaging dir: #{packaging_dir(pkginfo)}"
                    Dir.chdir(packaging_dir(pkginfo)) do
                        sources_name = plain_versioned_name(pkginfo)
                        # First, generate the source tarball
                        tarball = "#{sources_name}.orig.tar.gz"

                        # Check first if actual source contains newer information than existing
                        # orig.tar.gz -- only then we create a new debian package
                        package_with_update = false
                        if package_updated?(pkginfo)

                            Packager.warn "Package: #{pkginfo.name} requires update #{pkginfo.srcdir}"

                            if !tar_gzip(File.basename(pkginfo.srcdir), tarball,
                                    pkginfo.latest_commit_time, distribution,
                                        logfile: options[:logfile])
                                raise RuntimeError, "Debian: #{pkginfo.name} failed to create archive"
                            end
                            package_with_update = true
                        else
                            Packager.info "Package: #{pkginfo.name} (*.orig.tar.gz) does not require update #{pkginfo.srcdir}"
                        end

                        dsc_files = reprepro.registered_files(versioned_name(pkginfo, distribution),
                                                  rock_release_name,
                                                  "*#{target_platform.distribution_release_name}.dsc")

                        if package_with_update || dsc_files.empty?
                            update_debian_dir(pkginfo, options)
                        else
                            Packager.info "Package: #{pkginfo.name} is up to date"
                        end
                        FileUtils.rm_rf( File.basename(pkginfo.srcdir) )
                    end
                end

                def package_importer(pkginfo, options)
                    require_relative 'importer2deb'
                    importer = Packaging::Deb::Importer2Deb.new(options)
                    importer.package(pkginfo, options)
                end

                def package_deb_meta(name, depend,
                                     version: "0.1",
                                     distribution: nil,
                                     packaging_dir: nil)

                    Packager.info "Package Deb meta: '#{name}' for distribution: #{distribution},"
                        "packaging_dir: #{packaging_dir}"
                    raise ArgumentError, "#{self.class}.package_deb_meta: missing packaging_dir" unless packaging_dir

                    Packager.info "Changing into packaging dir: #{packaging_dir}"
                    pkg_dir = File.join(packaging_dir, "#{name}-#{version}")
                    if not File.directory?(pkg_dir)
                        FileUtils.mkdir_p pkg_dir
                    end

                    logfile = File.join(self.log_dir, "#{debian_meta_name(name)}-apaka-package.log")
                    Dir.chdir(pkg_dir) do
                        # Generate the debian directory as a subdirectory of meta
                        generate_debian_dir_meta(name, depend,
                                                 version: version,
                                                 distribution: distribution)

                        File.open("env.sh","w") do |file|
                            depend.each do |debian_pkg_name|
                                envsh = File.join(rock_install_directory(package_name: debian_pkg_name), "env.sh")
                                file.write ". #{envsh}\n"
                            end
                        end
                        dpkg_commit_changes("envsh", logfile: logfile)

                        # Run dpkg-source
                        # Use the new tar ball as source
                        if !system("dpkg-source", "-I", "-b", ".", :close_others => true)
                            Packager.warn "Package: #{name} failed to perform dpkg-source -- #{Dir.entries("meta")}"
                            raise RuntimeError, "Debian: #{name} failed to perform dpkg-source in meta"
                        end
                    end

                    ["#{name}.debian.tar.gz",
                     "#{name}.orig.tar.gz",
                     "#{name}.dsc"]
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

                # Install package name, where pkg is the debian package name
                def install(pkg_name)
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

                # We create a diff between the existing orig.tar.gz and the source directory
                # to identify if there have been any updates
                #
                # Using 'diff' allows us to apply this test to all kind of packages
                def package_updated?(pkginfo)
                    # append underscore to make sure version definition follows
                    registered_orig_tar_gz = reprepro.registered_files(debian_name(pkginfo) + "_",
                                                 rock_release_name,
                                                 "*.orig.tar.gz")
                    orig_file_names = Dir.glob("#{debian_name(pkginfo)}*.orig.tar.gz")
                    orig_file_names.each do |file|
                        FileUtils.rm file
                    end

                    if registered_orig_tar_gz.empty?
                        Packager.info "Apaka::Packaging::Debian::package_updated?: no existing orig.tar.gz found in reprepro"
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
                        raise RuntimeError, "Multiple versions of package #{debian_name(pkginfo)} in #{Dir.pwd} -- you have to fix this first"
                    else
                        orig_file_name = orig_file_name.first
                    end

                    !equal_pkg_content?(pkginfo, orig_file_name)
                end

                def file_suffix_patterns
                    DEB_ARTIFACTS_SUFFIXES
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
                        setup += Regexp.escape("ruby_ver=$(shell ruby -r rbconfig -e ") + "\\\"print RbConfig::CONFIG[\'ruby_version\']\\\")" + Regexp.escape("\n")
                        setup += Regexp.escape("ruby_arch_dir=$(shell ruby -r rbconfig -e ") + "\\\"print RbConfig::CONFIG[\'archdir\']\\\")" + Regexp.escape("\n")
                        setup += Regexp.escape("ruby_libdir=$(shell ruby -r rbconfig -e ") + "\\\"print RbConfig::CONFIG[\'rubylibdir\']\\\")" + Regexp.escape("\n")

                        setup += Regexp.escape("rockruby_archdir=$(subst /usr,,$(ruby_arch_dir))\n")
                        setup += Regexp.escape("rockruby_libdir=$(subst /usr,,$(ruby_libdir))\n")
                    else
                        setup = "arch=$(shell gcc -print-multiarch)\n"
                        # Extract the default ruby version to build for on that platform
                        # this assumes a proper setup of /usr/bin/ruby
                        setup += "ruby_ver=$(shell ruby -r rbconfig -e \"print RbConfig::CONFIG[\'ruby_version\']\")\n"
                        setup += "ruby_arch_dir=$(shell ruby -r rbconfig -e \"print RbConfig::CONFIG[\'archdir\']\")\n"
                        setup += "ruby_libdir=$(shell ruby -r rbconfig -e \"print RbConfig::CONFIG[\'rubylibdir\']\")\n"

                        setup += "rockruby_archdir=$(subst /usr,,$(ruby_arch_dir))\n"
                        setup += "rockruby_libdir=$(subst /usr,,$(ruby_libdir))\n"
                    end
                    Packager.info "Ruby env setup is:\n#{setup}"
                    setup
                end

                # Define the default compat level
                def set_compat_level(compatlevel = DEBHELPER_DEFAULT_COMPAT_LEVEL, compatfile = "debian/compat")
                    if !File.exist?(compatfile)
                        raise ArgumentError, "Apaka::Packaging::Debian::set_compat_level: could not find file '#{compatfile}', working directory is: '#{Dir.pwd}'"
                    end
                    existing_compatlevel = `cat #{compatfile}`.strip
                    Packager.info "Setting debian compat level to: #{compatlevel} (previous setting was #{existing_compatlevel})"
                    `echo #{compatlevel} > #{compatfile}`
                end

                def env_setup(install_prefix: nil)
                    @env.create_setup(install_prefix: install_prefix)
                end

                def env_create_exports(install_prefix: "$(debian_install_prefix)")
                    @env.create_exports(install_prefix: install_prefix)
                end

                # Compute the build dependencies for a packag info object
                # return [Array] list of dependencies
                #
                def build_dependencies(pkginfo)
                    dependencies = []
                    pkgdeps = pkginfo.dependencies
                    deps = pkgdeps[:rock_pkginfo].select do |pkginfo|
                        pkg_name = debian_name(pkginfo, true)
                        !rock_release_platform.ancestorContains(pkg_name)
                    end .map { |p| p.name }

                    gems = pkgdeps[:nonnative].select do |gem,version|
                            pkg_ruby_name = debian_ruby_name(gem, false)
                            pkg_prefixed_name = debian_ruby_name(gem, true)

                            !( rock_release_platform.ancestorContains(gem) ||
                               rock_release_platform.ancestorContains(pkg_ruby_name) ||
                               rock_release_platform.ancestorContains(pkg_prefixed_name))
                    end .map{ |p| p[0] }

                    deps.concat(gems)
                    deps
                end
            end
        end
    end
end
