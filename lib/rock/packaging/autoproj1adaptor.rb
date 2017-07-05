require 'rexml/document'
require 'autoproj'
require 'autobuild'
require 'rock/packaging/packageinfoask'

module Autoproj
    module Packaging
        class Autoproj1Adaptor < PackageInfoAsk

            attr_accessor :package_set_order

            def self.which
                :autoproj_v1
            end

            def self.probe
                #theoretically, we could check for every thing we use in
                #autoproj, but this should suffice for now.
                defined? Autoproj::CmdLine.initialize_root_directory()
            rescue
                false
            end

            def initialize(options)
                # Package set order
                @package_set_order = []
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
                    Packager.warn "No version extraction yet implemented for importer type: #{importer.class} -- using current time for version string"
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

            public

            def package_by_name(package_name)
                Autoproj.manifest.package(package_name).autobuild
            end

            private

            # Compute all packages that are require and their corresponding
            # reverse dependencies
            # return [Hash<package_name, reverse_dependencies>]
            def reverse_dependencies(selection)
                Packager.info ("#{selection.size} packages selected")
                Packager.debug "Selection: #{selection}}"
                orig_selection = selection.clone
                reverse_dependencies = Hash.new

                all_packages = Set.new
                all_packages.merge(selection)
                while true
                    all_packages_refresh = all_packages.dup
                    all_packages.each do |pkg_name|
                        begin
                            pkg_manifest = Autoproj.manifest.load_package_manifest(pkg_name)
                        rescue Exception => e
                            raise RuntimeError, "Autoproj::Packaging::Debian: failed to load manifest for '#{pkg_name}' -- #{e}"
                        end

                        pkg = pkg_manifest.package

                        pkg.resolve_optional_dependencies
                        reverse_dependencies[pkg.name] = pkg.dependencies.dup
                        Packager.debug "deps: #{pkg.name} --> #{pkg.dependencies}"
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

                reverse_dependencies
            end

            # Compute all required packages from a given selection
            # including the dependencies
            #
            # The selection is a list of package names
            #
            # The order of the resulting package list is sorted
            # accounting for interdependencies among packages
            def all_required_rock_packages(selection)
                reverse_dependencies = reverse_dependencies(selection)
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

                all_required_packages = Array.new
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
                    handled_packages = Array.new
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

                    Packager.debug "Handled: #{handled_packages}"
                    Packager.debug "Remaining: #{reverse_dependencies}"
                    if handled_packages.empty? && !resolve_packages
                        Packager.warn "Unhandled dependencies: #{resolve_packages}"
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
            def all_required_packages(selection, selected_gems, with_rock_release_prefix = false)
                all_packages = all_required_rock_packages(selection)

                gems = Array.new
                gem_versions = Hash.new

                # Make sure to account for extra packages
                selected_gems.each do |name, version|
                    gems << name
                    gem_versions[name] ||= Array.new
                    gem_versions[name] << version
                end

                extra_gems = Array.new()
                extra_osdeps = Array.new()

                # Add the ruby requirements for the current rock selection
                all_packages.each do |pkg|
                    deps = dependencies(pkg, with_rock_release_prefix)
                    # Update global list
                    extra_osdeps.concat deps[:osdeps]
                    extra_gems.concat deps[:extra_gems]

                    deps = filtered_dependencies(pkg, dependencies(pkg, with_rock_release_prefix), with_rock_release_prefix)
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

                {:packages => all_packages, :gems => sorted_gem_list, :gem_versions => exact_version_list, :extra_osdeps => extra_osdeps, :extra_gems => extra_gems }
            end

            private

            # Compute dependencies of this package
            # Returns [:rock => rock_packages, :osdeps => osdeps_packages, :nonnative => nonnative_packages ]
            def dependencies(pkg, with_rock_release_prefix = true)
                pkg = package_by_name(pkg.name)

                pkg.resolve_optional_dependencies
                deps_rock_pkgs = pkg.dependencies.map do |dep_name|
                    package_by_name(dep_name)
                end

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

                non_native_handlers = pkg_osdeps.collect do |handler, pkg_list|
                    if handler != native_package_manager
                        [handler, pkg_list]
                    end
                end.compact

                non_native_dependencies = Set.new
                extra_gems = Set.new
                non_native_handlers.each do |pkg_handler, pkg_list|
                    # Convert native ruby gems package names to rock-xxx
                    if pkg_handler.kind_of?(Autoproj::PackageManagers::GemManager)
                        pkg_list.each do |name,version|
                            extra_gems << [name, version]
                            non_native_dependencies << [name, version]
                        end
                    else
                        raise ArgumentError, "cannot package #{pkg.name} as it has non-native dependencies (#{pkg_list}) -- #{pkg_handler.class} #{pkg_handler}"
                    end
                end
                Packager.info "#{pkg.name}' with non native dependencies: #{non_native_dependencies.to_a}"

                # Return rock packages, osdeps and non native deps (here gems)
                {:rock_pkg => deps_rock_pkgs, :osdeps => deps_osdeps_packages, :nonnative => non_native_dependencies.to_a, :extra_gems => extra_gems.to_a }
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
                Packager.info "Using extra configure flags: #{flags}"
                flags
            end

            # Sort by package set order
            def sort_by_package_sets(packages, pkg_set_order)
                priority_lists = Array.new
                (0..pkg_set_order.size).each do |i|
                    priority_lists << Array.new
                end

                packages.each do |package|
                    if !package.kind_of?(String)
                        package = package.name
                    end
                    pkg = Autoproj.manifest.package(package)
                    pkg_set_name = pkg.package_set.name

                    if index = pkg_set_order.index(pkg_set_name)
                        priority_lists[index] << package
                    else
                        priority_lists.last << package
                    end
                end

                priority_lists.flatten
            end

            # Import a package for packaging
            def import_package(pkg, pkg_target_importdir)
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

        end #class Autoproj
    end #module Packaging
end #module Autoproj

