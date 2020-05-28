require_relative 'base'
require 'apaka/packaging/config'

module Apaka
    module CLI
        class Package < Base
            attr_reader :architectures
            attr_reader :distributions

            attr_reader :skip_existing
            attr_reader :build_dir
            attr_reader :dest_dir
            attr_reader :patch_dir
            attr_reader :rebuild
            attr_reader :use_remote_repository
            attr_reader :pkg_set_dir
            attr_reader :package

            attr_reader :meta
            attr_reader :overwrite

            attr_reader :osdeps_list_dir

            attr_reader :flavor
            attr_reader :rock_base_install_dir
            attr_reader :parallel_builds
            attr_reader :exists

            attr_reader :release_name
            attr_reader :package_version

            attr_reader :build_local
            attr_reader :install
            attr_reader :recursive
            attr_reader :activation_status
            attr_reader :config_file
            attr_reader :ancestor_blacklist_pkgs

            attr_reader :preferred_ruby_version
            attr_reader :operating_system
            attr_reader :lock_file
            # Interface to the package information DB
            # currently basically Autoproj
            attr_reader :package_info_ask

            # The packager to use
            attr_reader :packager
            attr_reader :selected_packages
            attr_reader :selected_rock_packages
            attr_reader :selected_gems

            def initialize
                super()

                @architectures = []
                @distributions = []
                @skip = false

                @build_dir = nil
                @dest_dir = nil
                @patch_dir = nil
                @pkg_set_dir = nil

                @rebuild = false
                @use_remote_repository = false
                @package = false
                @meta = nil
                @overwrite = false
                @flavor="master"
                if ENV.has_key?('AUTOPROJ_CURRENT_ROOT')
                    @flavor = ENV['AUTOPROJ_CURRENT_ROOT'].split('/')[-1]
                end

                @parallel_builds = false
                @control_job = false
                @all_control_jobs = false
                @exists = false

                @release_name = nil
                @package_version = nil

                @build_local = false
                @install = false
                @recursive = false

                @ancestor_blacklist_pkgs = Set.new


                @preferred_ruby_version = nil
                @operating_system = nil
                @lock_file = File.open("/tmp/apaka-package.lock",File::CREAT)

                @selected_packages = []
                @selected_rock_package = []
                @selected_gems = []
            end

            def activate_distribution(distribution)
                operating_system = []
                preferred_ruby_version = nil
                if Apaka::Packaging::Config.linux_distribution_releases.has_key?(distribution)
                    operating_system = Apaka::Packaging::Config.linux_distribution_releases[ distribution ]
                else
                    raise CLI::InvalidArguments, "Custom setting of operating system to: #{distribution} is not supported"
                end

                if Apaka::Packaging::Config.preferred_ruby_version.has_key?(distribution)
                    preferred_ruby_version = Apaka::Packaging::Config.preferred_ruby_version[ distribution ]
                end

                if !operating_system.empty?
                    package_info_ask.osdeps_operating_system = operating_system
                    Apaka::Packaging.info "Custom setting of operating system to: #{operating_system}"
                    if preferred_ruby_version
                        package_info_ask.osdeps_set_alias(preferred_ruby_version,"ruby")
                        Apaka::Packaging.info "Setting preferred ruby version: #{preferred_ruby_version}"
                    end
                end
            end

            def extract_selected_packages(package_list)
                gems = []
                packages = package_list.select do |name, version|
                    if package_info_ask.package(name)
                        Apaka::Packaging.warn "Package: #{name} is a known rock package"
                        true
                    elsif Apaka::Packaging::GemDependencies::is_gem?(name)
                        Apaka::Packaging.info "Package: #{name} is a gem"
                        gems << [name, version]
                        false
                    else
                        true
                    end
                end
                [packages, gems]
            end

            def validate_options(args, options)
                Base.activate_configuration(options)

                args, options = Base.validate_options(args, options)
                [:dest_dir, :base_dir, :patch_dir, :config_file, :pkg_set_dir].each do |path_option|
                    Base.validate_path(options, path_option)
                end

                options[:architecture] = validate_architecture(options)
                options[:distribution] = validate_distribution(options)

                @selected_packages = args
                if selected_packages.size > 1 && options[:version]
                    raise InvalidArguments, "Cannot use version option with multiple packages as argument"
                end

                #if the name matches a move target directory, convert to package name
                @selected_packages = selected_packages.map do |name|
                    package_info_ask.moved_packages.each do |pkg_name,target_dir|
                        if name == target_dir
                            name = pkg_name
                        end
                    end
                    name
                end

                @selected_rock_packages, @selected_gems = extract_selected_packages(@selected_packages)
                Apaka::Packaging.info "selected_packages: #{selected_packages}\n"
                        "    - rock_packages: #{selected_rock_packages}\n"
                        "    - gems: #{selected_gems}\n"

                selection = package_info_ask.autoproj_init_and_load(selected_rock_packages)
                selection = package_info_ask.resolve_user_selection_packages(selection)
                # Make sure that when we request a package build we only get this one,
                # and not the pattern matched to other packages, e.g. for orogen
                selection = selection.select do |pkg_name, i|
                    if selected_packages.empty? or selected_packages.include?(pkg_name)
                        Apaka::Packaging.info "Package: #{pkg_name} is in selection"
                        true
                    else
                        false
                    end
                end

                return selection, options
            end

            def acquire_lock
                # Prevent deb_package from parallel execution since autoproj configuration loading
                # does not account for parallelism
                Apaka::Packaging.debug "deb_package: waiting for execution lock"
                lock_time = Time.now
                lock_file.flock(File::LOCK_EX)
                lock_wait_time_in_s = Time.now - lock_time
                Apaka::Packaging.debug "deb_package: execution lock acquired after #{lock_wait_time_in_s} seconds"
            end

            def run(selection, options)
                acquire_lock

                Autobuild.do_update = true

                @packager = Apaka::Packaging::Deb::Package2Deb.new(options)
                @packager.build_dir = options[:build_dir] if options[:build_dir]

                # workaround for orogen
                @packager.rock_autobuild_deps[:orogen] = [ package_info_ask.pkginfo_from_pkg(package_info_ask.package_by_name("orogen")) ]
                if ancestor_blacklist = options[:ancestor_blacklist]
                    Apaka::Packaging::TargetPlatform::ancestor_blacklist = ancestor_blacklist.map do |pkg_name|
                        pkginfo = package_info_ask.pkginfo_from_pkg(package_info_ask.package_by_name(pkg_name))
                        @packager.debian_name(pkginfo, false)
                    end.to_set
                end

                packages, extra_gems = @packager.package_selection(selection)

                @selected_gems += extra_gems
                @selected_gems.uniq!

                @gem2deb_packager = Apaka::Packaging::Deb::Gem2Deb.new(options)
                @gem2deb_packager.build_dir = options[:build_dir] if options[:build_dir]
                gems = @gem2deb_packager.package_gems(@selected_gems, force_update: options[:rebuild], patch_dir: options[:patch_dir])

                sync_packages = packages + gems
                if options[:dest_dir]
                    sync_packages.each do |debian_pkg_name|
                        # sync the directory in build/debian and the target directory based on an existing
                        # files pattern

                        files = []
                        @packager.file_suffix_patterns.map do |p|
                            # Finding files that exist in the source directory
                            # needs to handle ruby-hoe_0.20130113/*.dsc vs. ruby-hoe-yard_0.20130113/*.dsc
                            # and ruby-hoe/_service
                            glob_exp = File.join(@packager.build_dir,debian_pkg_name,"*#{p}")
                            files += Dir.glob(glob_exp)
                        end
                        files = files.flatten.uniq
                        dest_dir = File.join(options[:dest_dir], debian_pkg_name)

                        FileUtils.mkdir_p dest_dir
                        FileUtils.cp files, dest_dir
                    end
                end

                @gem2deb_packager.cleanup
            end

#            def build_local
#                begin
#                    selected_gems.each do |gem_name, gem_version|
#                        pkg = package_info_ask.package(gem_name)
#                        options =  {:distributions => o_distributions, :verbose => Autobuild.verbose}
#                        if pkg && pkg.autobuild
#                            options[:parallel_build_level] = pkg.autobuild.parallel_build_level
#                        end
#                        filepath = packager.build_local_gem gem_name, options 
#                        puts "Debian package created for gem '#{gem_name}': " + filepath
#                        if o_dest_dir
#                            puts "Copying debian package to destination folder: #{dest_dir}"
#                            FileUtils.mkdir_p dest_dir
#                            FileUtils.cp filepath, dest_dir
#                        end
#                    end
#
#                    selection.each_with_index do |pkg_name, i|
#                        if pkg = package_info_ask.package(pkg_name)
#                            pkg = pkg.autobuild
#                        else
#                            Apaka::Packaging.warn "Package: #{pkg_name} is not a known rock package (but maybe a ruby gem?)"
#                            next
#                        end
#
#                        pkginfo = package_info_ask.pkginfo_from_pkg(pkg)
#                        filepath = packager.build_local_package pkginfo, :distributions => o_distributions, :verbose => Autobuild.verbose
#                        puts "Debian package created for package '#{pkg}': #{filepath}"
#                        if o_dest_dir
#                            puts "Copying debian package to destination folder: #{dest_dir}"
#                            FileUtils.mkdir_p dest_dir
#                            FileUtils.cp filepath, dest_dir
#                        end
#                    end
#                rescue Exception => e
#                    Apaka::Packaging.warn "Local build failed: #{e}"
#                    puts e.backtrace
#                    exit 10
#                end
#            end
#
#            def install
#                begin
#                    selected_gems.each do |gem_name, gem_version|
#                        is_osdeps = false
#                        native_name, is_osdeps = packager.native_dependency_name(gem_name)
#                        if !is_osdeps
#                            puts "Installing locally: '#{gem_name}'"
#                            debian_name = packager.debian_ruby_name(gem_name, true)
#                            packager.install debian_name, :distributions => o_distributions
#                        else
#                            puts "Package '#{gem_name}' is available as os dependency: #{native_name}"
#                        end
#                    end
#                    selection.each_with_index do |pkg_name, i|
#                        if pkg = package_info_ask.package(pkg_name)
#                            pkg = pkg.autobuild
#                        else
#                            Apaka::Packaging.warn "Package: #{pkg_name} is not a known rock package (but maybe a ruby gem?)"
#                            next
#                        end
#                        pkginfo = package_info_ask.pkginfo_from_pkg(pkg)
#                        debian_name = packager.debian_name(pkginfo)
#
#                        puts "Installing locally: '#{pkg.name}'"
#                        packager.install debian_name, :distributions => o_distributions, :verbose => Autobuild.verbose
#                    end
#                rescue Exception => e
#                    puts "Local install failed: #{e}"
#                    exit 20
#                end
#            end
        end
    end
end
