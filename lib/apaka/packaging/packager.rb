require 'utilrb/logger'
require 'thread'
require 'etc'
require_relative 'target_platform'
require_relative 'reprepro/distributions_config'

module Apaka
    module Packaging
        # Directory for temporary data to
        # validate obs_packages
        WWW_ROOT = File.join("/var/www")
        DEB_REPOSITORY=File.join(WWW_ROOT,"apaka-releases")
        TEMPLATES_DIR=File.join(File.expand_path(File.dirname(__FILE__)),"templates")

        EXCLUDED_DIRS_PREFIX = ["**/.travis","build","tmp","debian","**/.autobuild","**/.orogen","**/build"]
        EXCLUDED_FILES_PREFIX = ["**/.git","**/.travis","**/.orogen","**/.autobuild"]

        extend Logger::Root("Packaging", Logger::INFO)

        def self.root_dir= (dir)
            @root_dir = dir
        end

        def self.root_dir
            @root_dir
        end

        def self.build_dir
            File.join(root_dir, "build", "apaka-packager")
        end
        
        def self.cache_dir
            File.join(build_dir, "cache")
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

        def system(*args)
            Kernel.system(*args)
        end

        # Extract the base name from a path description
        # e.g. tools/metaruby => metaruby
        def self.basename(name)
            File.basename(name)
        end

        # Convert given lower case variable with dash as separators
        # to environment var, e.g., package-name => PACKAGE_NAME
        def self.as_var_name(name)
            name.gsub(/[\/-]/, '_').upcase
        end

        
        class Packager
            extend Logger::Root("Packager", Logger::INFO)

            # tests need to write this
            attr_accessor :build_dir
            attr_reader :log_dir
            attr_reader :local_tmp_dir
            attr_reader :deb_repository
            attr_reader :target_platform

            # Initialize the packager
            # @options
            #     :distribution [String] representation of a linux distribution,
            #         e.g., bionic, trusty, etc. which have to be configure in the
            #         configuration file
            #     :architecture [String] representation of an architecture:
            #         amd64, i386, arm64, armel, armhf
            def initialize(options = Hash.new)
                options, unknown_options = Kernel.filter_options options,
                    :distribution => TargetPlatform.autodetect_linux_distribution_release,
                    :architecture => TargetPlatform.autodetect_dpkg_architecture

                @target_platform = TargetPlatform.new(options[:distribution], options[:architecture])

                @build_dir = Apaka::Packaging.build_dir
                @log_dir = File.join(@build_dir, "logs",
                                     @target_platform.distribution_release_name, @target_platform.architecture)
                @local_tmp_dir = File.join(@build_dir, ".apaka_packager",
                                     @target_platform.distribution_release_name, @target_platform.architecture)
                @deb_repository = DEB_REPOSITORY
                @reprepro_lock = Mutex.new

                [@build_dir, @log_dir, @local_tmp_dir].each do |dir|
                    if not File.directory?(dir)
                        FileUtils.mkdir_p dir
                    end
                end
            end

            # Initialize or update the reprepro repository
            #
            def initialize_reprepro_conf_dir(release_prefix)
                if !@reprepro_lock.owned?
                    raise ThreadError.new
                end
                
                conf_dir = File.join(deb_repository, release_prefix, "conf")
                if File.exist? conf_dir
                    Packager.info "Reprepo repository exists: #{conf_dir} - updating"
                else
                    Packager.info "Initializing reprepo repository in #{conf_dir}"
                    system("sudo", "mkdir", "-p", conf_dir, :close_others => true)

                    user = Etc.getpwuid(Process.uid).name
                    Packager.info "Set owner #{user} for #{deb_repository}"
                    system("sudo", "chown", "-R", user, deb_repository, :close_others => true)
                    system("sudo", "chown", "-R", user, deb_repository + "/", :close_others => true)
                    system("sudo", "chmod", "-R", "755", conf_dir, :close_others => true)
                end

                distributions_file = File.join(conf_dir, "distributions")
                distributions_conf = nil
                if !File.exist?(distributions_file)
                    distributions_config = Reprepro::DistributionsConfig.new
                    Config.active_distributions.each do |release_name|
                        rc = Reprepro::ReleaseConfig.new
                        rc.codename = release_name
                        rc.architectures = ["amd64","i386","armel","armhf","arm64","source"]
                        rc.sign_with = Config.sign_with
                        rc.components = "main"
                        rc.udeb_components = "main"
                        rc.tracking = "minimal"

                        distributions_config.releases[rc.codename] = rc
                    end
                else
                    distributions_config = Reprepro::DistributionsConfig.load(distributions_file)
                    Config.active_distributions.each do |release_name|
                        rc = Reprepro::ReleaseConfig.new
                        rc.codename = release_name
                        rc.architectures = ["amd64","i386","armel","armhf","arm64","source"]
                        rc.sign_with = Config.sign_with
                        rc.components = "main"
                        rc.udeb_components = "main"
                        rc.tracking = "minimal"

                        distributions_config.releases[rc.codename] = rc
                    end
                end
                distributions_config.save(distributions_file)
                reprepro_dir = File.join(deb_repository, release_prefix)
                cmd = [reprepro_bin]
                cmd << "-V" << "-b" << reprepro_dir << "clearvanished"
                Packager.info "reprepro: updating conf/distributions and clearing vanished"
                logfile = File.join(log_dir,"reprepro-init.log")
                if !system(*cmd, [:out, :err] => logfile, :close_others => true)
                    Packager.info "Execution of #{cmd.join(" ")} failed -- see #{logfile}"
                end
            end

            def initialize_reprepro_repository(release_prefix)
                @reprepro_lock.lock
                begin

                    initialize_reprepro_conf_dir(release_prefix)

                    # Check if Packages file exists: /var/www/apaka-releases/local/dists/jessie/main/binary-amd64/Packages
                    # other initialize properly
                    packages_file = File.join(deb_repository,release_prefix,"dists",target_platform.distribution_release_name,"main",
                                              "binary-#{target_platform.architecture}","Packages")
                    if !File.exist?(packages_file)
                        reprepro_dir = File.join(deb_repository, release_prefix)
                        logfile = File.join(log_dir,"reprepro-init.log")

                        cmd = [reprepro_bin]
                        cmd << "-V" << "-b" << reprepro_dir <<
                            "export" << target_platform.distribution_release_name
                        Packager.info "Initialize distribution #{target_platform.distribution_release_name} : #{cmd.join(" ")} &> #{logfile}"
                        if !system(*cmd, [:out, :err] => logfile, :close_others => true)
                            Packager.info "Execution of #{cmd.join(" ")} failed -- see #{logfile}"
                        end
                        cmd = [reprepro_bin]
                        cmd << "-V" << "-b" << reprepro_dir <<
                            "flood" << target_platform.distribution_release_name <<
                            target_platform.architecture
                        logfile = File.join(log_dir,"reprepro-flood.log")
                        Packager.info "Flood #{target_platform.distribution_release_name} and #{target_platform.architecture}"
                        if !system(*cmd, [:out, :err] => logfile, :close_others => true)
                            Packager.info "Execution of #{cmd.join(" ")} failed -- see #{logfile}"
                        end
                    else
                        Packager.info "File: #{packages_file} exists"
                    end
                ensure
                    @reprepro_lock.unlock
                end
            end

            # Get the reprepro binary and install the rerepo package if not
            # already present
            def reprepro_bin
                reprepro = `which reprepro`
                if $?.exitstatus != 0
                    Packager.warn "Autoinstalling 'reprepro' for managing the debian package repository"
                   system("sudo", "apt-get", "install", "reprepro", :close_others => true)
                   reprepro = `which reprepro`
                end
                reprepro.strip
            end

            # Register the debian package for the given package and codename (= distribution)
            # (=distribution)
            # using reprepro
            def register_debian_package(debian_pkg_file, release_name, codename, force = false)
                begin
                    reprepro_dir = File.join(deb_repository, release_name)

                    debian_package_dir = File.dirname(debian_pkg_file)
                    debfile = File.basename(debian_pkg_file)
                    debian_pkg_name = debfile.split("_").first
                    logfile = File.join(log_dir,"#{debian_pkg_name}-reprepro.log")

                    if force
                        deregister_debian_package(debian_pkg_name, release_name, codename, true)
                    end
                    @reprepro_lock.lock
                    Dir.chdir(debian_package_dir) do
                        if !File.exists?(debfile)
                            raise ArgumentError, "Apaka::Packaging::register_debian_package: could not find '#{debfile}' in directory: '#{debian_package_dir}'"
                        end

                        cmd = [reprepro_bin]
                        cmd << "-V" << "-b" << reprepro_dir <<
                            "includedeb" << codename << debfile

                        Packager.info "Register deb file: #{cmd.join(" ")} &>> #{logfile}"
                        if !system(*cmd, [:out, :err] => [logfile, "a"], :close_others => true)
                            raise RuntimeError, "Execution of #{cmd.join(" ")} failed -- see #{logfile}"
                        end

                        if not reprepro_has_dsc?(debian_pkg_name, release_name, codename, true)
                            dscfile = Dir.glob("*.dsc").first
                            cmd = [reprepro_bin]
                            cmd << "-V" << "-b" << reprepro_dir <<
                                "includedsc" << codename <<  dscfile
                            Packager.info "Register dsc file: #{cmd.join(" ")} &>> #{logfile}"
                            if !system(*cmd, [:out, :err] => [logfile, "a"], :close_others => true)
                                raise RuntimeError, "Execution of #{cmd.join(" ")} failed -- see #{logfile}"
                            end
                        end
                    end
                ensure
                    @reprepro_lock.unlock
                end
            end

            # Register a debian package
            def deregister_debian_package(pkg_name_expression, release_name, codename, exactmatch = false)
                @reprepro_lock.lock

                begin
                    reprepro_dir = File.join(deb_repository, release_name)
                    logfile = File.join(log_dir,"deregistration-reprepro-#{release_name}-#{codename}.log")

                    cmd = [reprepro_bin]
                    cmd << "-V" << "-b" << reprepro_dir

                    if exactmatch
                        cmd << "remove" << codename << pkg_name_expression
                    else
                        cmd << "removematched" << codename << pkg_name_expression
                    end
                    IO::write(logfile, "#{cmd}\n", :mode => "a")
                    Packager.info "Remove existing package matching '#{pkg_name_expression}': #{cmd.join(" ")} &>> #{logfile}"
                    if !system(*cmd, [:out, :err] => [logfile, "a"], :close_others => true)
                        Packager.info "Execution of #{cmd.join(" ")} failed -- see #{logfile}"
                    else
                        cmd = [reprepro_bin]
                        cmd << "-V" << "-b" << reprepro_dir
                        cmd << "deleteunreferenced"
                        IO::write(logfile, "#{cmd}\n", :mode => "a")
                        system(*cmd, [:out, :err] => [logfile, "a"], :close_others => true)
                    end
                ensure
                    @reprepro_lock.unlock
                end
            end

            # Check if the *.dsc file has already been registered for a
            # particular release and codename(=distribution)
            def reprepro_has_dsc?(debian_pkg_name, release_name, codename, reuseLock = false)
                @reprepro_lock.lock unless reuseLock
                begin
                    reprepro_dir = File.join(deb_repository, release_name)
                    cmd = "#{reprepro_bin} -T dsc -V -b #{reprepro_dir} list #{codename} #{debian_pkg_name}"
                    package_info = `#{cmd}`
                    if !package_info.empty?
                        Packager.info "Reprepro: dsc file for #{debian_pkg_name} available for #{codename}"
                        return true
                    else
                        Packager.info "Reprepro: dsc file for #{debian_pkg_name} not available for #{codename}"
                        return false
                    end
                ensure
                    @reprepro_lock.unlock unless reuseLock
                end
            end

            # Check if the given package in available in reprepro for the given
            # architecture
            # @param debian_pkg_name Name of the debian package
            # @release_name name of the package release, e.g., master-18.04
            # @arch name of the architecture
            def reprepro_has_package?(debian_pkg_name, release_name, codename, arch)
                @reprepro_lock.lock

                begin
                    reprepro_dir = File.join(deb_repository, release_name)
                    cmd = "#{reprepro_bin} -A #{arch} -T deb -V -b #{reprepro_dir} list #{codename} #{debian_pkg_name}"
                    package_info = `#{cmd}`
                    if !package_info.empty?
                        Packager.info "Reprepro: #{debian_pkg_name} available for #{codename} #{arch}"
                        return true
                    else
                        Packager.info "Reprepro: #{debian_pkg_name} not available for #{codename} #{arch}"
                        return false
                    end
                ensure
                    @reprepro_lock.unlock
                end
            end

            # Retrieve files from reprepro repository
            def reprepro_registered_files(debian_pkg_name, release_name,
                                         suffix_regexp)
                reprepro_dir = File.join(deb_repository, release_name)
                Dir.glob(File.join(reprepro_dir,"pool","main","**","#{debian_pkg_name}#{suffix_regexp}"))
            end

            def remove_excluded_dirs(target_dir, excluded_dirs = EXCLUDED_DIRS_PREFIX)
                Dir.chdir(target_dir) do
                    excluded_dirs.each do |excluded_dir|
                        Dir.glob("#{excluded_dir}*/").each do |remove_dir|
                            if File.directory?(remove_dir)
                                Packager.info "Removing excluded directory: #{remove_dir}"
                                FileUtils.rm_r remove_dir
                            end
                        end
                    end
                end
            end
            def remove_excluded_files(target_dir, excluded_files = EXCLUDED_FILES_PREFIX)
                Dir.chdir(target_dir) do
                    excluded_files.each do |excluded_file|
                        Dir.glob("#{excluded_file}*").each do |excluded_file|
                            if File.file?(excluded_file)
                                Packager.info "Removing excluded file: #{excluded_file}"
                                FileUtils.rm excluded_file
                            end
                        end
                    end
                end
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

            # Import from a local src directory into the packaging directory for the debian packaging
            def import_from_local_src_dir(pkginfo, local_src_dir, pkg_target_importdir)
                Packager.info "Preparing source dir #{pkginfo.name} from existing: '#{local_src_dir}' -- import into: #{pkg_target_importdir}"
                if !pkginfo.importer_type || !pkginfo.importer_type == :git
                    Packager.info "Package importer requires copying into target directory"
                    FileUtils.cp_r local_src_dir, pkg_target_importdir
                else
                    pkginfo.import(pkg_target_importdir)
                end
            end

            # Prepare source directory and provide and pkg with update importer
            # information
            # return Autobuild package with update importer definition
            # reflecting the local checkout
            def prepare_source_dir(orig_pkginfo, options = Hash.new)
                pkginfo = orig_pkginfo.dup

                options, unknown_options = Kernel.filter_options options,
                    :existing_source_dir => nil,
                    :packaging_dir => File.join(@build_dir, debian_name(pkginfo))

                pkg_dir = options[:packaging_dir]
                if not File.directory?(pkg_dir)
                    FileUtils.mkdir_p pkg_dir
                end

                # Only when there is no importer or when the VCS supports distribution (here git)
                # then we allow to use the local version
                support_local_import = false
                if !pkginfo.importer_type || pkginfo.importer_type == :git
                    Packager.info "Import from local repository is supported for #{pkginfo.name}"
                    support_local_import = true
                else
                    Packager.info "Import from local repository is not supported for #{pkginfo.name}"
                end

                Packager.debug "Preparing source dir #{pkginfo.name}"
                # If we have given an existing source directory we should use it, 
                # but only if it is a git repository
                pkg_target_importdir = File.join(pkg_dir, plain_dir_name(pkginfo))
                if support_local_import && existing_source_dir = options[:existing_source_dir]
                    import_from_local_src_dir(pkginfo, existing_source_dir, pkg_target_importdir)
                    # update to the new srcdir
                    pkginfo.srcdir = pkg_target_importdir
                else
                    pkginfo.import(pkg_target_importdir)
                end
                # remove these even on fresh imports. some repositories
                # have prepopulated build directories and similar
                remove_excluded_dirs(pkg_target_importdir)
                remove_excluded_files(pkg_target_importdir)

                pkginfo
            end

            # Patch a package (in the current working directory) using overlays found in the global_patch_dir
            # Also picks architecture specific patches from the special
            # subdirectory __arch__/<architecture> within the global patch
            # directory.
            #
            # Patches are searched for by the package name and the gem name
            # @return [Bool] true if patches have been applied
            def patch_pkg_dir(package_name, global_patch_dir,
                              whitelist: nil,
                              pkg_dir: Dir.pwd,
                              options: {})
                if global_patch_dir && File.exists?(global_patch_dir)
                    if !package_name
                        raise ArgumentError, "DebianPackager::patch_pkg_dir: package name is required, but was nil"
                    end
                    patched = false
                    pkg_patch_dir = File.join(global_patch_dir, package_name)
                    if File.exist?(pkg_patch_dir)
                        patched ||= patch_directory(pkg_dir, pkg_patch_dir, whitelist: whitelist, options: options)
                    end
                    arch_pkg_patch_dir = File.join(global_patch_dir, "__arch__", target_platform.architecture, package_name)
                    if File.exist?(arch_pkg_patch_dir)
                        patched ||= patch_directory(pkg_dir, arch_pkg_patch_dir, whitelist: whitelist, options: options)
                    end
                    patched
                end
            end

            # Prepare a patch file by dynamically replacing the following
            # placeholder with the actual values
            # @APAKA_INSTALL_DIR@
            # @APAKA_RELEASE_NAME@
            # with the autogenerated one
            def prepare_patch_file(file, options: {})
                if File.file?(file)
                    filetype = `file -b --mime-type #{file} | cut -d/ -f1`.strip
                    if filetype == "text"
                        if options.has_key?(:install_dir) and not options[:skip_install_dir]
                            apaka_install_dir = options[:install_dir]
                            system("sed", "-i", "s#\@APAKA_INSTALL_DIR\@##{apaka_install_dir}#g", file, :close_others => true)
                        end
                        if options.has_key?(:package_dir) and not options[:skip_package_dir]
                            apaka_package_dir = options[:package_dir]
                            system("sed", "-i", "s#\@APAKA_PACKAGE_DIR\@##{apaka_package_dir}#g", file, :close_others => true)
                        end
                        if options.has_key?(:release_name) and not options[:skip_release_name]
                            apaka_release_name = options[:release_name]
                            system("sed", "-i", "s#\@APAKA_RELEASE_NAME\@##{apaka_release_name}#g", file, :close_others => true)
                        end
                        if options.has_key?(:release_dir) and not options[:skip_release_dir]
                            apaka_release_dir = options[:release_dir]
                            system("sed", "-i", "s#\@APAKA_RELEASE_DIR\@##{apaka_release_dir}#g", file, :close_others => true)
                        end
                    end
                end
            end

            # Patch a target directory with the content in patch_dir
            # a whitelist allows to patch only particular files, but by default all files can be patched
            def patch_directory(target_dir, patch_dir,
                                whitelist: nil,
                                options: {})
                 if File.directory?(patch_dir)
                     Packager.warn "Applying overlay (patch) from: #{patch_dir} to #{target_dir}, whitelist: #{whitelist}"
                     if !whitelist
                         Dir.mktmpdir do |dir|
                             FileUtils.cp_r("#{patch_dir}/.", "#{dir}/.")
                             Dir.glob("#{dir}/**/*").each do |file|
                                 prepare_patch_file(file, options: options)
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
                                    prepare_patch_file(tmpfile.path, options: options)
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

            # Create a local copy/backup of the current orig.tar.gz
            # and extract it there
            # Then compare the actual source package with the archive content
            # @return True if the archive has changed compared to the source
            def equal_pkg_content?(pkginfo, archive_filename)
                FileUtils.cp(archive_filename, local_tmp_dir)
                Dir.chdir(local_tmp_dir) do
                    msg, status = Open3.capture2e("tar xzf #{archive_filename}")
                    raise ArgumentError, "#{self}: failed to unpack #{archive_filename}" unless status.success?

                    base_name = archive_filename.gsub(".orig.tar.gz","")
                    Dir.chdir(base_name) do
                        diff_name = File.join(local_tmp_dir, "#{archive_filename}.diff")
                        system("diff", "-urN", "--exclude", ".*", "--exclude", "CVS", "--exclude", "debian", "--exclude", "build", pkginfo.srcdir, ".", :out  => diff_name)
                        Packager.info "Package: '#{pkginfo.name}' checking diff file '#{diff_name}'"
                        if File.open(diff_name).lines.any?
                            return true
                        end
                    end
                end
                return false
            end
        end # Packager
    end # Packaging
end # Apaka

