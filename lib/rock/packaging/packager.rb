require 'autoproj'
require 'autobuild'

module Autoproj
    module Packaging
        # Directory for temporary data to
        # validate obs_packages
        BUILD_DIR=File.join(Autoproj.root_dir, "build/rock-packager")
        LOG_DIR=File.join(BUILD_DIR, "logs")
        LOCAL_TMP = File.join(BUILD_DIR,".rock_packager")
        WWW_ROOT = File.join("/var/www")
        DEB_REPOSITORY=File.join(WWW_ROOT,"rock-reprepro")
        TEMPLATES_DIR=File.expand_path(File.dirname(__FILE__),"templates")
        CACHE_DIR=File.join(BUILD_DIR,"cache")

        EXCLUDED_DIRS_PREFIX = [".travis","build","tmp","debian",".autobuild",".orogen"]
        EXCLUDED_FILES_PREFIX = [".git",".travis",".orogen",".autobuild"]

        class Packager
            extend Logger::Root("Packager", Logger::INFO)

            attr_accessor :build_dir
            attr_accessor :log_dir
            attr_accessor :local_tmp_dir
            attr_accessor :deb_repository

            def initialize
                @build_dir = BUILD_DIR
                @log_dir = LOG_DIR
                @local_tmp_dir = LOCAL_TMP
                @deb_repository = DEB_REPOSITORY
            end

            # Initialize the reprepro repository
            #
            def initialize_reprepro_conf_dir(release_prefix)
                conf_dir = File.join(deb_repository, release_prefix, "conf")
                if File.exist? conf_dir
                    Packager.info "Reprepo repository exists: #{conf_dir}"
                else
                    Packager.info "Initializing reprepo repository in #{conf_dir}"
                    `sudo mkdir -p #{conf_dir}`

                    user = ENV['USER']
                    `sudo chown -R #{user} #{deb_repository}`
                    `sudo chmod -R 755 #{conf_dir}`
                end

                distributions_file = File.join(conf_dir, "distributions")
                if !File.exists?(distributions_file)
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

                initialize_reprepro_conf_dir(release_prefix)

                # Check if Packages file exists: /var/www/rock-reprepro/local/dists/jessie/main/binary-amd64/Packages
                # other initialize properly
                packages_file = File.join(deb_repository,release_prefix,"dists",target_platform.distribution_release_name,"main",
                                          "binary-#{target_platform.architecture}","Packages")
                if !File.exist?(packages_file)
                    reprepro_dir = File.join(deb_repository, release_prefix)
                    logfile = File.join(log_dir,"reprepro-init.log")
                    cmd = "#{reprepro_bin} -V -b #{reprepro_dir} export #{target_platform.distribution_release_name} > #{logfile} 2> #{logfile}"
                    Packager.info "Initialize distribution #{target_platform.distribution_release_name} : #{cmd}"
                    if !system(cmd)
                        Packager.info "Execution of #{cmd} failed -- see #{logfile}"
                    end
                    cmd = "#{reprepro_bin} -V -b #{reprepro_dir} flood #{target_platform.distribution_release_name} #{target_platform.architecture} >"
                    logfile = File.join(log_dir,"reprepro-flood.log")
                    Packager.info "Flood #{target_platform.distribution_release_name} and #{target_platform.architecture} > #{logfile} 2> #{logfile}"
                    if !system(cmd)
                        Packager.info "Execution of #{cmd} failed -- see #{logfile}"
                    end
                else
                    Packager.info "File: #{packages_file} exists"
                end
            end

            # Get the reprepro binary and install the rerepo package if not
            # already present
            def reprepro_bin
                reprepro = `which reprepro`
                if $?.exitstatus != 0
                    Packager.warn "Autoinstalling 'reprepro' for managing the debian package repository"
                   `sudo apt-get install reprepro`
                   reprepro = `which reprepro`
                end
                reprepro.strip
            end

            # Register the debian package for the given package and codename (= distribution)
            # (=distribution)
            # using reprepro
            def register_debian_package(debian_pkg_file, release_name, codename, force = false)
                reprepro_dir = File.join(deb_repository, release_name)

                debian_package_dir = File.dirname(debian_pkg_file)
                # get the basename, e.g., from rock-local-base-cmake_0.20160928-1~xenial_amd64.deb
                debian_pkg_name = File.basename(debian_pkg_file).split("_").first
                logfile = File.join(log_dir,"#{debian_pkg_name}-reprepro.log")

                if force
                    deregister_debian_package(debian_pkg_name, release_name, codename, true)
                end

                Dir.chdir(debian_package_dir) do
                    debfile = Dir.glob("*.deb").first
                    cmd = "#{reprepro_bin} -V -b #{reprepro_dir} includedeb #{codename} #{debfile} >> #{logfile} 2> #{logfile}"
                    Packager.info "Register deb file: #{cmd}"
                    if !system(cmd)
                        raise RuntimeError, "Execution of #{cmd} failed -- see #{logfile}"
                    end

                    dscfile = Dir.glob("*.dsc").first
                    cmd = "#{reprepro_bin} -V -b #{reprepro_dir} includedsc #{codename} #{dscfile} >> #{logfile} 2>> #{logfile}"
                    Packager.info "Register dsc file: #{cmd}"
                    if !system(cmd)
                        raise RuntimeError, "Execution of #{cmd} failed -- see #{logfile}"
                    end
                end
            end

            # Register a debian package
            def deregister_debian_package(pkg_name_expression, release_name, codename, exactmatch = false)
                reprepro_dir = File.join(deb_repository, release_name)
                logfile = File.join(log_dir,"deregistration-reprepro-#{release_name}-#{codename}.log")

                if exactmatch
                    cmd = "#{reprepro_bin} -V -b #{reprepro_dir} remove #{codename} '#{pkg_name_expression}' >> #{logfile} 2>> #{logfile}"
                else
                    cmd = "#{reprepro_bin} -V -b #{reprepro_dir} removematched #{codename} '#{pkg_name_expression}' >> #{logfile} 2>> #{logfile}"
                end
                system("echo #{cmd} >> #{logfile}")
                Packager.info "Remove existing package matching '#{pkg_name_expression}': #{cmd}"
                if !system(cmd)
                    Packager.info "Execution of #{cmd} failed -- see #{logfile}"
                else
                    cmd = "#{reprepro_bin} -V -b #{reprepro_dir} deleteunreferenced >> #{logfile} 2>> #{logfile}"
                    system("echo #{cmd} >> #{logfile}")
                    system(cmd)
                end
            end

            # Check if the given package in available in reprepro for the given
            # architecture
            def reprepro_has_package?(debian_pkg_name, release_name, codename, arch)
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
            end

            def remove_excluded_dirs(target_dir, excluded_dirs = EXCLUDED_DIRS_PREFIX)
                Dir.chdir(target_dir) do
                    excluded_dirs.each do |excluded_dir|
                        Dir.glob("**/#{excluded_dir}*/").each do |remove_dir|
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
                        Dir.glob("**/#{excluded_file}*").each do |excluded_file|
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

            # Prepare source directory and provide and pkg with update importer
            # information
            # return Autobuild package with update importer definition
            # reflecting the local checkout
            def prepare_source_dir(orig_pkg, options = Hash.new)
                pkg = orig_pkg.dup

                options, unknown_options = Kernel.filter_options options,
                    :existing_source_dir => nil,
                    :packaging_dir => File.join(@build_dir, debian_name(pkg))

                pkg_dir = options[:packaging_dir]
                if not File.directory?(pkg_dir)
                    FileUtils.mkdir_p pkg_dir
                end

                Packager.debug "Preparing source dir #{pkg.name}"
                if existing_source_dir = options[:existing_source_dir] || !pkg.importer
                    if !pkg.importer
                        existing_source_dir = pkg.srcdir
                    end

                    Packager.info "Preparing source dir #{pkg.name} from existing: '#{existing_source_dir}'"

                    target_dir = File.join(pkg_dir, dir_name(pkg, target_platform.distribution_release_name))
                    FileUtils.cp_r existing_source_dir, target_dir
                    pkg.srcdir = target_dir

                    remove_excluded_dirs(target_dir)
                    remove_excluded_files(target_dir)
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
                            Packager.debug "Using locally available git repository of '#{pkg.name}' -- '#{pkg.srcdir}'"
                        end
                        pkg.importer.repository = pkg.srcdir
                    end
                    pkg_target_importdir = File.join(pkg_dir, plain_dir_name(pkg, target_platform.distribution_release_name))

                    # Some packages, e.g. mars use a single git repository a split it artificially
                    # if this is the case, try to copy the content instead of doing a proper checkout
                    if pkg.srcdir != pkg.importdir
                        Packager.debug "Importing repository from #{pkg.srcdir} to #{pkg_target_importdir}"
                        FileUtils.mkdir_p pkg_target_importdir
                        FileUtils.cp_r File.join(pkg.srcdir,"/."), pkg_target_importdir
                        # Update resulting source directory
                        pkg.srcdir = pkg_target_importdir
                    else
                        pkg.srcdir = pkg_target_importdir
                        begin
                            Packager.debug "Importing repository to #{pkg.srcdir}"
                            # Workaround for bug in autoproj:
                            # archive_dir should be set from pkg.srcdir, but is actually set from pkg.name
                            # see autobuild-1.9.3/lib/autobuild/import/archive.rb +406
                            if pkg.importer.kind_of?(Autobuild::ArchiveImporter)
                                pkg.importer.options[:archive_dir] ||= File.basename(pkg.srcdir)
                            end
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
                pkg
            end

            def self.obs_package_name(pkg)
                "rock-" + pkg.name.gsub(/[\/_]/, '-').downcase
            end
        end # Packager
    end # Packaging
end #Autoproj

