require 'utilrb/logger'
require 'thread'
require 'etc'

module Apaka
    module Packaging
        # Directory for temporary data to
        # validate obs_packages
        WWW_ROOT = File.join("/var/www")
        DEB_REPOSITORY=File.join(WWW_ROOT,"apaka-releases")
        TEMPLATES_DIR=File.join(File.expand_path(File.dirname(__FILE__)),"templates")

        EXCLUDED_DIRS_PREFIX = ["**/.travis","build","tmp","debian","**/.autobuild","**/.orogen"]
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
        
        class Packager
            extend Logger::Root("Packager", Logger::INFO)

            # tests need to write this
            attr_accessor :build_dir
            attr_reader :log_dir
            attr_reader :local_tmp_dir
            attr_reader :deb_repository
            attr_reader :target_platform

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

            # Initialize the reprepro repository
            #
            def initialize_reprepro_conf_dir(release_prefix)
                if !@reprepro_lock.owned?
                    raise ThreadError.new
                end
                
                conf_dir = File.join(deb_repository, release_prefix, "conf")
                if File.exist? conf_dir
                    Packager.info "Reprepo repository exists: #{conf_dir}"
                else
                    Packager.info "Initializing reprepo repository in #{conf_dir}"
                    system("sudo", "mkdir", "-p", conf_dir, :close_others => true)

                    user = Etc.getpwuid(Process.uid).name
                    system("sudo", "chown", "-R", user, deb_repository, :close_others => true)
                    system("sudo", "chmod", "-R", "755", conf_dir, :close_others => true)
                end

                distributions_file = File.join(conf_dir, "distributions")
                if !File.exist?(distributions_file)
                    File.open(distributions_file,"w") do |f|
                        Config.linux_distribution_releases.each do |release_name, release|
                            f.write("Codename: #{release_name}\n")
                            f.write("Architectures: #{Config.architectures.keys.join(" ")} source\n")
                            f.write("Components: main\n")
                            f.write("UDebComponents: main\n")
                            f.write("Tracking: minimal\n")
                            f.write("Contents:\n\n")
                        end
                    end
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
                        dirname = File.join(log_dir,target_platform.to_s("-"))
                        if !File.directory?(dirname)
                            FileUtils.mkdir_p dirname
                        end
                        logfile = File.join(dirname,"reprepro-init.log")

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
                    # get the basename, e.g., from rock-local-base-cmake_0.20160928-1~xenial_amd64.deb
                    debian_pkg_name = File.basename(debian_pkg_file).split("_").first
                    logfile = File.join(log_dir,"#{debian_pkg_name}-reprepro.log")

                    if force
                        deregister_debian_package(debian_pkg_name, release_name, codename, true)
                    end

                    @reprepro_lock.lock
                    Dir.chdir(debian_package_dir) do
                        debfile = Dir.glob("*.deb").first
                        cmd = [reprepro_bin]
                        cmd << "-V" << "-b" << reprepro_dir <<
                            "includedeb" << codename << debfile

                        Packager.info "Register deb file: #{cmd.join(" ")} &>> #{logfile}"
                        if !system(*cmd, [:out, :err] => [logfile, "a"], :close_others => true)
                            raise RuntimeError, "Execution of #{cmd.join(" ")} failed -- see #{logfile}"
                        end

                        dscfile = Dir.glob("*.dsc").first
                        cmd = [reprepro_bin]
                        cmd << "-V" << "-b" << reprepro_dir <<
                            "includedsc" << codename <<  dscfile
                        Packager.info "Register dsc file: #{cmd.join(" ")} &>> #{logfile}"
                        if !system(*cmd, [:out, :err] => [logfile, "a"], :close_others => true)
                            raise RuntimeError, "Execution of #{cmd.join(" ")} failed -- see #{logfile}"
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

            # Check if the given package in available in reprepro for the given
            # architecture
            def reprepro_has_package?(debian_pkg_name, release_name, codename, arch)
                @reprepro_lock.lock

                begin
                    reprepro_dir = File.join(deb_repository, release_name)
                    cmd = "#{reprepro_bin} -V -b #{reprepro_dir} list #{codename} #{debian_pkg_name} | grep #{arch}"
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

            def self.obs_package_name(pkginfo)
                "rock-" + pkginfo.name.gsub(/[\/_]/, '-').downcase
            end
        end # Packager
    end # Packaging
end # Apaka

