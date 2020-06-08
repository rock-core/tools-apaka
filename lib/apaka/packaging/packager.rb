require 'utilrb/logger'
require 'thread'
require 'etc'
require_relative 'target_platform'
require_relative 'reprepro'

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
            @root_dir || Autoproj.workspace.root_dir
        end

        def self.build_dir
            File.join(root_dir, "build", "apaka-packager")
        end
        
        def self.cache_dir
            File.join(build_dir, "cache")
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

        def self.default_release_name
            "release-#{Time.now.strftime("%y.%m")}"
        end

        
        class Packager
            extend Logger::Root("Packager", Logger::INFO)

            # tests need to write this
            attr_accessor :build_dir
            attr_reader :log_dir
            attr_reader :local_tmp_dir
            attr_reader :deb_repository
            attr_reader :target_platform
            attr_reader :reprepro

            attr_reader :package_info_ask

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
                @package_info_ask = Apaka::Packaging::PackageInfoAsk.new(:detect, Hash.new())
                root_dir = package_info_ask.root_dir
                Apaka::Packaging::TargetPlatform.osdeps_release_tags = package_info_ask.osdeps_release_tags

                @build_dir = Apaka::Packaging.build_dir
                @log_dir = File.join(@build_dir, "logs",
                                     @target_platform.distribution_release_name, @target_platform.architecture)
                @local_tmp_dir = File.join(@build_dir, ".apaka_packager",
                                     @target_platform.distribution_release_name, @target_platform.architecture)

                @deb_repository = DEB_REPOSITORY

                @reprepro = Reprepro::BaseRepo.new(DEB_REPOSITORY, @log_dir)

                prepare
            end

            # Prepare the build directory, i.e. cleanup and obsolete file
            def prepare
                [@build_dir, @log_dir, @local_tmp_dir].each do |dir|
                    if not File.directory?(dir)
                        FileUtils.mkdir_p dir
                    end
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

            def redirection(logfile, io_mode="w")
                if logfile && logfile.kind_of?(String)
                    [logfile, io_mode]
                else
                    STDOUT
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

