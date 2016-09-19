require 'autoproj'
require 'autobuild'

module Autoproj
    module Packaging
        # Directory for temporary data to
        # validate obs_packages
        BUILD_DIR=File.join(Autoproj.root_dir, "build/rock-packager")
        LOG_DIR=File.join(BUILD_DIR, "logs")
        LOCAL_TMP = File.join(BUILD_DIR,".rock_packager")
        DEB_REPOSITORY=File.join(Autoproj.root_dir, "build/rock-reprepro")

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
            def initialize_reprepro_repository
                dir = deb_repository
                conf_dir = File.join(dir,"conf")
                FileUtils.mkdir_p conf_dir

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

            # Register the debian package for the given package and codename
            # (=distribution)
            # using reprepro
            def register_debian_package(debian_pkg_name, codename)
                dir = deb_repository

                debian_package_dir = File.join(build_dir, debian_pkg_name)
                logfile = File.join(log_dir,"#{debian_pkg_name}-reprepro.log")

                cmd = "#{reprepro_bin} -V -b #{dir} remove #{codename} #{debian_pkg_name} > #{logfile} 2> #{logfile}"
                Packager.info "Remove existing package '#{debian_pkg_name}': #{cmd}"
                if !system(cmd)
                    Packager.info "Execution of #{cmd} failed -- see #{logfile}"
                end

                Dir.chdir(debian_package_dir) do
                    debfile = Dir.glob("*.deb").first
                    cmd = "#{reprepro_bin} -V -b #{dir} includedeb #{codename} #{debfile} >> #{logfile} 2> #{logfile}"
                    Packager.info "Register deb file: #{cmd}"
                    if !system(cmd)
                        raise RuntimeError, "Execution of #{cmd} failed -- see #{logfile}"
                    end

                    dscfile = Dir.glob("*.dsc").first
                    cmd = "#{reprepro_bin} -V -b #{dir} includedsc #{codename} #{dscfile} >> #{logfile} 2>> #{logfile}"
                    Packager.info "Register dsc file: #{cmd}"
                    if !system(cmd)
                        raise RuntimeError, "Execution of #{cmd} failed -- see #{logfile}"
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

            def prepare_source_dir(pkg, options = Hash.new)
                options, unknown_options = Kernel.filter_options options,
                    :existing_source_dir => nil

                Packager.debug "Preparing source dir #{pkg.name}"
                if existing_source_dir = options[:existing_source_dir] || !pkg.importer
                    if !pkg.importer
                        existing_source_dir = pkg.srcdir
                    end

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
                    pkg_target_importdir = File.join(@build_dir, debian_name(pkg), plain_dir_name(pkg, target_platform.distribution_release_name))

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
            end

            def self.obs_package_name(pkg)
                "rock-" + pkg.name.gsub(/[\/_]/, '-').downcase
            end
        end # Packager
    end # Packaging
end #Autoproj

