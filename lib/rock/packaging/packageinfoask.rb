
module Autoproj
    module Packaging
        class PackageInfoAsk

            class << self
                alias :class_new :new

                def new(which, options)
                    if which == :detect
                        subclasses.each do |subclass|
                            if subclass.probe
                                return subclass.new(options)
                            end
                        end
                        raise "Cannot find a suitable packageinfo provider"
                    end
                    subclasses.each do |subclass|
                        if which == subclass.which
                            return subclass.new(options)
                        end
                    end
                    raise "Don't know how to create an adaptor for #{which}"
                end

                def inherited(subclass)
                    subclasses.add subclass
                    # this allows child classes to use new as they are used to
                    class << subclass
                        alias :new :class_new
                    end
                end

                def subclasses
                    @subclasses ||= Set.new
                end

                def which
                    raise "#{self} needs to overwrite self.which"
                end

                def probe
                    # default implementation never auto probes
                    false
                end
            end

            def package_set_order
                raise "#{self.class} needs to overwrite package_set_order"
            end

            def package_set_order=
                raise "#{self.class} needs to overwrite package_set_order="
            end

            def osdeps_release_tags
                raise "#{self.class} needs to overwrite osdeps_release_tags"
            end

            def osdeps_operating_system
                raise "#{self.class} needs to overwrite osdeps_operating_system"
            end

            # required for jenkins.rb or if there is a specific operating
            # system in the config file
            def osdeps_operating_system= (os)
                raise "#{self.class} needs to overwrite osdeps_operating_system="
            end

            def root_dir
                raise "#{self.class} needs to overwrite root_dir"
            end

            def osdeps_set_alias(old_name, new_name)
                raise "#{self.class} needs to overwrite osdeps_set_alias"
            end

            def autoproj_init_and_load(selection)
                raise "#{self.class} needs to overwrite autoproj_init_and_load"
            end

            def resolve_user_selection_packages(selection)
                raise "#{self.class} needs to overwrite resolve_user_selection_packages"
            end

            # returns an array of moved packages
            def moved_packages
                raise "#{self.class} needs to overwrite moved_packages"
            end

            # returns an autoproj package
            def package(package_name)
                raise "#{self.class} needs to overwrite package"
            end

            # returns true if pkgname is an autoproj meta package
            def is_metapackage?(package_name)
                raise "#{self.class} needs to overwrite is_metapackage?"
            end

            # returns true if pkgname is to be ignored
            def ignored?(package_name)
                raise "#{self.class} needs to overwrite ignored?"
            end

            # returns a PackageInfo from an autobuild package
            def pkginfo_from_pkg(package)
                raise "#{self.class} needs to overwrite pkginfo_from_pkg"
            end

            # returns an autobuild package from a package_name
            def package_by_name(package_name)
                raise "#{self.class} needs to overwrite package_by_name"
            end

            # Compute all required packages from a given selection
            # including the dependencies
            #
            # The selection is a list of package names
            #
            # The order of the resulting package list is sorted
            # accounting for interdependencies among packages
            def all_required_rock_packages(selection)
                raise "#{self.class} needs to overwrite all_required_rock_packages"
            end

            # Get all required packages that come with a given selection of packages
            # including the dependencies of ruby gems
            #
            # This requires the current installation to be complete since
            # `gem dependency <gem-name>` has been selected to provide the information
            # of ruby dependencies
            def all_required_packages(selection, with_rock_release_prefix = false)
                raise "#{self.class} needs to overwrite all_required_packages"
            end

            # resolve the required gems of a list of gems and their versions
            # { gem => [versions] }
            # returns { :gems => [gem names sorted so least dependend is first],
            #           :gem_versions => { gem => version } }
            def all_required_gems(gem_versions)
                raise "#{self.class} needs to overwrite all_required_gems"
            end

            # Sort by package set order
            # can be used with any packages array of objects providing a name(),
            # that is, works with both autobuild packages and PackageInfos
            # returns a sorted array populated from elements of packages
            def sort_by_package_sets(packages, pkg_set_order)
                raise "#{self.class} needs to overwrite sort_by_package_sets"
            end

        end # class PackageInfoAsk
    end # module Packaging
end # module Autoproj

begin
    require 'rock/packaging/autoproj1adaptor'
rescue LoadError
    # in case the adaptors require fails, not so much that this require fails
rescue
    # if one of the backends does not load, we should still be fine.
end

begin
    require 'rock/packaging/autoproj2adaptor'
rescue LoadError
rescue
end
