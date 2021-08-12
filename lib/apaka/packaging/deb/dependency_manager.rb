module Apaka
    module Packaging
        module Deb
            class DependencyManager
                def initialize(packager)
                    @packager = packager
                end

                def filter_all_required_packages(packages)
                    all_pkginfos = packages[:pkginfos]
                    sorted_gem_list = packages[:gems]
                    exact_version_list = packages[:gem_versions]

                    # Filter all packages that are available
                    if @packager.rock_release_name
                        all_pkginfos = all_pkginfos.select do |pkginfo|
                            pkg_name = @packager.debian_name(pkginfo, true || with_prefix)
                            !@packager.rock_release_platform.ancestorContains(pkg_name)
                        end

                        sorted_gem_list = sorted_gem_list.select do |gem|
                            with_prefix = true
                            pkg_ruby_name = @packager.debian_ruby_name(gem, !with_prefix)
                            pkg_prefixed_name = @packager.debian_ruby_name(gem, with_prefix)

                            !( @packager.rock_release_platform.ancestorContains(gem) ||
                              @packager.rock_release_platform.ancestorContains(pkg_ruby_name) ||
                              @packager.rock_release_platform.ancestorContains(pkg_prefixed_name))
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
                        all_recursive_deps[:nonnative] = GemDependencies::resolve_all(all_recursive_deps[:nonnative]).keys
                    end
                    recursive_deps = all_recursive_deps.values.flatten.uniq
                end

                # Get the debian package names of dependencies
                def filtered_dependencies(pkginfo, with_rock_release_prefix = true)
                    target_platform = @packager.target_platform
                    this_rock_release = TargetPlatform.new(@packager.rock_release_name, target_platform.architecture)

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

                        # Filter out excluded packages, e.g. libqwt5-qt4-dev
                        deps_osdeps_packages = deps_osdeps_packages.select do |name|
                            result = true
                            Packaging::Config.packages_excluded.each do |pkg_name|
                                regex = Regexp.new(pkg_name)
                                if regex.match(name)
                                    Packager.info "#{pkginfo.name} excluding osdeps #{pkg_name} as dependency"
                                    result = false
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
                        debian_name = @packager.debian_name(pkginfo, with_rock_release_prefix)
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
                        selected_platform = @packager.target_platform
                    end

                    # Identify this rock release and its ancestors
                    this_rock_release = TargetPlatform.new(@packager.rock_release_name, selected_platform.architecture)

                    if name.is_a? String
                        # Check for 'plain' name, the 'unprefixed' name and for the 'release' name
                        if this_rock_release.ancestorContains(name) ||
                           selected_platform.contains(name)
                            # direct name match always is an os dependency
                            # it can never be in a rock release
                            return [name, true]
                        end

                        # try debian naming scheme for ruby
                        if this_rock_release.ancestorContains("ruby-#{Deb.canonize(name)}") ||
                                selected_platform.contains("ruby-#{Deb.canonize(name)}")
                            return ["ruby-#{Deb.canonize(name)}", true]
                        end

                        # otherwise, ask for the ancestor that contains a rock ruby
                        # package
                        ancestor_release_name = this_rock_release.releasedInAncestor(
                            @packager.debian_ruby_name(name, true, this_rock_release.distribution_release_name)
                        )
                        if !ancestor_release_name.empty?
                            return [@packager.debian_ruby_name(name, true, ancestor_release_name), false]
                        end

                        # Return the 'release' name, since no other source provides this package
                        [@packager.debian_ruby_name(name, true), false]
                    else
                        # ask for the ancestor that contains a rock ruby
                        # package
                        ancestor_release = this_rock_release.releasedInAncestor(
                            @packager.debian_name(name, true, this_rock_release.distribution_release_name)
                        )
                        if !ancestor_release.empty?
                            return [@packager.debian_name(name, true, ancestor_release_name), false]
                        end

                        # Return the 'release' name, since no other source provides this package
                        [@packager.debian_name(name, true), false]
                    end
                end
            end
        end
    end
end
