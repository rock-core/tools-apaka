#require 'rexml/document'
require 'autoproj'
require 'autobuild'
require 'apaka/packaging/packageinfoask'
require 'autoproj/cli/base'
require 'apaka/packaging/gem_dependencies'

module Apaka
    module Packaging
        class Autoproj2Adaptor < PackageInfoAsk

            attr_accessor :package_set_order

            attr_reader :osdeps_release_tags

            def self.which
                :autoproj_v2
            end

            def self.probe
                #theoretically, we could check for every thing we use in
                #autoproj, but this should suffice for now.
                defined? Autoproj::workspace
            rescue
                false
            end

            def initialize(options)
                # Package set order
                @package_set_order = []

                @pkginfo_cache = {}

                @pkg_manifest_cache = {}

                distribution,release_tags = osdeps_operating_system
                @osdeps_release_tags = release_tags

                Autoproj::workspace.setup
                #mainline: true: apply no overrides
                #          nil: apply local overrides
                Autoproj::workspace.load_package_sets(mainline: nil)
                Autoproj::workspace.config.save
                Autoproj::workspace.setup_all_package_directories
                Autoproj::workspace.finalize_package_setup

                # Assume that ruby is already installed and avoid dependance on
                # updating autoproj just for ignoring ruby
                ruby_version = "ruby#{RbConfig::CONFIG['MAJOR']}#{RbConfig::CONFIG['MINOR']}"
                Autoproj.osdeps.add_entries({ruby_version => [[{'default' => 'ignore'}]]})

                @cli = Autoproj::CLI::Base.new(Autoproj::workspace)
            end

            def osdeps_operating_system
                Autoproj::workspace.os_package_resolver.operating_system
            end

            # required for jenkins.rb, if there is a specific operating
            # system in the config file or if there is one given on the
            # commandline
            def osdeps_operating_system= (os)
                Autoproj.workspace.os_package_resolver.operating_system = os
                Autoproj.workspace.os_package_resolver.invalidate_resolve_package_cache

                Autoproj.workspace.os_repository_resolver.operating_system = os
            end

            def root_dir
                Autoproj.root_dir
            end

            def osdeps_set_alias(old_name, new_name)
                Autoproj::workspace.os_package_resolver.add_aliases(new_name => old_name)
            end

            def autoproj_init_and_load(selection)
                selection
            end

            def resolve_user_selection_packages(selection)
                pkgs, _ = @cli.resolve_user_selection(selection)
                pkgs.packages
            end

            def moved_packages
                Autoproj.manifest.moved_packages
            end

            def package(package_name)
                #make sure the manifest of package_name has been parsed,
                #and while we are at it, put it in our cache.
                pkgmanifest_by_name(package_name)
                Autoproj.manifest.package(package_name)
            end

            def is_metapackage?(sel)
                Autoproj.manifest.metapackages.has_key?(sel)
            end

            def ignored?(name)
                Autoproj.manifest.ignored?(name)
            end

            def pkginfo_from_pkg(pkg)
                if Autoproj.manifest.excluded?(pkg.name)
                    raise ArgumentError, "Apaka::Packaging::Autoproj2Adaptor::pkginfo_from_pkg: trying to get info from excluded package '#{pkg.name}'"
                end
                if @pkginfo_cache.has_key?(pkg.name)
                    return @pkginfo_cache[pkg.name]
                end
                if pkg.failed?
                    raise ArgumentError, "Apaka::Packaging::Autoproj2Adaptor: cannot retrieve" \
                        " package information for '#{pkg.name}' -- " \
                        " package is in failed state."
                end
                #first, we need to make sure the package is imported. otherwise,
                #there is no useful manifest, thus no dependencies,
                #latest_commit_time does not work, and more.
                if not File.exist?(pkg.srcdir)
                    Packaging.debug "Retrieving remote git repository of '#{pkg.name}'"
                    pkg.importer.import(pkg)
                end
                pkg_commit_time = latest_commit_time(pkg)
                pkginfo = Autoproj2PackageInfo.new(pkg,self)
                @pkginfo_cache[pkg.name] = pkginfo
                pkginfo.latest_commit_time = pkg_commit_time
                pkginfo.name = pkg.name
                pkginfo.srcdir = pkg.srcdir

                if pkg.kind_of?(Autobuild::Orogen)
                    pkginfo.build_type = :orogen
                    pkginfo.cmake_defines = pkg.defines
                    pkginfo.orogen_command = "orogen #{Autobuild::Orogen.orogen_options.join(" ")} #{pkg.orogen_options.join(" ")} --corba --transports=corba,mqueue,typelib --type-export-policy=used #{pkg.orogen_file}"
                elsif pkg.kind_of?(Autobuild::CMake)
                    pkginfo.build_type = :cmake
                    pkginfo.cmake_defines = pkg.defines
                elsif  pkg.kind_of?(Autobuild::Autotools)
                    pkginfo.build_type = :autotools
                    pkginfo.extra_configure_flags = extra_configure_flags(pkg)
                    pkginfo.using_libtool = pkg.using[:libtool]
                    pkginfo.using_autogen = pkg.using[:autogen]
                elsif  pkg.kind_of?(Autobuild::Ruby)
                    pkginfo.build_type = :ruby
                elsif  pkg.kind_of?(Autobuild::ArchiveImporter)
                    pkginfo.build_type = :archive_importer
                elsif  pkg.kind_of?(Autobuild::ImporterPackage)
                    pkginfo.build_type = :importer_package
                else
                    raise ArgumentError, "Debian: Unsupported package type #{pkg.class} for #{pkg.name}"
                end
                if pkg.importer.kind_of?(Autobuild::Git)
                    pkginfo.importer_type = :git
                elsif pkg.importer.kind_of?(Autobuild::SVN)
                    pkginfo.importer_type = :svn
                elsif pkg.importer.kind_of?(Autobuild::ArchiveImporter)
                    pkginfo.importer_type = :archive_importer
                end
                if pkg.description.nil?
                    pkgi.description_version = "0"
                else
                    if !pkg.description.version
                        pkginfo.description_version = "0"
                    else
                        pkginfo.description_version = pkg.description.version
                    end
                end

                pkginfo.short_documentation = pkg.description.short_documentation
                pkginfo.documentation = pkg.description.documentation
                pkginfo.origin_information = Array.new()
                begin
                    if pkg.importer.kind_of?(Autobuild::Git)
                        status = pkg.importer.status(pkg, only_local: true)
                        pkginfo.origin_information << "repository: #{pkg.importer.repository_id}"
                        pkginfo.origin_information << "branch: #{pkg.importer.current_branch(pkg)}"
                        pkginfo.origin_information << "commit: #{status.common_commit}"
                        pkginfo.origin_information << "tag: #{pkg.importer.tag}"
                    elsif pkg.importer.kind_of?(Autobuild::SVN)
                        pkginfo.origin_information << "repository: #{pkg.importer.repository_id}"
                        pkginfo.origin_information << "revision: #{pkg.importer.revision}"
                    elsif pkg.importer.kind_of?(Autobuild::ArchiveImporter)
                        pkginfo.origin_information << "url: #{pkg.importer.url}"
                        pkginfo.origin_information << "filename: #{pkg.importer.filename}"
                    end
                rescue Exception => e
                    pkginfo.origin_information << "the repository and commit information could not be extracted"
                    pkginfo.origin_information << "error at generation: #{e.to_s}"
                end

                pkginfo.parallel_build_level = pkg.parallel_build_level

                pkginfo
            end

            private

            # Extract the latest commit time for given importers
            # return a Time object
            def latest_commit_time(pkg)
                importer = pkg.importer
                if importer.kind_of?(Autobuild::Git)
                    git_version(pkg)
                elsif importer.kind_of?(Autobuild::SVN)
                    svn_version(pkg)
                elsif importer.kind_of?(Autobuild::ArchiveImporter) || importer.kind_of?(Autobuild::ImporterPackage)
                    archive_version(pkg)
                else
                    Packaging.warn "No version extraction yet implemented for importer type: #{importer.class} -- using current time for version string"
                    Time.now
                end
            end

            def git_version(pkg)
                time_of_last_commit=pkg.importer.run_git_bare(pkg, 'log', '--encoding=UTF-8','--date=iso',"--pretty=format:'%cd'","-1").first
                Time.parse(time_of_last_commit.strip)
            end

            def svn_version(pkg)
                #["------------------------------------------------------------------------",
                # "r21 | anauthor | 2012-10-01 13:46:46 +0200 (Mo, 01. Okt 2012) | 1 Zeile",
                #  "",
                #   "some comment",
                #    "------------------------------------------------------------------------"]
                #
                svn_log = pkg.importer.run_svn(pkg, 'log', "-l 1", "--xml")
                svn_log = REXML::Document.new(svn_log.join("\n"))
                time_of_last_commit = nil
                svn_log.elements.each('//log/logentry/date') do |d|
                    time_of_last_commit = Time.parse(d.text)
                end
                time_of_last_commit
            end

            def archive_version(pkg)
                File.lstat(pkg.importer.cachefile).mtime
            end

            def pkgmanifest_by_name(package_name)
                if !@pkg_manifest_cache[package_name]
                    begin
                        if !Autoproj.workspace.all_present_packages.include?(package_name)
                            Packaging.warn "Apaka::Packaging::Autoproj2Adaptor: package '#{package_name}' is not present in workspace -- trying to load package"
                            ps = Autoproj::PackageSelection.new
                            ps.select(ps, package_name)
                            Autoproj.workspace.load_packages(ps)
                        end
                    rescue Exception => e
                        Packaging.warn "Apaka::Packaging::Autoproj2Adaptor: failed to load package '#{package_name}' -- #{e}"
                    end

                    begin
                        Packaging.info "Loading manifest for #{package_name}"
                        @pkg_manifest_cache[package_name] = Autoproj.manifest.load_package_manifest(package_name)
                    rescue Exception => e
                        @pkg_manifest_cache[package_name] = nil
                        Packaging.warn "Apaka::Packaging::Autoproj2Adaptor: failed to load manifest for '#{package_name}' -- #{e}"
                    end
                end
                @pkg_manifest_cache[package_name]
            end

            public

            def package_by_name(package_name)
                 manifest = pkgmanifest_by_name(package_name)
                 if not manifest
                     raise RuntimeError, "No manifest found for #{package_name}"
                 end
                 manifest.package
            end

            def pkginfo_by_name(package_name)
                pkg = package_by_name(package_name)
                pkginfo_from_pkg(pkg)
            end

            private

            # Compute all packages that are required and their corresponding
            # reverse dependencies
            # return [Hash<package_name, reverse_dependencies>]
            def reverse_dependencies(selection)
                Packaging.info ("#{selection.size} packages selected")
                Packaging.debug "Selection: #{selection}}"
                orig_selection = selection.clone
                reverse_dependencies = Hash.new

                all_packages = Set.new
                all_packages.merge(selection)
                while true
                    all_packages_refresh = all_packages.dup
                    all_packages.each do |pkg_name|
                        pkg = package_by_name(pkg_name)
                        pkg_dependencies = dependencies(pkg)[:rock_pkginfo].collect {|p| p.name}
                        reverse_dependencies[pkg.name] = pkg_dependencies.dup
                        Packaging.debug "deps: #{pkg.name} --> #{pkg_dependencies}"
                        all_packages_refresh.merge(pkg_dependencies)
                    end

                    if all_packages.size == all_packages_refresh.size
                        # nothing changed, so converged
                        break
                    else
                        all_packages = all_packages_refresh
                    end
                end
                Packaging.info "all packages: #{all_packages.to_a}"
                Packaging.info "reverse deps: #{reverse_dependencies}"

                reverse_dependencies
            end

            # Compute all required packages from a given selection
            # including the dependencies
            #
            # The selection is a list of package names
            #
            # The order of the resulting package list is sorted
            # accounting for interdependencies among packages
            def all_required_rock_packages(selection, no_deps: false)
                reverse_dependencies = {}
                if no_deps
                    selection.each do |pkg_name|
                        reverse_dependencies[pkg_name] = []
                    end
                else
                    reverse_dependencies = reverse_dependencies(selection)
                end
                sort_packages(reverse_dependencies)
            end

            def sort_packages(reverse_dependencies_hash)
                # input is a hash, but we require a sorted list
                # to deal with package set order, so we convert

                reverse_dependencies = Array.new
                if !package_set_order.empty?
                    sorted_dependencies = Array.new
                    sorted_pkgs = sort_by_package_sets(reverse_dependencies_hash.keys, package_set_order)
                    sorted_pkgs.each do |pkg_name|
                       pkg_dependencies = reverse_dependencies_hash[pkg_name]
                       sorted_pkg_dependencies = sort_by_package_sets(pkg_dependencies, package_set_order)
                       sorted_dependencies << [ pkg_name, sorted_pkg_dependencies ]
                    end
                    reverse_dependencies = sorted_dependencies
                else
                    reverse_dependencies_hash.each do |k,v|
                        reverse_dependencies << [k,v]
                    end
                end

                all_required_packages = Set.new
                resolve_packages = []
                while true
                    if resolve_packages.empty?
                        if reverse_dependencies.empty?
                            break
                        else
                            # Pick the entries name
                            resolve_packages = [ reverse_dependencies.first.first ]
                        end
                    end

                    # Contains the name of all handled packages
                    handled_packages = Set.new
                    resolve_packages.each do |pkg_name|
                        name, dependencies = reverse_dependencies.find { |p| p.first == pkg_name }
                        if dependencies.empty?
                            handled_packages << pkg_name
                            pkg = Autoproj.manifest.package(pkg_name).autobuild
                            all_required_packages << pkg
                        else
                            resolve_packages += dependencies
                            resolve_packages.uniq!
                        end
                    end

                    handled_packages.each do |pkg_name|
                        resolve_packages.delete(pkg_name)
                        reverse_dependencies.delete_if { |dep_name, _| dep_name == pkg_name }
                    end

                    reverse_dependencies.map! do |pkg,dependencies|
                        dependencies.reject! { |x| handled_packages.include? x }
                        [pkg, dependencies]
                    end

                    Packaging.debug "Handled: #{handled_packages}"
                    Packaging.debug "Remaining: #{reverse_dependencies}"
                    if handled_packages.empty? && !resolve_packages
                        Packaging.warn "Unhandled dependencies: #{resolve_packages}"
                    end
                end

                all_required_packages
            end

            public

            # Get all required packages that come with a given selection of packages
            # including the dependencies of ruby gems
            #
            # This requires the current installation to be complete since
            # `gem dependency <gem-name>` has been selected to provide the information
            # of ruby dependencies
            def all_required_packages(selection, selected_gems, with_rock_release_prefix: false, no_deps: false)
                all_packages = all_required_rock_packages(selection, no_deps: no_deps)

                gems = Array.new
                gem_versions = Hash.new

                # Make sure to account for extra packages
                selected_gems.each do |name, version|
                    gems << name
                    gem_versions[name] ||= Array.new
                    if version
                        gem_versions[name] << version
                    end
                end

                extra_gems = Array.new
                extra_osdeps = Array.new

                # Add the ruby requirements for the current rock selection
                #todo: this used to work an all_packages without the already installed packages
                all_pkginfos = []
                excluded_packages = []
                failed_packages = []
                all_packages.each do |pkg|
                    begin
                        if Autoproj.manifest.excluded?(pkg.name)
                            excluded_packages << pkg
                            next
                        end

                        deps = nil
                        begin
                            # Retrieve information about osdeps and non-native
                            # dependencies, since
                            # No need to reiterate on rock package dependencies
                            # since these are contained in all_packages
                            deps = dependencies(pkg, with_rock_release_prefix) unless no_deps
                            all_pkginfos << pkginfo_from_pkg(pkg)
                        rescue ArgumentError
                            failed_packages << pkg
                            next
                        end

                        next unless deps

                        # Update global list
                        extra_osdeps.concat deps[:osdeps]
                        extra_gems.concat deps[:extra_gems]

                        deps[:nonnative].each do |dep, version|
                            if dep =~ /([^<=>]*)([<=>]?.*)/
                                name = $1
                                gem_versions[name] ||= Array.new
                                version = $2 unless $2.empty?
                            end
                            if version
                                gem_versions[name] << version
                            end
                        end
                    rescue Exception => e
                        Packager.warn "Apaka::Packaging::Autoproj2Adaptor: failed to process package " \
                            " '#{pkg.name}' -- #{e.message} -- #{e.backtrace}"
                        failed_packages << pkg.name
                    end
                end

                required_gems = all_required_gems(gem_versions, no_deps: no_deps )

                {:pkginfos => all_pkginfos, :extra_osdeps => extra_osdeps, :extra_gems => extra_gems, :failed => failed_packages, :excluded => excluded_packages }.merge required_gems
            end

            # resolve the required gems of a list of gems and their versions
            # { gem => [versions] }
            # returns { :gems => [gem names sorted so least dependend is first],
            #           :gem_versions => { gem => version } }
            def all_required_gems(gem_versions, no_deps: false)
                specs = GemDependencies.all_gem_specs

                sorted_gem_list = []
                exact_version_list = {}
                specs.each do |name, spec|
                    if gem_versions.has_key?(name)
                        sorted_gem_list << name
                        exact_version_list[name] = spec.version.to_s
                    end
                end

                {:gems => sorted_gem_list, :gem_versions => exact_version_list}
            end

            private

            def resolve_optional_dependencies(pkg)
                packages, osdeps = pkg.partition_optional_dependencies
                packages.each do |dep_pkg_name|
                    if !Autoproj::manifest.ignored?(dep_pkg_name) && !Autoproj::manifest.excluded?(dep_pkg_name)
                        pkg.depends_on dep_pkg_name
                    end
                end
                osdeps.each do |osdep_pkg_name|
                    if !Autoproj::manifest.ignored?(osdep_pkg_name) && !Autoproj::manifest.excluded?(osdep_pkg_name)
                        pkg.os_packages << osdep_pkg_name
                    end
                end
            end

            # Compute dependencies of this package
            # Returns [:rock_pkginfo => rock_pkginfos, :osdeps => osdeps_packages, :nonnative => nonnative_packages ]
            def dependencies(pkg, with_rock_release_prefix = true)
                pkg = package_by_name(pkg.name)

                resolve_optional_dependencies(pkg)

                # Ignore dependencies as rock package, when they resolved to an
                # osdeps package
                pkg_dependencies = pkg.dependencies.select do |dep_name|
                    !Autoproj.osdeps.has?(dep_name)
                end

                deps_rock_pkginfo = pkg_dependencies.map do |dep_name|
                    pkginfo_from_pkg(package_by_name(dep_name))
                end

                pkg_osdeps = Autoproj.osdeps.resolve_os_packages(pkg.os_packages)
                # There are limitations regarding handling packages with native dependencies
                #
                # Currently gems need to converted into debs using gem2deb
                # These deps dependencies are updated here before uploading a package
                #
                # Generation of the debian packages from the gems can be done in postprocessing step
                # i.e. see convert_gems

                deps_osdeps_packages = []
                native_package_manager = Autoproj.osdeps.os_package_manager
                _, native_pkg_list = pkg_osdeps.find { |manager, _| manager == native_package_manager }

                deps_osdeps_packages += native_pkg_list if native_pkg_list

                non_native_handlers = pkg_osdeps.collect do |handler, pkg_list|
                    if handler != native_package_manager
                        [handler, pkg_list]
                    end
                end.compact

                non_native_dependencies = Set.new
                extra_gems = Set.new
                non_native_handlers.each do |pkg_handler, pkg_list|
                    # Convert native ruby gems package names to rock-xxx
                    if pkg_handler == "gem"
                        pkg_list.each do |name|
                            version = nil
                            if name =~ /([<>=]=?.*)$/
                                version = $1
                            end

                            name = name.gsub(/[<>=]=?.*$/,"")

                            extra_gems << [name, version]
                            non_native_dependencies << [name, version]
                        end
                    else
                        raise ArgumentError, "cannot package #{pkg.name} as it has non-native dependencies (#{pkg_list}) -- #{pkg_handler.class} #{pkg_handler}"
                    end
                end
                Packaging.info "'#{pkg.name}'\n" \
                    "\tpackage deps: '#{deps_rock_pkginfo.collect {|p| p.name}}'\n" \
                    "\tos deps: '#{deps_osdeps_packages.join(' ')}'\n" \
                    "\tnon-native deps: #{non_native_dependencies.to_a.join(' ')}"

                # Return rock packages, osdeps and non native deps (here gems)
                { :rock_pkginfo => deps_rock_pkginfo, :osdeps => deps_osdeps_packages, :nonnative => non_native_dependencies.to_a, :extra_gems => extra_gems.to_a }
            end

            def extra_configure_flags(package)
                flags = []
                key_value_regexp = Regexp.new(/([^=]+)=([^=]+)/)
                package.configureflags.each do |flag|
                    if match_data = key_value_regexp.match(flag)
                        key = match_data[1]
                        value = match_data[2]
                        # Skip keys that start with --arguments
                        # and assume defines starting with UpperCase
                        # letter, e.g., CFLAGS='...'
                        if key =~ /^[A-Z]/
                            if value !~ /^["]/ && value !~ /^[']/
                                value = "'#{match_data[2]}'"
                            end
                        end
                        flags << "#{key}=#{value}"
                    else
                        flags << flag
                    end
                end
                Packaging.info "Using extra configure flags: #{flags}"
                flags
            end

            # Sort by package set order
            # can be used with any packages array of objects providing a name(),
            # that is, works with both autobuild packages and PackageInfos
            # returns a sorted array populated from elements of packages
            def sort_by_package_sets(packages, pkg_set_order)
                priority_lists = Array.new
                (0..pkg_set_order.size).each do |i|
                    priority_lists << Array.new
                end

                packages.each do |package|
                    pkg_name = package
                    if !package.kind_of?(String)
                        pkg_name = package.name
                    end
                    pkg = Autoproj.manifest.package(pkg_name)
                    pkg_set_name = pkg.package_set.name

                    if index = pkg_set_order.index(pkg_set_name)
                        priority_lists[index] << package
                    else
                        priority_lists.last << package
                    end
                end

                priority_lists.flatten
            end

            # Import a package for packaging into the specified target dir
            # @param pkg_target_importdir [String] Path to where the package
            #     shall be imported
            def import_package(pkg, pkg_target_importdir)
                orig_srcdir = pkg.srcdir
                # Some packages, e.g. mars use a single git repository a split it artificially
                # if this is the case, try to copy the content instead of doing a proper checkout
                if pkg.srcdir != pkg.importdir
                    Packaging.debug "Importing repository from #{pkg.srcdir} to #{pkg_target_importdir}"
                    FileUtils.mkdir_p pkg_target_importdir
                    FileUtils.cp_r File.join(pkg.srcdir,"/."), pkg_target_importdir
                    # Update resulting source directory
                    pkg.srcdir = pkg_target_importdir
                else
                    pkg.srcdir = pkg_target_importdir
                    begin
                        Packaging.debug "Importing repository to #{pkg.srcdir}"
                        # Workaround for bug in autoproj:
                        # archive_dir should be set from pkg.srcdir, but is actually set from pkg.name
                        # see autobuild-1.9.3/lib/autobuild/import/archive.rb +406
                        if pkg.importer.kind_of?(Autobuild::ArchiveImporter)
                            pkg.importer.options[:archive_dir] ||= File.basename(pkg.srcdir)
                        end
                        pkg.importer.import(pkg)

                        # Ensure that additional code from overrides.rb
                        # (by addition a post_import block) applies
                        Autoproj.each_post_import_block(pkg) do |block|
                            block.call(pkg)
                        end
                    rescue Exception => e
                        if not e.message =~ /failed in patch phase/
                            raise
                        else
                            Packaging.warn "Patching #{pkg.name} failed"
                        end
                    end

                    Dir.glob(File.join(pkg.srcdir, "*-stamp")) do |file|
                        FileUtils.rm_f file
                    end
                end
                pkg.srcdir = orig_srcdir
            end

            class Autoproj2PackageInfo < PackageInfo
                def initialize(pkg,pkginfoask)
                    super(pkg: pkg)
                    @pkginfoask = pkginfoask
                end

                # imports the package to the importdir
                # generally, that is a copy if a different source dir exists, but
                # it may be a source control checkout.
                def import(pkg_target_importdir)
                    pkg = @pkg.dup
                    @pkginfoask.send(:pkgmanifest_by_name, @pkg.name)

                    # Test whether there is a local
                    # version of the package to use.
                    # Only for Git-based repositories
                    # If it is not available import package
                    # from the original source
                    if @pkg.importer.kind_of?(Autobuild::Git)
                        Packaging.debug "Using locally available git repository of '#{@pkg.name}' -- '#{@pkg.srcdir}' ('#{@pkg.importdir}')"
                        @pkg.importer.repository = pkg.importdir
                        @pkg.importer.commit = pkg.importer.current_remote_commit(pkg)
                        Packaging.info "Using local (git) package: #{@pkg.srcdir} and commit #{@pkg.importer.commit}"
                    end

                    @srcdir = pkg_target_importdir
                    @pkginfoask.send(:import_package, @pkg, pkg_target_importdir)

                    @files = Dir.glob("#{@pkg.srcdir}/**")
                    @licenses = ""
                    @copyright = ""
                    ['manifest.xml','package.xml'].each do |file|
                        xml_file  = File.join(@pkg.srcdir, file)
                        if File.exist?(xml_file)
                            data = File.read(xml_file)
                            # check over multilines, then filter out newlines to
                            # get a consistent/unformatted text block
                            if data =~ /<license>(.*)<\/license>/m
                                @licenses += $1.split("\n").map { |x| x.strip }.reject {|x| x.empty? }.join(", ")
                            end
                            if data =~ /<copyright>(.*)<\/copyright>/m
                                @copyright += $1.split("\n").map { |x| x.strip }.reject {|x| x.empty? }.join(", ")
                            end
                        end
                    end
                    @files.grep(/^license/i).each do |file|
                        @licenses += File.read(file)
                        @licenses += "\n"
                    end
                    @files.grep(/^copyright/i).each do |file|
                        @copyright += File.read(file)
                        @copyright += "\n"
                    end
                end

                # raw dependencies
                # can be processed with filtered_dependencies to obtain old
                # behaviour
                # [:rock_pkginfo => rock_pkginfos, :osdeps => osdeps_packages, :nonnative => nonnative_packages ]
                def dependencies
                    if !@dependencies
                        @dependencies = @pkginfoask.send(:dependencies,@pkg)
                    end
                    @dependencies
                end

                def required_rock_packages
                    if !@required_rock_packages
                        @required_rock_packages =
                            @pkginfoask.send(:all_required_rock_packages, [@pkg.name]).map do |pkg|
                            @pkginfoask.pkginfo_from_pkg(pkg)
                        end
                    end
                    @required_rock_packages
                end

                # Get all environment variable settings that
                # should be applied when using this package
                def env_ops
                    @pkg.env
                end

                # Generate an environment data structure:
                # { VAR_NAME => { :type => :add_path, :values => [ ... ] } }
                # @return env data
                def generate_env_data(pkg_var, pkg_prefix, base_data: {})
                    env_data = base_data
                    env_ops.each do |op|
                        var_name = op.name
                        env_data[var_name] ||= { :type => nil,
                                                :values => []
                                              }
                        op_type = env_data[var_name][:type]
                        if not op_type
                            env_data[var_name][:type] = op.type
                        elsif op_type != op.type
                            raise RuntimeError, "Apaka::Packaging::Autoproj2Adaptor.envsh: #{pkg_var} -- setting of env var: #{var_name} failed" \
                                " incompatible mix of #{op_type} and #{op.type} -- cannot proceed"
                        end

                        env_data[var_name][:values] = op.values.map { |v| v.gsub(pkg.prefix, pkg_prefix) if v }
                    end

                    if is_bundle?
                        env_data["ROCK_BUNDLE_PATH"] = {
                            :type => :add_path,
                            :values => [ File.join(pkg_prefix,"share","rock","bundles") ],
                        }
                    end
                    env_data
                end

                # Convert env data to string
                def envsh(env_data)
                    s = ""
                    env_data.each do |var_name, spec|
                        var_setup = "#{var_name}="
                        spec[:values].each do |value|
                            var_setup += value + ":" if value
                        end

                        case spec[:type]
                        when :add
                            if var_setup[-1] != ":"
                                var_setup += ":"
                            end
                            var_setup += "${#{var_name}}\n"
                        when :add_path
                            if var_setup[-1] != ":"
                                var_setup += ":"
                            end
                            var_setup += "${#{var_name}}\n"
                        when :add_prefix
                            Packager.warn ":add_prefix encountered in envsh " \
                                "generation, but it is ignored for now" \
                                " -- varname #{var_name} -- spec #{spec}"
                        when :set
                            if var_setup[-1] == ":"
                                var_setup[-1] = "\n"
                            else
                                var_setup += "\n"
                            end
                        else
                            raise ArgumentError, "#{self.class}#{__method__}: unknown env op type: #{spec[:type]}"
                        end
                        var_setup += "export #{var_name}\n"
                        s += var_setup
                    end
                    return s
                end

                def env
                    if !@env
                        @pkg.update_environment
                        #make autoproj actually generate the environments.
                        #resolved_env and update_environment are not enough,
                        #looks like it needs to be done recursively
                        dependencies[:rock_pkginfo].each { |d| d.env }
                        @env = @pkg.resolved_env
                    end
                    @env
                end

                def is_bundle?
                    raise RuntimeError, "#{self.class}#{__method__}: pkginfo is not properly initialized" if not name or not srcdir
                    return false if build_type != :ruby

                    name =~ /bundles/ || File.exist?(File.join(srcdir,"config","init.rb"))
                end
            end #class Autoproj2PackageInfo

        end #class Autoproj2Adaptor
    end #module Packaging
end #module Apaka

